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
const orca_policy = @import("orca_core").policy;

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
///
/// D09/D10: missing → generic-agent (ask-on-risk) create; present → never overwrite;
/// unreadable / non-mediating / no-mode → operator-visible residual or core_failed
/// (never silent-green Ask-on-risk without mode evidence).
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
        // Honesty depth (D10): inspect mode evidence; never claim Ask-on-risk without it.
        return try leaveAloneWithHonesty(io, allocator, workspace_root, stderr);
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
            return try leaveAloneWithHonesty(io, allocator, workspace_root, stderr);
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

/// Classification of an existing policy for D09/D10 honesty.
const ExistingPolicyClass = union(enum) {
    /// ask / yolo / strict / ci / redteam — mediating; silent leave-alone is honest.
    mediating,
    /// observe / trusted — non-mediating; must surface residual (never silent Ask).
    non_mediating: []const u8,
    /// File present but empty / no parseable top-level mode.
    no_mode,
    /// Exists at path but cannot be read (permissions / I/O).
    unreadable,
};

/// Leave-alone path with D10 honesty: residual warn or core_failed when mode evidence
/// is missing or non-mediating. Never overwrites. Never claims Ask-on-risk without mode.
fn leaveAloneWithHonesty(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    stderr: anytype,
) !EnsureOutcome {
    const class = inspectExistingPolicy(io, allocator, workspace_root);
    switch (class) {
        .mediating => return leaveAloneOutcome(),
        .non_mediating => |mode_name| {
            // Operator-visible residual aligned with start's "policy mode=… (not Ask)" wording.
            // Always emit (not gated on quiet): honesty must not silent-green under --quiet.
            try stderr.print(
                "ryk ensure: policy mode={s} (not Ask) — existing non-mediating policy left unchanged.\n",
                .{mode_name},
            );
            return leaveAloneOutcome();
        },
        .no_mode => {
            try stderr.print(
                "ryk ensure: policy has no mode evidence (non-mediating residual) — left alone; not Ask-on-risk without mode evidence.\n",
                .{},
            );
            return leaveAloneOutcome();
        },
        .unreadable => {
            // D23 / fail-closed: unreadable is not "present and readable" mediating proof.
            try stderr.print(
                "ryk ensure: policy unreadable — cannot read mode evidence; core_failed (not Ask active).\n",
                .{},
            );
            return coreFailedOutcome();
        },
    }
}

/// Read existing policy at workspace root and classify mode evidence.
/// Never mutates the file. Returns `.unreadable` on open/read failure.
fn inspectExistingPolicy(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ExistingPolicyClass {
    var root_dir = std.Io.Dir.openDirAbsolute(io, workspace_root, .{}) catch return .unreadable;
    defer root_dir.close(io);

    const text = root_dir.readFileAlloc(io, ".orca/policy.yaml", allocator, .limited(256 * 1024)) catch return .unreadable;
    defer allocator.free(text);

    if (text.len == 0) return .no_mode;

    const mode_raw = extractTopLevelMode(text) orelse return .no_mode;
    const parsed = orca_policy.schema.Mode.parse(mode_raw) orelse return .no_mode;

    return switch (parsed) {
        // Soft / non-mediating: must not claim Ask-on-risk (matches start.policyModeIsAskEquivalent).
        .observe, .trusted => .{ .non_mediating = parsed.toString() },
        // Mediating / ask-equivalent (and strict enforce family).
        .ask, .yolo, .strict, .ci, .redteam => .mediating,
    };
}

/// Extract top-level YAML `mode:` scalar from policy text (borrowed into `text`).
/// Skips comments and indented keys so nested `mode:` fields are ignored.
fn extractTopLevelMode(text: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const rest = text[line_start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |n| rest[0..n] else rest;
        const next = if (nl) |n| line_start + n + 1 else text.len + 1;

        // Indented keys are nested — ignore.
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            line_start = next;
            if (nl == null) break;
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_start = next;
            if (nl == null) break;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "mode:")) {
            var value = std.mem.trim(u8, trimmed["mode:".len..], " \t");
            if (std.mem.indexOfScalar(u8, value, '#')) |hash| {
                value = std.mem.trim(u8, value[0..hash], " \t");
            }
            // Strip optional surrounding quotes.
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }
            if (value.len == 0) return null;
            return value;
        }

        line_start = next;
        if (nl == null) break;
    }
    return null;
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

// ---------------------------------------------------------------------------
// EnsurePolicy — default create + leave-alone honesty (w1-policy-default / D09/D10)
// Named-run gate: --filter EnsurePolicy
// ---------------------------------------------------------------------------

fn ensurePolicySha256(bytes: []const u8) [32]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn ensurePolicyClaimsAskOnRiskActive(text: []const u8) bool {
    // Active-claim phrases only — residual notes like "not Ask" / "setup path Ask on risk (auto)"
    // are allowed when accompanied by mode evidence (asserted separately).
    if (containsIgnoreCase(text, "you're now protected")) return true;
    if (containsIgnoreCase(text, "ask-on-risk active")) return true;
    if (containsIgnoreCase(text, "ask on risk active")) return true;
    // Bare "Ask on risk" / "Ask-on-risk" as protection status without residual wording.
    if (std.mem.indexOf(u8, text, "Ask on risk") != null or std.mem.indexOf(u8, text, "Ask-on-risk") != null) {
        // Allowed only when mode residual evidence is co-present (D10).
        const has_mode_evidence =
            containsIgnoreCase(text, "not ask") or
            containsIgnoreCase(text, "policy mode") or
            containsIgnoreCase(text, "mode=observe") or
            containsIgnoreCase(text, "mode=trusted") or
            containsIgnoreCase(text, "mode unread") or
            containsIgnoreCase(text, "unreadable") or
            containsIgnoreCase(text, "non-mediat");
        return !has_mode_evidence;
    }
    return false;
}

fn ensurePolicyHasOperatorResidual(text: []const u8) bool {
    return containsIgnoreCase(text, "not ask") or
        containsIgnoreCase(text, "policy mode") or
        containsIgnoreCase(text, "mode=observe") or
        containsIgnoreCase(text, "mode=trusted") or
        containsIgnoreCase(text, "observe") and containsIgnoreCase(text, "left") or
        containsIgnoreCase(text, "unreadable") or
        containsIgnoreCase(text, "cannot read") or
        containsIgnoreCase(text, "unread") or
        containsIgnoreCase(text, "residual") or
        containsIgnoreCase(text, "non-mediat") or
        containsIgnoreCase(text, "core fail") or
        containsIgnoreCase(text, "core_failed");
}

// Acceptance (1): Missing policy creates generic-agent / ask-on-risk path used by former start.
test "EnsurePolicy missing creates generic-agent ask-on-risk path used by former start" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Locked default used by start / onboarding (D09).
    try std.testing.expectEqualStrings("generic-agent", onboarding.default_preset);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // Null preset must resolve to the same create path former start used.
    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = true,
        .preset = null,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_created);
    try std.testing.expect(!outcome.policy_left_alone);
    try std.testing.expect(outcome.protection_label != .core_failed);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expect(policy.len > 0);
    // Ask-on-risk = policy mode ask (generic-agent preset body).
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: observe") == null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: trusted") == null);
    // generic-agent shape markers (preset file + init path).
    try std.testing.expect(std.mem.indexOf(u8, policy, "write_mode: staged") != null or
        std.mem.indexOf(u8, policy, "version:") != null);
}

// Acceptance (1) explicit preset pin — same ask-on-risk body as start --preset generic-agent.
test "EnsurePolicy explicit generic-agent preset creates mode ask not observe" {
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
        .preset = "generic-agent",
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expect(outcome.policy_created);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: ask") != null);
}

// Acceptance (2): Existing policy content unchanged after ensure (hash equal).
test "EnsurePolicy existing policy content hash unchanged after ensure" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sentinel =
        \\version: 1
        \\mode: strict
        \\# ensure-policy-hash-marker-c7e1
        \\workspace:
        \\  root: "."
        \\  write_mode: staged
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, sentinel);

    const before = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(before);
    const hash_before = ensurePolicySha256(before);

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

    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(!outcome.policy_created);

    const after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings(sentinel, after);
    const hash_after = ensurePolicySha256(after);
    try std.testing.expectEqualSlices(u8, &hash_before, &hash_after);
    try std.testing.expect(std.mem.indexOf(u8, after, "ensure-policy-hash-marker-c7e1") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "mode: strict") != null);
    // Must not rewrite to default ask-on-risk body.
    try std.testing.expect(std.mem.indexOf(u8, after, "mode: ask") == null);
}

// Composition: nested cwd re-run keeps root path + hash stable (no project-subdir steal).
test "EnsurePolicy nested cwd leave-alone keeps workspace root hash stable" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "nested/deep");
    const seeded =
        \\version: 1
        \\mode: ask
        \\# ensure-policy-nested-hash-b2a4
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, seeded);

    const before = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(before);
    const hash_before = ensurePolicySha256(before);

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

    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(!outcome.policy_created);

    const after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualSlices(u8, &hash_before, &ensurePolicySha256(after));

    if (tmp.dir.access(io, "nested/deep/.orca/policy.yaml", .{})) |_| {
        try std.testing.expect(false); // must not create under nested cwd
    } else |_| {}
}

// Acceptance (3): Non-mediating (observe) is operator-visible; never silent Ask-on-risk green (D10).
test "EnsurePolicy non-mediating observe is operator-visible never silent Ask-on-risk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const observe_body =
        \\version: 1
        \\mode: observe
        \\# ensure-policy-observe-residual-d10
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, observe_body);

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // quiet=false: honesty residual must be operator-visible on the ensure surface.
    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = false,
        .preset = "generic-agent",
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(!outcome.policy_created);
    // Never claim full protection without mode evidence / host proof.
    try std.testing.expect(outcome.protection_label != .full);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expectEqualStrings(observe_body, policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: observe") != null);

    // Joint operator-visible channel (stdout ∪ stderr).
    var joint_buf: [12288]u8 = undefined;
    const joint = blk: {
        const out = stdout_writer.buffered();
        const err = stderr_writer.buffered();
        if (out.len + err.len > joint_buf.len) break :blk out; // fall back: still check out
        @memcpy(joint_buf[0..out.len], out);
        @memcpy(joint_buf[out.len .. out.len + err.len], err);
        break :blk joint_buf[0 .. out.len + err.len];
    };

    try std.testing.expect(!ensurePolicyClaimsAskOnRiskActive(joint));

    // Operator-visible residual: warn text and/or core fail. Silent core_ok + partial alone is insufficient (D10).
    const residual_text = ensurePolicyHasOperatorResidual(joint);
    const core_failed = !outcome.core_ok or outcome.protection_label == .core_failed;
    try std.testing.expect(residual_text or core_failed);
    // Prefer explicit mode evidence when still core_ok (leave-alone non-mediating path).
    if (outcome.core_ok) {
        try std.testing.expect(residual_text);
        try std.testing.expect(containsIgnoreCase(joint, "observe") or containsIgnoreCase(joint, "not ask") or containsIgnoreCase(joint, "policy mode"));
    }
}

// Acceptance (3): trusted is non-mediating (same residual class as observe).
test "EnsurePolicy non-mediating trusted is operator-visible never silent Ask-on-risk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trusted_body =
        \\version: 1
        \\mode: trusted
        \\# ensure-policy-trusted-residual-d10
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, trusted_body);

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = false,
        .preset = onboarding.default_preset,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.policy_left_alone);
    try std.testing.expect(outcome.protection_label != .full);

    const policy = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(policy);
    try std.testing.expectEqualStrings(trusted_body, policy);

    var joint_buf: [12288]u8 = undefined;
    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    try std.testing.expect(out.len + err.len <= joint_buf.len);
    @memcpy(joint_buf[0..out.len], out);
    @memcpy(joint_buf[out.len .. out.len + err.len], err);
    const joint = joint_buf[0 .. out.len + err.len];

    try std.testing.expect(!ensurePolicyClaimsAskOnRiskActive(joint));
    const residual_text = ensurePolicyHasOperatorResidual(joint);
    const core_failed = !outcome.core_ok or outcome.protection_label == .core_failed;
    try std.testing.expect(residual_text or core_failed);
    if (outcome.core_ok) try std.testing.expect(residual_text);
}

// Acceptance (3): Unreadable policy is operator-visible; never silent-green Ask claim (D10/D23 readable).
test "EnsurePolicy unreadable policy is operator-visible not silent green Ask" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try ensureCoreWritePolicy(tmp.dir,
        \\version: 1
        \\mode: ask
        \\
    );

    // Strip all perms so mode evidence cannot be read.
    try tmp.dir.setFilePermissions(io, ".orca/policy.yaml", std.Io.File.Permissions.fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(io, ".orca/policy.yaml", std.Io.File.Permissions.fromMode(0o644), .{}) catch {};

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = false,
        .preset = "generic-agent",
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    // Must not overwrite unreadable existing policy (still present at path).
    try std.testing.expect(!outcome.policy_created);

    var joint_buf: [12288]u8 = undefined;
    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    try std.testing.expect(out.len + err.len <= joint_buf.len);
    @memcpy(joint_buf[0..out.len], out);
    @memcpy(joint_buf[out.len .. out.len + err.len], err);
    const joint = joint_buf[0 .. out.len + err.len];

    try std.testing.expect(!ensurePolicyClaimsAskOnRiskActive(joint));
    try std.testing.expect(outcome.protection_label != .full);

    // D23: unreadable is not "policy present/readable" → operator-visible fail or residual.
    const residual_text = ensurePolicyHasOperatorResidual(joint);
    const core_failed = !outcome.core_ok or outcome.protection_label == .core_failed;
    try std.testing.expect(residual_text or core_failed);
    // Prefer fail-closed on unreadable for ensure honesty depth.
    try std.testing.expect(core_failed or containsIgnoreCase(joint, "unread") or containsIgnoreCase(joint, "unreadable") or containsIgnoreCase(joint, "cannot read"));
}

// Acceptance (3): Corrupt / no-mode policy cannot claim Ask-on-risk without mode evidence.
test "EnsurePolicy corrupt no-mode policy never claims Ask-on-risk without mode evidence" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const garbage =
        \\# not a mediating policy
        \\this is: [not, valid, mode evidence]
        \\random: true
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, garbage);
    const before = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(before);
    const hash_before = ensurePolicySha256(before);

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = false,
        .preset = "generic-agent",
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    // Never overwrite garbage with default ask-on-risk (D09 leave-alone).
    try std.testing.expect(!outcome.policy_created);
    const after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualSlices(u8, &hash_before, &ensurePolicySha256(after));

    var joint_buf: [12288]u8 = undefined;
    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    try std.testing.expect(out.len + err.len <= joint_buf.len);
    @memcpy(joint_buf[0..out.len], out);
    @memcpy(joint_buf[out.len .. out.len + err.len], err);
    const joint = joint_buf[0 .. out.len + err.len];

    try std.testing.expect(!ensurePolicyClaimsAskOnRiskActive(joint));
    try std.testing.expect(outcome.protection_label != .full);

    const residual_text = ensurePolicyHasOperatorResidual(joint);
    const core_failed = !outcome.core_ok or outcome.protection_label == .core_failed;
    try std.testing.expect(residual_text or core_failed);
}

// Empty policy file: no mode evidence → not silent Ask-on-risk green.
test "EnsurePolicy empty policy is operator-visible never silent Ask-on-risk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try ensureCoreWritePolicy(tmp.dir, "");

    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    var outcome = try runEnsure(io, allocator, tmp.dir, .{
        .from_install = false,
        .quiet = false,
        .preset = null,
        .skip_verify = true,
    }, &stdout_writer, &stderr_writer);
    defer outcome.deinit(allocator);

    try std.testing.expect(!outcome.policy_created);
    // Empty file must remain empty (no silent rewrite to ask).
    const after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);

    var joint_buf: [12288]u8 = undefined;
    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    try std.testing.expect(out.len + err.len <= joint_buf.len);
    @memcpy(joint_buf[0..out.len], out);
    @memcpy(joint_buf[out.len .. out.len + err.len], err);
    const joint = joint_buf[0 .. out.len + err.len];

    try std.testing.expect(!ensurePolicyClaimsAskOnRiskActive(joint));
    try std.testing.expect(outcome.protection_label != .full);
    const residual_text = ensurePolicyHasOperatorResidual(joint);
    const core_failed = !outcome.core_ok or outcome.protection_label == .core_failed;
    try std.testing.expect(residual_text or core_failed);
}

// Mediating existing ask policy may leave-alone without residual scare (hash stable).
test "EnsurePolicy existing ask mode leave-alone hash equal without false residual fail" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ask_body =
        \\version: 1
        \\mode: ask
        \\# ensure-policy-ask-leave-alone-a91f
        \\
    ;
    try ensureCoreWritePolicy(tmp.dir, ask_body);
    const hash_before = ensurePolicySha256(ask_body);

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
    try std.testing.expect(outcome.protection_label != .core_failed);

    const after = try ensureCoreReadPolicy(tmp.dir);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(ask_body, after);
    try std.testing.expectEqualSlices(u8, &hash_before, &ensurePolicySha256(after));
}
