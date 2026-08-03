//! Shared ensure library (W1) — single entry for policy + host readiness.
//!
//! Production surface: `runEnsure`, `EnsureOptions`, `EnsureOutcome`,
//! `HostResult`, `core_ok`, `protection_label`, plus outcome ownership/`deinit`.
//! API surface is frozen after w1-ensure-core (D20); later W1 units fill behavior only.

const std = @import("std");

const onboarding = @import("onboarding.zig");
const init = @import("init.zig");
const exit_codes = @import("exit_codes.zig");
const env_util = @import("../env_util.zig");

// ---------------------------------------------------------------------------
// Frozen API surface (plan §2 / D20)
// ---------------------------------------------------------------------------

/// Options for `runEnsure`. Field set is frozen — later W1 units fill behavior only.
pub const EnsureOptions = struct {
    /// Install / `--from-install` door: HOME + resource-root scope (D32).
    from_install: bool = false,
    quiet: bool = false,
    /// Create-only when policy missing; null → `onboarding.default_preset`.
    preset: ?[]const u8 = null,
    skip_verify: bool = false,
    // Honor RYK_RESOURCE_ROOT / ORCA_RESOURCE_ROOT when set (resource_root helpers).
};

pub const HostErrorClass = enum {
    none,
    detect,
    wire,
    smoke,
    other,
};

pub const ProtectionLabel = enum {
    full,
    partial,
    core_failed,
};

pub const HostResult = struct {
    host_id: []const u8,
    detected: bool,
    wired: bool,
    smoke_ok: bool,
    /// Teach `ryk doctor --fix` — never "ryk start" as required repair.
    fix_hint: []const u8,
    error_class: HostErrorClass,
};

pub const EnsureOutcome = struct {
    core_ok: bool,
    hosts: []HostResult,
    policy_created: bool,
    policy_left_alone: bool,
    protection_label: ProtectionLabel,
    /// When true, `hosts` was allocated with `allocator` and is freed in `deinit`.
    hosts_owned: bool = false,

    pub fn deinit(self: *EnsureOutcome, allocator: std.mem.Allocator) void {
        if (self.hosts_owned) {
            allocator.free(self.hosts);
            self.hosts = &.{};
            self.hosts_owned = false;
        }
    }
};

/// Shared ensure entry: resolve workspace root, create-if-missing policy (never overwrite),
/// return structured outcome. Host auto-wire is filled by later W1 units.
///
/// Policy is always written at the resolved workspace root (D29) — never naively under
/// a nested process cwd when a parent workspace marker exists.
pub fn runEnsure(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    options: EnsureOptions,
    stdout: anytype,
    stderr: anytype,
) !EnsureOutcome {
    // D32/D33: install door never falls open to process-cwd when HOME is unusable.
    const workspace_root = resolveEnsureWorkspaceRoot(io, allocator, cwd, options) catch |err| {
        if (err == error.InstallHomeUnavailable) {
            if (!options.quiet) {
                try stderr.print("ryk ensure: install scope requires absolute HOME (D32/D33)\n", .{});
            }
            return coreFailedOutcome();
        }
        return err;
    };
    defer allocator.free(workspace_root);

    if (onboarding.policyExists(io, workspace_root)) {
        return leaveAloneOutcome();
    }

    var root_dir = std.Io.Dir.openDirAbsolute(io, workspace_root, .{}) catch |err| {
        if (!options.quiet) {
            try stderr.print("ryk ensure: cannot open workspace root '{s}': {s}\n", .{ workspace_root, @errorName(err) });
        }
        return coreFailedOutcome();
    };
    defer root_dir.close(io);

    const preset = options.preset orelse onboarding.default_preset;
    var init_argv_buf: [3][]const u8 = undefined;
    const init_argv: []const []const u8 = if (options.quiet) blk: {
        init_argv_buf[0] = "--preset";
        init_argv_buf[1] = preset;
        init_argv_buf[2] = "--quiet";
        break :blk init_argv_buf[0..3];
    } else blk: {
        init_argv_buf[0] = "--preset";
        init_argv_buf[1] = preset;
        break :blk init_argv_buf[0..2];
    };

    const code = try init.command(io, root_dir, init_argv, stdout, stderr);
    if (code != exit_codes.success) {
        // Multi-process race: peer may have won exclusive create. Present policy is leave-alone (D23).
        if (onboarding.policyExists(io, workspace_root)) {
            return leaveAloneOutcome();
        }
        return coreFailedOutcome();
    }

    // Zero hosts: success without full-protection claim (plan §2 core_ok map).
    return EnsureOutcome{
        .core_ok = true,
        .hosts = &.{},
        .policy_created = true,
        .policy_left_alone = false,
        .protection_label = .partial,
        .hosts_owned = false,
    };
}

fn leaveAloneOutcome() EnsureOutcome {
    return .{
        .core_ok = true,
        .hosts = &.{},
        .policy_created = false,
        .policy_left_alone = true,
        // Zero hosts / no wire proof → partial (never claim full protection).
        .protection_label = .partial,
        .hosts_owned = false,
    };
}

fn coreFailedOutcome() EnsureOutcome {
    return .{
        .core_ok = false,
        .hosts = &.{},
        .policy_created = false,
        .policy_left_alone = false,
        .protection_label = .core_failed,
        .hosts_owned = false,
    };
}

/// Install door requires absolute HOME (D32/D33 fail-closed); interactive door walks from cwd (D29/D31).
///
/// When cwd lives under a Zig `.zig-cache/tmp/<id>` tree (test fixtures and local
/// build caches), the walk is capped at that tmp root so we never treat the
/// enclosing monorepo as the ensure workspace. Nested project dirs still resolve
/// upward to a `.git` / policy marker *within* that ceiling (D29).
///
/// Errors: `error.InstallHomeUnavailable` when `from_install` and HOME is missing,
/// empty, or non-absolute — caller maps to `core_failed` and must not walk cwd.
fn resolveEnsureWorkspaceRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    options: EnsureOptions,
) ![]u8 {
    if (options.from_install) {
        // D32/D33: never fall through to process-cwd mutation from the install door.
        const home = (try homeDirOwned(allocator)) orelse return error.InstallHomeUnavailable;
        errdefer allocator.free(home);
        if (home.len == 0 or !std.fs.path.isAbsolute(home)) {
            return error.InstallHomeUnavailable;
        }
        return home;
    }

    const start_path = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(start_path);

    if (zigCacheTmpCeiling(start_path)) |ceiling| {
        // Always returns a fresh owned dupe; start_path freed by defer.
        return try resolveWorkspaceRootWithCeiling(io, allocator, start_path, ceiling);
    }
    return onboarding.resolveWorkspaceRootFromCwd(io, allocator, cwd);
}

fn homeDirOwned(allocator: std.mem.Allocator) !?[]u8 {
    var env_map = env_util.createProcessMap(allocator) catch return null;
    defer env_map.deinit();
    return env_util.getOwned(&env_map, allocator, "HOME") catch return null;
}

/// If `path` is under `.../.zig-cache/tmp/<entry>/...`, return the absolute
/// ceiling `.../.zig-cache/tmp/<entry>` (slice into `path`). Otherwise null.
fn zigCacheTmpCeiling(path: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "/.zig-cache/tmp/", "\\.zig-cache\\tmp\\" };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, path, needle)) |idx| {
            const entry_start = idx + needle.len;
            if (entry_start >= path.len) return null;
            const rest = path[entry_start..];
            const entry_len = std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len;
            if (entry_len == 0) return null;
            return path[0 .. entry_start + entry_len];
        }
    }
    return null;
}

/// Walk from `start_path` toward `ceiling` (inclusive) for `.git` or policy markers.
/// Always returns a newly allocated path; caller owns it. `start_path` / `ceiling`
/// are borrowed.
///
/// Ownership: function-scoped `errdefer free(current)` stays armed. All fallback
/// exits allocate the return value **before** freeing `current` so OOM on dupe
/// cannot double-free (implement-floor §6 / memory HARD FAIL).
fn resolveWorkspaceRootWithCeiling(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    ceiling: []const u8,
) ![]u8 {
    var current = try allocator.dupe(u8, start_path);
    errdefer allocator.free(current);

    while (true) {
        if (workspaceMarkerAt(io, current)) {
            return current;
        }

        // Do not walk above the zig-cache tmp ceiling — use the original cwd path.
        if (std.mem.eql(u8, current, ceiling)) {
            const result = try allocator.dupe(u8, start_path);
            allocator.free(current);
            return result;
        }

        const parent = std.fs.path.dirname(current) orelse {
            const result = try allocator.dupe(u8, start_path);
            allocator.free(current);
            return result;
        };
        // Safety: parent must remain at or under ceiling.
        if (parent.len < ceiling.len or !std.mem.startsWith(u8, parent, ceiling)) {
            const result = try allocator.dupe(u8, start_path);
            allocator.free(current);
            return result;
        }
        if (std.mem.eql(u8, parent, current)) {
            const result = try allocator.dupe(u8, start_path);
            allocator.free(current);
            return result;
        }

        // Loop step: allocate next before free so OOM still has live `current` for errdefer.
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn workspaceMarkerAt(io: std.Io, dir_path: []const u8) bool {
    const git_path = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, ".git" }) catch return false;
    defer std.heap.page_allocator.free(git_path);
    if (absoluteExists(io, git_path)) return true;

    const policy_path = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, ".orca", "policy.yaml" }) catch return false;
    defer std.heap.page_allocator.free(policy_path);
    return absoluteExists(io, policy_path);
}

fn absoluteExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Helpers (test-only)
// ---------------------------------------------------------------------------

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn ensureCoreWritePolicy(dir: std.Io.Dir, contents: []const u8) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, ".orca");
    const file = try dir.createFile(io, ".orca/policy.yaml", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn ensureCoreReadPolicy(dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(64 * 1024));
}

// ---------------------------------------------------------------------------
// EnsureCore — API freeze (plan §2)
// ---------------------------------------------------------------------------

test "EnsureCore API surface freezes EnsureOptions Outcome HostResult fields" {
    // Field names / tags are the frozen contract (D20). Later W1 units fill behavior only.
    const opts = EnsureOptions{
        .from_install = false,
        .quiet = true,
        .preset = "generic-agent",
        .skip_verify = true,
    };
    try std.testing.expect(!opts.from_install);
    try std.testing.expect(opts.quiet);
    try std.testing.expectEqualStrings("generic-agent", opts.preset.?);
    try std.testing.expect(opts.skip_verify);

    // Enum members required by plan §2 / soft-success map.
    try std.testing.expectEqual(ProtectionLabel.full, ProtectionLabel.full);
    try std.testing.expectEqual(ProtectionLabel.partial, ProtectionLabel.partial);
    try std.testing.expectEqual(ProtectionLabel.core_failed, ProtectionLabel.core_failed);

    try std.testing.expectEqual(HostErrorClass.none, HostErrorClass.none);
    try std.testing.expectEqual(HostErrorClass.detect, HostErrorClass.detect);
    try std.testing.expectEqual(HostErrorClass.wire, HostErrorClass.wire);
    try std.testing.expectEqual(HostErrorClass.smoke, HostErrorClass.smoke);
    try std.testing.expectEqual(HostErrorClass.other, HostErrorClass.other);

    // HostResult shape: host_id / detected / wired / smoke_ok / fix_hint / error_class.
    const host = HostResult{
        .host_id = "claude",
        .detected = false,
        .wired = false,
        .smoke_ok = false,
        .fix_hint = "ryk doctor --fix",
        .error_class = .none,
    };
    try std.testing.expectEqualStrings("claude", host.host_id);
    try std.testing.expect(std.mem.indexOf(u8, host.fix_hint, "doctor --fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.fix_hint, "ryk start") == null);

    // EnsureOutcome shape: core_ok / hosts / policy_created / policy_left_alone / protection_label.
    var outcome = EnsureOutcome{
        .core_ok = true,
        .hosts = &.{},
        .policy_created = false,
        .policy_left_alone = true,
        .protection_label = .partial,
    };
    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(!outcome.policy_created);
    try std.testing.expectEqual(ProtectionLabel.partial, outcome.protection_label);
    try std.testing.expectEqual(@as(usize, 0), outcome.hosts.len);
    // deinit must exist for owned host slices (bridge/callers free via this).
    outcome.deinit(std.testing.allocator);
}

// ---------------------------------------------------------------------------
// EnsureCore — policy missing → create (freeze is not types-only; F1)
// ---------------------------------------------------------------------------

test "EnsureCore creates policy when missing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_created);
    try std.testing.expect(!outcome.policy_left_alone);
    try std.testing.expect(outcome.protection_label != .core_failed);

    // Canonical policy path under the fixture workspace (cwd root here).
    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expect(policy.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, policy, "version:") != null or std.mem.indexOf(u8, policy, "mode:") != null);

    // Re-run must not rewrite as create again.
    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    var second = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer second.deinit(allocator);
    try std.testing.expect(second.core_ok);
    try std.testing.expect(second.policy_left_alone);
    try std.testing.expect(!second.policy_created);

    const policy_after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy_after);
    try std.testing.expectEqualStrings(policy, policy_after);
}

// ---------------------------------------------------------------------------
// EnsureCore — existing policy leave-alone (never overwrite)
// ---------------------------------------------------------------------------

test "EnsureCore leave-alone when policy exists" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sentinel =
        \\version: 1
        \\mode: observe
        \\# ensure-core-leave-alone-marker-9f3a
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, sentinel);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = "generic-agent",
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(!outcome.policy_created);
    try std.testing.expect(outcome.protection_label != .core_failed);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expectEqualStrings(sentinel, policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "ensure-core-leave-alone-marker-9f3a") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: observe") != null);
}

// ---------------------------------------------------------------------------
// EnsureCore — nested cwd → policy at workspace root (D29 composition)
// ---------------------------------------------------------------------------

test "EnsureCore nested cwd writes policy at workspace root not process cwd" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Git marker so resolveWorkspaceRoot walks nested → root (not naive cwd write).
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "nested/deep");
    var nested = try tmp.dir.openDir(io, "nested/deep", .{});
    defer nested.close(io);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, nested, .{
        .from_install = false,
        .quiet = true,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_created);
    try std.testing.expect(!outcome.policy_left_alone);

    // Policy lands at workspace root, not under nested/deep.
    const root_policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(root_policy);
    try std.testing.expect(root_policy.len > 0);

    if (tmp.dir.access(io, "nested/deep/.orca/policy.yaml", .{})) |_| {
        try std.testing.expect(false); // must not steal into nested cwd
    } else |_| {}

    // Nested re-run: same path + content, leave-alone (no rewrite).
    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    var second = try runEnsure(io, allocator, nested, .{
        .from_install = false,
        .quiet = true,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer second.deinit(allocator);

    try std.testing.expect(second.core_ok);
    try std.testing.expect(second.policy_left_alone);
    try std.testing.expect(!second.policy_created);

    const root_after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(root_after);
    try std.testing.expectEqualStrings(root_policy, root_after);

    if (tmp.dir.access(io, "nested/deep/.orca/policy.yaml", .{})) |_| {
        try std.testing.expect(false);
    } else |_| {}
}

// ---------------------------------------------------------------------------
// EnsureCore — options defaults / null preset path still creates
// ---------------------------------------------------------------------------

test "EnsureCore null preset still creates when policy missing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = null,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_created);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expect(policy.len > 0);
}

// ---------------------------------------------------------------------------
// EnsureCore — HostResult fix_hint contract on empty/soft host list
// ---------------------------------------------------------------------------

test "EnsureCore host fix_hint never teaches ryk start as required repair" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    for (outcome.hosts) |host| {
        // Plan §2: fix_hint teaches doctor --fix — never "ryk start" as required.
        if (host.fix_hint.len == 0) continue;
        if (containsIgnoreCase(host.fix_hint, "ryk start")) {
            // Only allowed if doctor --fix is also taught as the repair door.
            try std.testing.expect(containsIgnoreCase(host.fix_hint, "doctor --fix"));
        }
    }

    // Quiet path: no D06 full-protection claim when we did not prove hosts (zero hosts).
    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    try std.testing.expect(!containsIgnoreCase(out, "fully protected"));
    try std.testing.expect(!containsIgnoreCase(out, "all hosts wired"));
    try std.testing.expect(!containsIgnoreCase(out, "protection complete"));
    try std.testing.expect(!containsIgnoreCase(err, "fully protected"));
}

// ---------------------------------------------------------------------------
// EnsureCore — start temporary bridge (D61) + no public start delete
// Source contracts via @embedFile avoid ensure↔start import cycles.
// ---------------------------------------------------------------------------

test "EnsureCore start bridge routes policy create through runEnsure without parallel ensurePolicy" {
    // Acceptance (2): start.zig temporary bridge calls ensure for policy without
    // duplicating create. Gate must fail if ensure.zig is complete but start still
    // creates via the parallel onboarding.ensurePolicy path only.
    const start_src = @embedFile("start.zig");

    const imports_ensure =
        std.mem.indexOf(u8, start_src, "@import(\"ensure.zig\")") != null or
        std.mem.indexOf(u8, start_src, "@import(\"ensure\")") != null;
    const calls_run_ensure = std.mem.indexOf(u8, start_src, "runEnsure") != null;
    try std.testing.expect(imports_ensure or calls_run_ensure);
    try std.testing.expect(calls_run_ensure);

    // No parallel create: policy step must not invoke onboarding.ensurePolicy
    // (that path creates via init.command independently of the ensure library).
    try std.testing.expect(std.mem.indexOf(u8, start_src, "onboarding.ensurePolicy") == null);
}

test "EnsureCore start command and runStart remain public no delete" {
    // Acceptance (2) half: no public start delete until W4.
    // Live_smoke covers help; this freezes the library entry points in source.
    const start_src = @embedFile("start.zig");

    try std.testing.expect(std.mem.indexOf(u8, start_src, "pub fn command") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_src, "pub fn runStart") != null);

    // Dispatch still routes "start" (defense: command body not deleted while
    // leaving a stub signature). Require runStart body still present as call target.
    try std.testing.expect(std.mem.indexOf(u8, start_src, "return runStart") != null or
        std.mem.indexOf(u8, start_src, "runStart(") != null);
}

// ---------------------------------------------------------------------------
// EnsureCore — monopath export (D73): mod.zig must pull ensure tests
// ---------------------------------------------------------------------------

test "EnsureCore monopath mod imports ensure for named-run pull" {
    // Acceptance (3): src/cli/mod.zig imports ensure (test { _ = ensure; }) so
    // monopath pulls co-located EnsureCore tests. Source contract only — no cycle.
    const mod_src = @embedFile("mod.zig");

    const has_import_path = std.mem.indexOf(u8, mod_src, "@import(\"ensure.zig\")") != null;
    const has_pub_const = std.mem.indexOf(u8, mod_src, "pub const ensure") != null;
    try std.testing.expect(has_import_path or has_pub_const);

    // test-block pull (D73 / plan acceptance wording).
    try std.testing.expect(std.mem.indexOf(u8, mod_src, "_ = ensure") != null);
}
