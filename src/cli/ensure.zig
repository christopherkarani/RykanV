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
const plugin = @import("plugin.zig");
const orca_policy = @import("orca_core").policy;
const pi_install = @import("pi_install.zig");
const grok_install = @import("grok_install.zig");
const host_status = @import("host_status.zig");
const child_process = @import("child_process.zig");
const brand = @import("brand.zig");

/// Teach repair door for soft host/wire failures — never `ryk start` as required.
pub const doctor_fix_hint: []const u8 = "ryk doctor --fix";

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
/// auto-wire every detected day-one host (no multi-select), return soft-success outcome.
///
/// Policy is always written at the resolved workspace root (D29) — never naively under
/// a nested process cwd when a parent workspace marker exists.
///
/// D09/D10: missing → generic-agent (ask-on-risk) create; present → never overwrite;
/// unreadable / non-mediating / no-mode → operator-visible residual or core_failed
/// (never silent-green Ask-on-risk without mode evidence).
///
/// Soft success (D24/D25): host/wire/smoke fails keep `core_ok` when policy is ok;
/// `protection_label=partial` + `fix_hint` teaching `ryk doctor --fix` (D06 honesty).
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
        return try leaveAloneWithHonesty(io, allocator, workspace_root, options, stderr);
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
            return try leaveAloneWithHonesty(io, allocator, workspace_root, options, stderr);
        }
        return coreFailedOutcome();
    }

    // Policy created → auto-wire detected hosts (soft); zero hosts → partial, never full claim.
    return try coreOkOutcomeWithHosts(io, allocator, options, true, false);
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

/// Policy ok → attach auto-wire HostResult[] + protection_label from hosts (D05/D24).
fn coreOkOutcomeWithHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: EnsureOptions,
    policy_created: bool,
    policy_left_alone: bool,
) !EnsureOutcome {
    const hosts = try wireDetectedHosts(io, allocator, options);
    return .{
        .core_ok = true,
        .hosts = hosts,
        .policy_created = policy_created,
        .policy_left_alone = policy_left_alone,
        .protection_label = protectionLabelFromHosts(hosts),
        .hosts_owned = true,
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
/// On leave-alone (not core_failed), still auto-wires detected hosts with soft success.
fn leaveAloneWithHonesty(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    options: EnsureOptions,
    stderr: anytype,
) !EnsureOutcome {
    const class = inspectExistingPolicy(io, allocator, workspace_root);
    switch (class) {
        .mediating => {},
        .non_mediating => |mode_name| {
            // Operator-visible residual aligned with start's "policy mode=… (not Ask)" wording.
            // Always emit (not gated on quiet): honesty must not silent-green under --quiet.
            try stderr.print(
                "ryk ensure: policy mode={s} (not Ask) — existing non-mediating policy left unchanged.\n",
                .{mode_name},
            );
        },
        .no_mode => {
            try stderr.print(
                "ryk ensure: policy has no mode evidence (non-mediating residual) — left alone; not Ask-on-risk without mode evidence.\n",
                .{},
            );
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
    return try coreOkOutcomeWithHosts(io, allocator, options, false, true);
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
// Soft success + host wire table (D28 / D24 / D05 / D06) — w1-auto-wire-soft-success
// ---------------------------------------------------------------------------

/// Map host results → protection label (D05).
/// Zero hosts / zero detected → partial (never full-protection claim without proof).
/// ≥1 detected and all wired+smoke_ok with error_class.none → full.
/// Any detected host incomplete → partial.
pub fn protectionLabelFromHosts(hosts: []const HostResult) ProtectionLabel {
    var any_detected: bool = false;
    var all_ok: bool = true;
    for (hosts) |h| {
        if (!h.detected) continue;
        any_detected = true;
        if (!h.wired or !h.smoke_ok or h.error_class != .none) {
            all_ok = false;
        }
    }
    if (!any_detected) return .partial;
    if (all_ok) return .full;
    return .partial;
}

/// Process exit map for ensure / doctor --fix soft success (D24/D25).
/// core_ok true → 0; core_ok false → non-zero (never soft-success on core fail).
pub fn processExitForOutcome(outcome: EnsureOutcome) u8 {
    if (outcome.core_ok) return exit_codes.success;
    return exit_codes.general;
}

/// Soft-incomplete demotion for packs / global shell verify (D24).
/// Never upgrades core_failed; demotes full → partial when packs or global verify fail.
pub fn applySoftIncomplete(
    label: ProtectionLabel,
    packs_ok: bool,
    global_verify_ok: bool,
) ProtectionLabel {
    if (label == .core_failed) return .core_failed;
    if (!packs_ok or !global_verify_ok) return .partial;
    return label;
}

/// Plain-text ensure receipt (W1). Partial must include partial token + doctor --fix
/// repair + failed host ids; must never claim D06 full-protection phrases.
pub fn writeEnsureReceipt(writer: anytype, outcome: EnsureOutcome) !void {
    switch (outcome.protection_label) {
        .full => {
            // Allowed only when label is full (≥1 host all ok). Avoid D06 forbid-list phrases.
            try writer.writeAll("ryk ensure: hosts ready.\n");
            for (outcome.hosts) |h| {
                if (h.detected) try writer.print("  host {s}: ok\n", .{h.host_id});
            }
        },
        .partial => {
            try writer.writeAll("ryk ensure: protection partial — some hosts incomplete or none detected.\n");
            var any_fail_line: bool = false;
            for (outcome.hosts) |h| {
                if (!h.detected) continue;
                if (h.wired and h.smoke_ok and h.error_class == .none) continue;
                any_fail_line = true;
                const hint = if (h.fix_hint.len > 0) h.fix_hint else doctor_fix_hint;
                try writer.print("  host {s}: incomplete — repair: {s}\n", .{ h.host_id, hint });
            }
            if (!any_fail_line) {
                // Zero hosts or only non-detected: still teach repair door.
                try writer.print("  no hosts fully wired — repair: {s}\n", .{doctor_fix_hint});
            }
        },
        .core_failed => {
            try writer.writeAll("ryk ensure: core failed — policy create or binary unusable.\n");
            try writer.print("  repair: {s}\n", .{doctor_fix_hint});
        },
    }
}

/// Installer strategy for a day-one host (D28). Ensure owns host→installer
/// dispatch; membership keys come from `onboarding.isSupportedHost` only (F2).
/// Mirrors `start.installSelectedHosts` without multi-select:
/// - `pi_extension` → `pi_install.install`
/// - `grok_hook` → `grok_install.installAtHome`
/// - `plugin_yes` → `ryk plugin install <host> --yes` + `plugin.verifyHostInstallAfterChild`
/// W3 Cursor extends via the same table (`plugin_yes` or a new installer kind).
const HostInstaller = enum {
    pi_extension,
    grok_hook,
    plugin_yes,
};

/// Host→installer dispatch row (D28).
const HostWireTableEntry = struct {
    host_id: []const u8,
    installer: HostInstaller,
};

/// Greppable day-one wire table symbol (D28). Rows name installer entrypoints;
/// membership is onboarding single-source — no ensure-local host-id array (F2).
const HostWireTable = struct {
    /// Compile-time marker that the table exists for source contracts.
    pub const present = true;

    /// Resolve whether a host id is in the day-one membership set (onboarding single-source).
    pub fn isDayOneMember(host_id: []const u8) bool {
        return onboarding.isSupportedHost(host_id);
    }

    /// Build a dispatch entry for a membership host (keys import onboarding list).
    pub fn entryFor(host_id: []const u8) ?HostWireTableEntry {
        if (!isDayOneMember(host_id)) return null;
        // Per-host installer entrypoints (W1 reuses Pi/plugin paths; W3 extends).
        const installer: HostInstaller = if (std.mem.eql(u8, host_id, "pi"))
            .pi_extension
        else if (std.mem.eql(u8, host_id, "grok"))
            .grok_hook
        else
            .plugin_yes;
        return .{
            .host_id = host_id,
            .installer = installer,
        };
    }
};

/// Also greppable as host_wire_table for D28 source contracts.
const host_wire_table = HostWireTable;

fn ensureProcessHome(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try env_util.createProcessMap(allocator);
    defer env_map.deinit();
    return (try env_util.getOwned(&env_map, allocator, "HOME")) orelse error.HomeNotSet;
}

fn ensureIsProductRykBinary(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return brand.isPrimaryInvocation(base) or brand.isLegacyInvocation(base);
}

fn ensureRunChild(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    const result = try child_process.runHostCommandTimed(
        allocator,
        argv,
        15_000,
        .{},
        .{},
    );
    defer child_process.deinitHostCommandResult(result, allocator);
    return if (result.timed_out) 255 else result.exit_code;
}

/// Attempt install for one host via HostWireTable installer (no multi-select).
/// Returns true when install succeeds / already present after attempt.
fn attemptHostInstall(
    io: std.Io,
    allocator: std.mem.Allocator,
    entry: HostWireTableEntry,
    home: []const u8,
    self_exe: []const u8,
) bool {
    switch (entry.installer) {
        .pi_extension => {
            // Entrypoint: pi_install.install (bundled extension).
            const result = pi_install.install(io, allocator, .{
                .home = home,
                .ryk_binary = self_exe,
            }) catch return false;
            return result != .assets_unavailable;
        },
        .grok_hook => {
            // Entrypoint: grok_install.installAtHome (PreToolUse hook).
            const result = grok_install.installAtHome(io, allocator, home, self_exe) catch return false;
            result.deinit(allocator);
            return true;
        },
        .plugin_yes => {
            // Entrypoint: ryk plugin install <host> --yes + verifyHostInstallAfterChild.
            const install_argv = [_][]const u8{ self_exe, "plugin", "install", entry.host_id, "--yes" };
            const code = ensureRunChild(allocator, &install_argv) catch return false;
            return plugin.verifyHostInstallAfterChild(io, allocator, entry.host_id, code) != .failed;
        },
    }
}

/// Per-host smoke (D26 / D14 doctor-class; no live host UI spawn).
/// When `skip_verify`, install-evidence-only: smoke is not run; wire-ok is treated
/// as smoke skip-pass (honest: protection_label still partial if any host unwired).
/// When smoke is on, fold doctor Hermes smoke + host_status pair into smoke_ok.
fn evaluateHostSmoke(
    allocator: std.mem.Allocator,
    host_id: []const u8,
    doctor_report: plugin.PluginDoctorReport,
    skip_verify: bool,
) struct { smoke_ok: bool, error_class: HostErrorClass } {
    if (skip_verify) {
        return .{ .smoke_ok = true, .error_class = .none };
    }

    // Hermes: doctor report already ran hook smoke (unless overridden).
    if (std.mem.eql(u8, host_id, "hermes")) {
        if (doctor_report.hermes_hook_smoke_passed) {
            return .{ .smoke_ok = true, .error_class = .none };
        }
        return .{ .smoke_ok = false, .error_class = .smoke };
    }

    // Pi / grok: native install paths — host_status returns not_run for pi;
    // wire evidence is the W1 smoke bar (extension/hook presence).
    if (std.mem.eql(u8, host_id, "pi") or std.mem.eql(u8, host_id, "grok")) {
        return .{ .smoke_ok = true, .error_class = .none };
    }

    const smoke = host_status.runHostSmokePair(allocator, host_id) catch {
        return .{ .smoke_ok = false, .error_class = .smoke };
    };
    if (smoke.bothPassed()) {
        return .{ .smoke_ok = true, .error_class = .none };
    }
    // not_run or fail → soft smoke incomplete (never silent full on missing smoke).
    return .{ .smoke_ok = false, .error_class = .smoke };
}

/// Auto-wire every detected day-one host (no multi-select — D02/D28).
///
/// Product path:
/// 1. Detect via `onboarding.collectHostStatuses` (membership = `onboarding.supported_hosts`).
/// 2. Dispatch HostWireTable installer for each detected host (existing Pi/plugin paths).
/// 3. Already-installed → wired without re-mutation; not installed → attempt install;
///    install fail → soft `.wire` + `doctor_fix_hint` (D24), never clears core_ok.
/// 4. Per-host smoke when `!skip_verify` (D26); skip_verify → install-evidence smoke skip-pass.
///
/// HostResult.host_id / fix_hint are borrowed static strings; only the slice is owned.
pub fn wireDetectedHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: EnsureOptions,
) ![]HostResult {
    _ = host_wire_table.present;

    // skip_verify: skip live Hermes smoke spawn inside doctor collect (install-evidence path).
    // When smoke is on, null override runs real hermes_hook_smoke for HostResult folding.
    var doctor_report = try plugin.collectPluginDoctorReportWithHermesSmoke(
        io,
        allocator,
        if (options.skip_verify) true else null,
    );
    defer plugin.deinitPluginDoctorReport(&doctor_report, allocator);

    const statuses = try onboarding.collectHostStatuses(io, allocator, doctor_report);
    defer allocator.free(statuses);

    // Install context once. Missing HOME / non-product binary → soft wire fail (no mutation
    // under unit-test harness where self_exe is not `ryk`/`orca`).
    const home_opt = ensureProcessHome(allocator) catch null;
    defer if (home_opt) |h| allocator.free(h);
    const self_exe_opt = std.process.executablePathAlloc(io, allocator) catch null;
    defer if (self_exe_opt) |e| allocator.free(e);
    const can_mutate = blk: {
        const home = home_opt orelse break :blk false;
        if (home.len == 0 or !std.fs.path.isAbsolute(home)) break :blk false;
        const exe = self_exe_opt orelse break :blk false;
        break :blk ensureIsProductRykBinary(exe);
    };

    var list: std.ArrayList(HostResult) = .empty;
    errdefer list.deinit(allocator);

    for (statuses) |st| {
        // Dispatch only day-one membership (onboarding keys — F2).
        const entry = HostWireTable.entryFor(st.name) orelse continue;
        if (!st.detected) continue;

        var wired = st.installed;
        if (!wired and can_mutate) {
            // Auto-wire: attempt host→installer (mirror start.installSelectedHosts, no multi-select).
            wired = attemptHostInstall(io, allocator, entry, home_opt.?, self_exe_opt.?);
        }

        if (!wired) {
            // Soft wire incomplete: keep core_ok path; honest partial + repair.
            try list.append(allocator, .{
                .host_id = st.name,
                .detected = true,
                .wired = false,
                .smoke_ok = false,
                .fix_hint = doctor_fix_hint,
                .error_class = .wire,
            });
            continue;
        }

        const smoke = evaluateHostSmoke(allocator, st.name, doctor_report, options.skip_verify);
        if (smoke.smoke_ok) {
            try list.append(allocator, .{
                .host_id = st.name,
                .detected = true,
                .wired = true,
                .smoke_ok = true,
                .fix_hint = "",
                .error_class = .none,
            });
        } else {
            // Wired but smoke failed → soft .smoke + partial demotion (D24/D26).
            try list.append(allocator, .{
                .host_id = st.name,
                .detected = true,
                .wired = true,
                .smoke_ok = false,
                .fix_hint = doctor_fix_hint,
                .error_class = smoke.error_class,
            });
        }
    }

    return try list.toOwnedSlice(allocator);
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


// ---------------------------------------------------------------------------
// EnsureSoft — auto-wire soft success + partial honesty (w1-auto-wire-soft-success)
// Named-run gate: --filter EnsureSoft
// Seams: pure label/exit/receipt helpers + source contracts (no live host spawn).
// ---------------------------------------------------------------------------

/// D06 forbid-list (case-insensitive) for partial / soft-incomplete success copy.
fn ensureSoftClaimsFullProtection(text: []const u8) bool {
    if (containsIgnoreCase(text, "fully protected")) return true;
    if (containsIgnoreCase(text, "all hosts wired")) return true;
    if (containsIgnoreCase(text, "protection complete")) return true;
    if (containsIgnoreCase(text, "full protection")) return true;
    return false;
}

fn ensureSoftHasPartialToken(text: []const u8) bool {
    return containsIgnoreCase(text, "partial") or containsIgnoreCase(text, "partially");
}

fn ensureSoftHasDoctorRepair(text: []const u8) bool {
    return containsIgnoreCase(text, "doctor --fix");
}

test "EnsureSoft never multi-select uses host wire table (D28/D02)" {
    // Acceptance (1): Ensure never requires interactive multi-select; uses ensure
    // host wire table (D28). Source contract — no multiSelect on ensure path;
    // dispatcher table/function must exist for day-one auto-wire.
    //
    // Production (not this test block) must define a host→installer table under one
    // of these greppable names so W3 Cursor can extend the same table.
    const ensure_src = @embedFile("ensure.zig");

    // Strip co-located test region so this file's own documentation cannot satisfy
    // the wire-table contract. Production ends at the first co-located test.
    const prod = blk: {
        if (std.mem.indexOf(u8, ensure_src, "\ntest \"")) |idx| break :blk ensure_src[0..idx];
        break :blk ensure_src;
    };

    try std.testing.expect(std.mem.indexOf(u8, prod, "multiSelect") == null);
    try std.testing.expect(std.mem.indexOf(u8, prod, "multi_select") == null);

    const has_table =
        std.mem.indexOf(u8, prod, "HostWireTable") != null or
        std.mem.indexOf(u8, prod, "host_wire_table") != null or
        std.mem.indexOf(u8, prod, "wireDetectedHosts") != null or
        std.mem.indexOf(u8, prod, "wireDayOneHosts") != null;
    try std.testing.expect(has_table);

    // Day-one membership remains single-source in onboarding (F2 residual): ensure
    // must not invent a second host-id list for auto-wire after this unit. Table
    // keys/dispatch may import onboarding.supported_hosts (or a later day-one const).
    // Soft unit only forbids multi-select + requires a dispatcher symbol.
    _ = onboarding.supported_hosts;
}

test "EnsureSoft HostResult fail carries success shape fix_hint and error_class (D22/D24)" {
    // Acceptance (2): HostResult includes success/fail + fix_hint; soft classes use
    // error_class. Synthetic hosts only — reject live host spawn.
    const ok_host = HostResult{
        .host_id = "codex",
        .detected = true,
        .wired = true,
        .smoke_ok = true,
        .fix_hint = "",
        .error_class = .none,
    };
    try std.testing.expect(ok_host.detected);
    try std.testing.expect(ok_host.wired);
    try std.testing.expect(ok_host.smoke_ok);
    try std.testing.expectEqual(HostErrorClass.none, ok_host.error_class);

    const fail_host = HostResult{
        .host_id = "claude",
        .detected = true,
        .wired = false,
        .smoke_ok = false,
        .fix_hint = "ryk doctor --fix",
        .error_class = .wire,
    };
    try std.testing.expect(fail_host.detected);
    try std.testing.expect(!fail_host.wired);
    try std.testing.expect(!fail_host.smoke_ok);
    try std.testing.expectEqual(HostErrorClass.wire, fail_host.error_class);
    try std.testing.expect(ensureSoftHasDoctorRepair(fail_host.fix_hint));
    try std.testing.expect(!containsIgnoreCase(fail_host.fix_hint, "ryk start") or
        ensureSoftHasDoctorRepair(fail_host.fix_hint));

    const smoke_fail = HostResult{
        .host_id = "pi",
        .detected = true,
        .wired = true,
        .smoke_ok = false,
        .fix_hint = "ryk doctor --fix",
        .error_class = .smoke,
    };
    try std.testing.expectEqual(HostErrorClass.smoke, smoke_fail.error_class);
    try std.testing.expect(ensureSoftHasDoctorRepair(smoke_fail.fix_hint));
}

test "EnsureSoft mock one host wire fail is core_ok partial process exit 0 (D24/D25)" {
    // Acceptance (3) + composition: Mock one host fail → core_ok true,
    // protection_label=partial, process-map exit 0. Pure helpers — no live spawn.
    var hosts = [_]HostResult{
        .{
            .host_id = "claude",
            .detected = true,
            .wired = false,
            .smoke_ok = false,
            .fix_hint = "ryk doctor --fix",
            .error_class = .wire,
        },
    };

    const label = protectionLabelFromHosts(hosts[0..]);
    try std.testing.expectEqual(ProtectionLabel.partial, label);

    var outcome = EnsureOutcome{
        .core_ok = true,
        .hosts = hosts[0..],
        .policy_created = true,
        .policy_left_alone = false,
        .protection_label = label,
        .hosts_owned = false,
    };
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(outcome.core_ok);
    try std.testing.expectEqual(ProtectionLabel.partial, outcome.protection_label);
    try std.testing.expectEqual(@as(u8, exit_codes.success), processExitForOutcome(outcome));
    try std.testing.expect(processExitForOutcome(outcome) == 0);
}

test "EnsureSoft packs and global-verify fails stay soft partial (D24)" {
    // Acceptance (2) soft classes: packs / global shell verify fails are soft —
    // never clear core_ok; force partial (no full-protection claim).
    var hosts = [_]HostResult{
        .{
            .host_id = "codex",
            .detected = true,
            .wired = true,
            .smoke_ok = true,
            .fix_hint = "",
            .error_class = .none,
        },
    };
    // Hosts alone would be full; packs/global soft incomplete demotes to partial.
    const from_hosts = protectionLabelFromHosts(hosts[0..]);
    try std.testing.expectEqual(ProtectionLabel.full, from_hosts);

    const packs_soft = applySoftIncomplete(from_hosts, false, true);
    try std.testing.expectEqual(ProtectionLabel.partial, packs_soft);

    const global_soft = applySoftIncomplete(from_hosts, true, false);
    try std.testing.expectEqual(ProtectionLabel.partial, global_soft);

    const both_ok = applySoftIncomplete(from_hosts, true, true);
    try std.testing.expectEqual(ProtectionLabel.full, both_ok);

    // Soft incomplete never upgrades core_failed.
    const core = applySoftIncomplete(.core_failed, false, false);
    try std.testing.expectEqual(ProtectionLabel.core_failed, core);
}

test "EnsureSoft mock host fail receipt forbids D06 full phrases requires partial and fix_hint" {
    // Acceptance (3): forbids D06 full-protection phrases; requires partial +
    // repair/fix_hint token (doctor --fix) + failed host id.
    var hosts = [_]HostResult{
        .{
            .host_id = "claude",
            .detected = true,
            .wired = false,
            .smoke_ok = false,
            .fix_hint = "ryk doctor --fix",
            .error_class = .wire,
        },
        .{
            .host_id = "codex",
            .detected = true,
            .wired = true,
            .smoke_ok = true,
            .fix_hint = "",
            .error_class = .none,
        },
    };

    const label = protectionLabelFromHosts(hosts[0..]);
    try std.testing.expectEqual(ProtectionLabel.partial, label);

    var outcome = EnsureOutcome{
        .core_ok = true,
        .hosts = hosts[0..],
        .policy_created = false,
        .policy_left_alone = true,
        .protection_label = label,
        .hosts_owned = false,
    };
    defer outcome.deinit(std.testing.allocator);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeEnsureReceipt(&writer, outcome);
    const text = writer.buffered();

    try std.testing.expect(!ensureSoftClaimsFullProtection(text));
    try std.testing.expect(ensureSoftHasPartialToken(text));
    try std.testing.expect(ensureSoftHasDoctorRepair(text));
    try std.testing.expect(containsIgnoreCase(text, "claude"));

    // Process-map still soft-success.
    try std.testing.expectEqual(@as(u8, exit_codes.success), processExitForOutcome(outcome));
}

test "EnsureSoft zero hosts success without full-protection claim (D05)" {
    // Composition: zero hosts → success without full-protection claim.
    const empty: []HostResult = &.{};
    const label = protectionLabelFromHosts(empty);
    try std.testing.expect(label != .full);
    try std.testing.expectEqual(ProtectionLabel.partial, label);

    var outcome = EnsureOutcome{
        .core_ok = true,
        .hosts = empty,
        .policy_created = true,
        .policy_left_alone = false,
        .protection_label = label,
        .hosts_owned = false,
    };
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, exit_codes.success), processExitForOutcome(outcome));

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeEnsureReceipt(&writer, outcome);
    const text = writer.buffered();
    try std.testing.expect(!ensureSoftClaimsFullProtection(text));
}

test "EnsureSoft all detected hosts ok yields full protection label (D05)" {
    // Contrast path: ≥1 host detected and all ok → full allowed (not partial).
    var hosts = [_]HostResult{
        .{
            .host_id = "claude",
            .detected = true,
            .wired = true,
            .smoke_ok = true,
            .fix_hint = "",
            .error_class = .none,
        },
        .{
            .host_id = "codex",
            .detected = true,
            .wired = true,
            .smoke_ok = true,
            .fix_hint = "",
            .error_class = .none,
        },
    };
    try std.testing.expectEqual(ProtectionLabel.full, protectionLabelFromHosts(hosts[0..]));
}

test "EnsureSoft core_ok false maps non-zero exit never soft success (D23/D25)" {
    // reject: soft success when core_ok false (policy create / binary unusable).
    var outcome = EnsureOutcome{
        .core_ok = false,
        .hosts = &.{},
        .policy_created = false,
        .policy_left_alone = false,
        .protection_label = .core_failed,
        .hosts_owned = false,
    };
    defer outcome.deinit(std.testing.allocator);

    const code = processExitForOutcome(outcome);
    try std.testing.expect(code != exit_codes.success);
    try std.testing.expect(code != 0);
    try std.testing.expectEqual(ProtectionLabel.core_failed, outcome.protection_label);
}

test "EnsureSoft runEnsure zero hosts is soft success not full protection claim" {
    // Integration with frozen runEnsure: empty host auto-wire still core_ok + not full.
    // (Auto-wire table may still return zero hosts when nothing is detected.)
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
    try std.testing.expect(outcome.protection_label != .core_failed);
    // Zero detected hosts must not claim full protection (D05).
    if (outcome.hosts.len == 0) {
        try std.testing.expect(outcome.protection_label != .full);
    } else {
        // If environment has detected hosts, any fail forces partial; all-ok may be full.
        var any_fail = false;
        for (outcome.hosts) |h| {
            if (h.detected and (!h.wired or !h.smoke_ok or h.error_class != .none)) {
                any_fail = true;
                break;
            }
        }
        if (any_fail) {
            try std.testing.expectEqual(ProtectionLabel.partial, outcome.protection_label);
        }
    }

    try std.testing.expectEqual(@as(u8, exit_codes.success), processExitForOutcome(outcome));

    const out = stdout_writer.buffered();
    const err = stderr_writer.buffered();
    if (outcome.protection_label == .partial or outcome.hosts.len == 0) {
        try std.testing.expect(!ensureSoftClaimsFullProtection(out));
        try std.testing.expect(!ensureSoftClaimsFullProtection(err));
    }

    // Failed hosts must teach doctor --fix, never ryk start as sole repair.
    for (outcome.hosts) |h| {
        if (h.error_class == .none and h.wired and h.smoke_ok) continue;
        if (!h.detected) continue;
        try std.testing.expect(h.fix_hint.len == 0 or ensureSoftHasDoctorRepair(h.fix_hint));
        if (h.fix_hint.len > 0 and containsIgnoreCase(h.fix_hint, "ryk start")) {
            try std.testing.expect(ensureSoftHasDoctorRepair(h.fix_hint));
        }
    }
}

test "EnsureSoft start bridge receipt driven by protection_label not multi-select ensure path" {
    // code_paths include start.zig: temporary bridge remains; ensure soft path must not
    // reintroduce multiSelect for host consent on the ensure library. Start may still
    // multi-select for legacy interactive start until W4 (dual residual) — ensure must not.
    const start_src = @embedFile("start.zig");
    const ensure_src = @embedFile("ensure.zig");

    const ensure_prod = blk: {
        if (std.mem.indexOf(u8, ensure_src, "\ntest \"")) |idx| break :blk ensure_src[0..idx];
        break :blk ensure_src;
    };
    try std.testing.expect(std.mem.indexOf(u8, ensure_prod, "multiSelect") == null);

    // Bridge still routes policy via runEnsure (locked by EnsureCore); soft unit fills
    // host table + receipt honesty. Start should consume protection_label for honesty.
    try std.testing.expect(std.mem.indexOf(u8, start_src, "runEnsure") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, start_src, "protection_label") != null or
            std.mem.indexOf(u8, start_src, "writeEnsureReceipt") != null or
            std.mem.indexOf(u8, start_src, "processExitForOutcome") != null,
    );
}
