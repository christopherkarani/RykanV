//! `ryk status` — one-glance protection snapshot (P2a).
//! Doctor remains the deep diagnostic; status is the summary.

const std = @import("std");
const orca_policy = @import("orca_core").policy;
const core = @import("orca_core").core;
const supervisor = core.supervisor;

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const suggestions = @import("suggestions.zig");
const onboarding = @import("onboarding.zig");
const pack_state = @import("pack_state.zig");
const plugin = @import("plugin.zig");
const host_status = @import("host_status.zig");
const readiness = @import("readiness.zig");

const Options = struct {
    json: bool = false,
    check: bool = false,
};

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    return commandWithDeps(realExecuteCli, null, io, argv, stdout, stderr);
}

fn realExecuteCli(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const cli = @import("mod.zig");
    return cli.executeDaemonCli(io, argv, stdout, stderr);
}

/// Injectable for tests: execute_cli for packs; daemon_check_fn for health.
pub fn commandWithDeps(
    comptime execute_cli: anytype,
    daemon_check_fn: ?*const fn (std.mem.Allocator, bool) anyerror!void,
    io: std.Io,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const options = parseOptions(argv, stderr) catch return exit_codes.usage;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "status");
            return exit_codes.success;
        }
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // --check/--json are probe contracts: never spawn/ensure the daemon.
    const ensure_running = !(options.check or options.json);
    var snapshot = try collectSnapshot(execute_cli, daemon_check_fn, io, allocator, ensure_running);
    defer snapshot.deinit(allocator);

    if (options.json) {
        try writeJson(stdout, snapshot, options.check);
    } else {
        try writeHuman(stdout, snapshot);
    }
    return snapshot.readiness.exitCode(options.check);
}

fn parseOptions(argv: []const []const u8, stderr: anytype) !Options {
    var options: Options = .{};
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk status", arg, &.{ "--json", "--check", "--help", "-h" }, "status");
        return error.Usage;
    }
    return options;
}

const Snapshot = struct {
    /// Typed daemon health — format at edges (human vs wire).
    daemon_health: onboarding.DaemonHealthStatus,
    daemon_detail: []const u8,
    policy_path: []const u8,
    policy_present: bool,
    policy_valid: bool,
    /// Load/parse error name when present but invalid (owned).
    policy_error: ?[]const u8 = null,
    policy_mode: ?[]const u8,
    policy_preset: ?[]const u8,
    hosts_summary: []const u8,
    packs_summary_line: []const u8,
    packs_known: bool,
    packs_opt_in_count: usize,
    packs_opt_in: []const []const u8,
    next_step: []const u8,
    readiness: readiness.Assessment,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.daemon_detail);
        allocator.free(self.policy_path);
        if (self.policy_error) |err_name| allocator.free(err_name);
        if (self.policy_mode) |m| allocator.free(m);
        if (self.policy_preset) |p| allocator.free(p);
        allocator.free(self.hosts_summary);
        allocator.free(self.packs_summary_line);
        for (self.packs_opt_in) |id| allocator.free(id);
        allocator.free(self.packs_opt_in);
        allocator.free(self.next_step);
        self.* = undefined;
    }
};

fn collectSnapshot(
    comptime execute_cli: anytype,
    daemon_check_fn: ?*const fn (std.mem.Allocator, bool) anyerror!void,
    io: std.Io,
    allocator: std.mem.Allocator,
    ensure_running: bool,
) !Snapshot {
    // Probe paths pass ensure_running=false so --check never mutates runtime.
    const daemon_check = try onboarding.checkDaemonHealth(allocator, ensure_running, daemon_check_fn);
    const daemon_detail = try allocator.dupe(u8, daemon_check.detail);
    errdefer allocator.free(daemon_detail);

    const workspace_root = try onboarding.resolveWorkspaceRoot(io, allocator);
    defer allocator.free(workspace_root);

    const policy_path = try onboarding.policyPath(allocator, workspace_root);
    errdefer allocator.free(policy_path);

    var policy_assessment = try readiness.assessPolicyFile(io, allocator, policy_path);
    const policy_present = policy_assessment.present;
    const policy_valid = policy_assessment.valid;
    // Transfer ownership of error_name into Snapshot.policy_error.
    const policy_error = policy_assessment.error_name;
    policy_assessment.error_name = null;
    errdefer if (policy_error) |value| allocator.free(value);

    var policy_mode: ?[]const u8 = null;
    var policy_preset: ?[]const u8 = null;
    if (policy_present) {
        const meta = readPolicyMeta(io, allocator, policy_path);
        policy_mode = meta.mode;
        policy_preset = meta.preset;
    }
    errdefer if (policy_mode) |m| allocator.free(m);
    errdefer if (policy_preset) |p| allocator.free(p);

    const hosts_summary = try buildHostsSummary(io, allocator);
    errdefer allocator.free(hosts_summary);

    var packs = try pack_state.queryPacksSummary(execute_cli, io, allocator);
    defer packs.deinit(allocator);
    const packs_line = try pack_state.formatSummaryLine(allocator, packs);
    errdefer allocator.free(packs_line);

    var opt_in_owned: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (opt_in_owned.items) |id| allocator.free(id);
        opt_in_owned.deinit(allocator);
    }
    for (packs.opt_in_ids) |id| {
        try opt_in_owned.append(allocator, try allocator.dupe(u8, id));
    }

    const core_ready = readiness.assess(daemon_check.status, policy_present, policy_valid);
    const next_step = try chooseNextStep(allocator, daemon_check.status, policy_present, policy_valid, packs.known);
    errdefer allocator.free(next_step);

    return .{
        .daemon_health = daemon_check.status,
        .daemon_detail = daemon_detail,
        .policy_path = policy_path,
        .policy_present = policy_present,
        .policy_valid = policy_valid,
        .policy_error = policy_error,
        .policy_mode = policy_mode,
        .policy_preset = policy_preset,
        .hosts_summary = hosts_summary,
        .packs_summary_line = packs_line,
        .packs_known = packs.known,
        .packs_opt_in_count = packs.optInCount(),
        .packs_opt_in = try opt_in_owned.toOwnedSlice(allocator),
        .next_step = next_step,
        .readiness = core_ready,
    };
}

fn readPolicyMeta(io: std.Io, allocator: std.mem.Allocator, path: []const u8) struct { mode: ?[]const u8, preset: ?[]const u8 } {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch {
        return .{ .mode = null, .preset = null };
    };
    defer allocator.free(content);

    var mode: ?[]const u8 = null;
    var preset: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "mode:")) {
            const value = std.mem.trim(u8, trimmed["mode:".len..], " \t");
            if (value.len > 0 and mode == null) {
                mode = allocator.dupe(u8, value) catch null;
            }
        }
        // "# Orca preset: generic-agent" or "# Orca policy pack: team-ci"
        if (std.mem.indexOf(u8, trimmed, "preset:")) |idx| {
            const after = std.mem.trim(u8, trimmed[idx + "preset:".len ..], " \t");
            if (after.len > 0 and preset == null) {
                var end = after.len;
                if (std.mem.indexOfScalar(u8, after, ' ')) |sp| end = sp;
                preset = allocator.dupe(u8, after[0..end]) catch null;
            }
        } else if (std.mem.indexOf(u8, trimmed, "policy pack:")) |idx| {
            const after = std.mem.trim(u8, trimmed[idx + "policy pack:".len ..], " \t");
            if (after.len > 0 and preset == null) {
                var end = after.len;
                if (std.mem.indexOfScalar(u8, after, ' ')) |sp| end = sp;
                preset = allocator.dupe(u8, after[0..end]) catch null;
            }
        }
    }
    return .{ .mode = mode, .preset = preset };
}

fn buildHostsSummary(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var doctor_report = plugin.collectPluginDoctorReport(io, allocator) catch {
        return try allocator.dupe(u8, "unknown (plugin scan failed)");
    };
    defer plugin.deinitPluginDoctorReport(&doctor_report, allocator);

    const statuses = try onboarding.collectHostStatuses(io, allocator, doctor_report);
    defer allocator.free(statuses);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var any = false;
    for (statuses) |st| {
        if (!st.detected and !st.installed) continue;
        if (any) try buf.appendSlice(allocator, " ");
        any = true;
        try buf.appendSlice(allocator, st.name);
        if (st.installed) {
            try buf.appendSlice(allocator, "✓");
        } else if (st.detected) {
            try buf.appendSlice(allocator, ":detected");
        }
    }
    // Pi is not a managed plugin host; surface the P1 note briefly.
    if (!any) {
        buf.deinit(allocator);
        return try allocator.dupe(u8, "none detected · pi:not managed");
    }
    try buf.appendSlice(allocator, " pi:not managed");
    return try buf.toOwnedSlice(allocator);
}

fn chooseNextStep(
    allocator: std.mem.Allocator,
    daemon_status: onboarding.DaemonHealthStatus,
    policy_present: bool,
    policy_valid: bool,
    packs_known: bool,
) ![]u8 {
    return switch (daemon_status) {
        .unavailable => try allocator.dupe(u8, "Repair the local companion service, then re-run `ryk status` (shell eval fails closed)."),
        .incompatible => try allocator.dupe(u8, "Upgrade the complete ryk installation, then re-run `ryk status`."),
        .degraded => try allocator.dupe(u8, "Restart the daemon: `ryk shutdown --daemon` then `ryk status`."),
        .compatible => blk: {
            if (!policy_present) {
                break :blk try allocator.dupe(u8, "Run `ryk start` to create a policy and get protected.");
            }
            if (!policy_valid) {
                break :blk try allocator.dupe(u8, "Fix invalid policy (parse/load failed), then re-run `ryk status --check` or `ryk doctor --check`.");
            }
            if (!packs_known) {
                break :blk try allocator.dupe(u8, "Daemon is up but packs could not be listed; run `ryk doctor`.");
            }
            break :blk try allocator.dupe(u8, "Protected path looks healthy. Try `ryk claude` (or another host), then `ryk replay`.");
        },
    };
}

/// Operator-facing three-way protection posture (human status only; not JSON wire).
const ProtectionPosture = enum {
    protected,
    limited,
    off,

    pub fn label(self: ProtectionPosture) []const u8 {
        return switch (self) {
            .protected => "Protected",
            .limited => "Limited",
            .off => "Off",
        };
    }
};

/// Plain-language honesty when Protected: mediation asks/blocks but is not a universal OS sandbox.
/// Status cannot prove live OS-enforced attach.
const mediation_bypass_caveat =
    "Blocks dangerous actions for agents started via ryk; some paths can still bypass.";

/// Limited: daemon may be up, but setup is incomplete or mode is not asking/enforcing.
const limited_caveat_line =
    "Not fully protected yet — setup incomplete or policy not in ask/strict mode.";

/// True when policy mode actively asks or enforces (not observe/trusted).
fn policyModeIsMediating(policy_mode: ?[]const u8) bool {
    const mode_str = policy_mode orelse return false;
    const mode = orca_policy.schema.Mode.parse(mode_str) orelse return false;
    return switch (mode) {
        .ask, .yolo, .strict, .ci, .redteam => true,
        .observe, .trusted => false,
    };
}

/// Map daemon + policy readiness + mode into Protected | Limited | Off.
/// - Off: daemon cannot mediate
/// - Limited: daemon up but policy missing/invalid, or mode does not ask/enforce (e.g. observe)
/// - Protected: core path ready and mode is ask-equivalent or enforcing (wrapper/hook — not OS claim)
fn assessProtectionPosture(
    daemon: onboarding.DaemonHealthStatus,
    policy_present: bool,
    policy_valid: bool,
    policy_mode: ?[]const u8,
) ProtectionPosture {
    if (daemon != .compatible) return .off;
    if (!policy_present or !policy_valid) return .limited;
    if (!policyModeIsMediating(policy_mode)) return .limited;
    return .protected;
}

fn mediationCaveat(posture: ProtectionPosture) ?[]const u8 {
    return switch (posture) {
        .off => null,
        .limited => limited_caveat_line,
        .protected => mediation_bypass_caveat,
    };
}

fn writeHuman(stdout: anytype, s: Snapshot) !void {
    const posture = assessProtectionPosture(s.daemon_health, s.policy_present, s.policy_valid, s.policy_mode);
    try stdout.writeAll("ryk status\n");
    try stdout.print("  State:     {s}\n", .{posture.label()});
    if (mediationCaveat(posture)) |caveat| {
        try stdout.print("  Note:      {s}\n", .{caveat});
    }
    try stdout.print("  Daemon:    {s}  ({s})\n", .{ s.daemon_health.label(), s.daemon_detail });
    if (s.policy_present) {
        try stdout.writeAll("  Policy:    ");
        try stdout.writeAll(s.policy_path);
        try stdout.print("  valid={}", .{s.policy_valid});
        if (s.policy_mode) |mode| try stdout.print("  mode={s}", .{mode});
        if (s.policy_preset) |preset| try stdout.print("  preset={s}", .{preset});
        try stdout.writeAll("\n");
    } else {
        try stdout.print("  Policy:    missing  (expected {s})\n", .{s.policy_path});
    }
    try stdout.print("  Ready:     {}  ({s})\n", .{ s.readiness.ready, s.readiness.state.label() });
    try stdout.print("  Hosts:     {s}\n", .{s.hosts_summary});
    try stdout.print("  Packs:     {s}\n", .{s.packs_summary_line});
    try stdout.print("  Next:      {s}\n", .{s.next_step});
}

fn writeJson(stdout: anytype, s: Snapshot, check_mode: bool) !void {
    // Shared readiness envelope leaves the root object open after policy so we can append.
    // Wire vocabulary only — never human labels like "healthy".
    try readiness.writeJsonEnvelope(stdout, .{
        .assessment = s.readiness,
        .check = check_mode,
        .daemon_status = readiness.daemonWireLabel(s.daemon_health),
        .daemon_detail = s.daemon_detail,
        .policy_path = s.policy_path,
        .policy_error = s.policy_error,
        .policy_mode = s.policy_mode,
        .policy_preset = s.policy_preset,
        .close_object = false,
    });

    try stdout.writeAll("  \"hosts\": {\"summary\":");
    try core.util.writeJsonString(stdout, s.hosts_summary);
    try stdout.writeAll("},\n");

    try stdout.writeAll("  \"packs\": {");
    try stdout.print("\"known\":{},\"opt_in_count\":{d},\"opt_in\":[", .{ s.packs_known, s.packs_opt_in_count });
    for (s.packs_opt_in, 0..) |id, i| {
        if (i > 0) try stdout.writeAll(",");
        try core.util.writeJsonString(stdout, id);
    }
    try stdout.writeAll("],\"summary\":");
    try core.util.writeJsonString(stdout, s.packs_summary_line);
    try stdout.writeAll("},\n");

    try stdout.writeAll("  \"next\": ");
    try core.util.writeJsonString(stdout, s.next_step);
    try stdout.writeAll("\n");
    try stdout.writeAll("}\n");
}

// ─── Tests ───────────────────────────────────────────────────────────────────

fn fakePacksHealthy(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try std.testing.expectEqualStrings("packs", argv[0]);
    try stdout.writeAll(
        \\{"packs":[{"id":"core.git","name":"Git","category":"core","description":"g","enabled":true,"safe_pattern_count":1,"destructive_pattern_count":1},{"id":"system.disk","name":"Disk","category":"system","description":"d","enabled":true,"safe_pattern_count":1,"destructive_pattern_count":1},{"id":"containers.docker","name":"Docker","category":"containers","description":"c","enabled":true,"safe_pattern_count":1,"destructive_pattern_count":1}],"enabled_count":3,"total_count":3}
    );
    return exit_codes.success;
}

fn fakePacksFail(_: std.Io, _: []const []const u8, _: anytype, _: anytype) !u8 {
    return error.SocketConnectFailed;
}

fn mockDaemonOk(_: std.mem.Allocator, _: bool) anyerror!void {}

fn mockDaemonDown(_: std.mem.Allocator, _: bool) anyerror!void {
    return error.SocketConnectFailed;
}

test "assessProtectionPosture maps to Protected Limited Off" {
    try std.testing.expectEqual(ProtectionPosture.off, assessProtectionPosture(.unavailable, true, true, "ask"));
    try std.testing.expectEqual(ProtectionPosture.off, assessProtectionPosture(.incompatible, true, true, "ask"));
    try std.testing.expectEqual(ProtectionPosture.off, assessProtectionPosture(.degraded, false, false, null));
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, false, false, null));
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, true, false, "ask"));
    // Valid policy + ask/strict → Protected
    try std.testing.expectEqual(ProtectionPosture.protected, assessProtectionPosture(.compatible, true, true, "ask"));
    try std.testing.expectEqual(ProtectionPosture.protected, assessProtectionPosture(.compatible, true, true, "strict"));
    try std.testing.expectEqual(ProtectionPosture.protected, assessProtectionPosture(.compatible, true, true, "ci"));
    try std.testing.expectEqual(ProtectionPosture.protected, assessProtectionPosture(.compatible, true, true, "redteam"));
    // observe/trusted/null/unknown: valid policy but not actually asking/blocking → Limited
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, true, true, "observe"));
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, true, true, "trusted"));
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, true, true, null));
    try std.testing.expectEqual(ProtectionPosture.limited, assessProtectionPosture(.compatible, true, true, "mystery"));
    try std.testing.expectEqualStrings("Protected", ProtectionPosture.protected.label());
    try std.testing.expectEqualStrings("Limited", ProtectionPosture.limited.label());
    try std.testing.expectEqualStrings("Off", ProtectionPosture.off.label());
}

test "mediationCaveat distinct for Protected vs Limited" {
    try std.testing.expect(mediationCaveat(.off) == null);
    const protected_note = mediationCaveat(.protected).?;
    const limited_note = mediationCaveat(.limited).?;
    try std.testing.expect(std.mem.indexOf(u8, protected_note, "Blocks dangerous actions for agents started via ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, protected_note, "some paths can still bypass") != null);
    // Limited must not reuse the affirmative blocking caveat.
    try std.testing.expect(std.mem.indexOf(u8, limited_note, "Blocks dangerous actions") == null);
    try std.testing.expect(std.mem.indexOf(u8, limited_note, "Not fully protected yet") != null);
    try std.testing.expect(!std.mem.eql(u8, protected_note, limited_note));
}

fn fixtureSnapshot(
    daemon: onboarding.DaemonHealthStatus,
    policy_present: bool,
    policy_valid: bool,
) Snapshot {
    return fixtureSnapshotMode(daemon, policy_present, policy_valid, if (policy_present) "ask" else null);
}

fn fixtureSnapshotMode(
    daemon: onboarding.DaemonHealthStatus,
    policy_present: bool,
    policy_valid: bool,
    policy_mode: ?[]const u8,
) Snapshot {
    return .{
        .daemon_health = daemon,
        .daemon_detail = "detail",
        .policy_path = "/tmp/.orca/policy.yaml",
        .policy_present = policy_present,
        .policy_valid = policy_valid,
        .policy_error = null,
        .policy_mode = policy_mode,
        .policy_preset = if (policy_present) "generic-agent" else null,
        .hosts_summary = "none detected · pi:not managed",
        .packs_summary_line = "unknown",
        .packs_known = false,
        .packs_opt_in_count = 0,
        .packs_opt_in = &.{},
        .next_step = "next",
        .readiness = readiness.assess(daemon, policy_present, policy_valid),
    };
}

test "writeHuman Protected shows State and mediation bypass caveat" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHuman(&w, fixtureSnapshot(.compatible, true, true));
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Protected") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Limited") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Off") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions for agents started via ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "some paths can still bypass") != null);
}

test "writeHuman Limited (missing policy) shows incomplete note not blocking caveat" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHuman(&w, fixtureSnapshot(.compatible, false, false));
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Not fully protected yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions") == null);
}

test "writeHuman observe mode is Limited not Protected with blocking claim" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHuman(&w, fixtureSnapshotMode(.compatible, true, true, "observe"));
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Protected") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mode=observe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Not fully protected yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions") == null);
}

test "writeHuman Off shows State without mediation caveat" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHuman(&w, fixtureSnapshot(.unavailable, false, false));
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Off") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Note:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions") == null);
}

test "status human healthy path shows section labels" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithDeps(fakePacksHealthy, mockDaemonOk, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "State:") != null);
    // Three-way posture: daemon mock is ok → Protected or Limited depending on workspace policy/mode.
    const has_protected = std.mem.indexOf(u8, out, "State:     Protected") != null;
    const has_limited = std.mem.indexOf(u8, out, "State:     Limited") != null;
    try std.testing.expect(has_protected or has_limited);
    if (has_protected) {
        try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions for agents started via ryk") != null);
    }
    if (has_limited) {
        try std.testing.expect(std.mem.indexOf(u8, out, "Not fully protected yet") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "Daemon:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "healthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hosts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Packs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "containers.docker") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Next:") != null);
}

test "status daemon unavailable path still exits 0 without --check" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithDeps(fakePacksFail, mockDaemonDown, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "State:     Off") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Blocks dangerous actions") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Packs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown") != null or std.mem.indexOf(u8, out, "fails closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Next:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Protected path looks healthy") == null);
}

test "status --check fails when daemon unavailable" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithDeps(fakePacksFail, mockDaemonDown, std.testing.io, &.{"--check"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Ready:") != null);
}

test "status --json includes ready state and policy.valid" {
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithDeps(fakePacksHealthy, mockDaemonOk, std.testing.io, &.{"--json"}, &stdout_writer, &stderr_writer);
    // Without --check, report always succeeds even if core is not ready.
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"daemon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"check\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hosts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"packs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"next\"") != null);
    // Wire vocabulary only — never human "healthy".
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"compatible\"") != null or std.mem.indexOf(u8, out, "\"status\": \"compatible\"") != null or std.mem.indexOf(u8, out, "\"status\":\"unavailable\"") != null or std.mem.indexOf(u8, out, "\"status\": \"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"healthy\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\": \"healthy\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    try std.testing.expect(parsed.value.object.get("ready") != null);
    try std.testing.expect(parsed.value.object.get("state") != null);
    const daemon_obj = parsed.value.object.get("daemon").?.object;
    const wire_status = daemon_obj.get("status").?.string;
    try std.testing.expect(std.mem.eql(u8, wire_status, "compatible") or std.mem.eql(u8, wire_status, "unavailable") or std.mem.eql(u8, wire_status, "incompatible") or std.mem.eql(u8, wire_status, "degraded"));
    try std.testing.expect(!std.mem.eql(u8, wire_status, "healthy"));
    const policy_obj = parsed.value.object.get("policy").?.object;
    try std.testing.expect(policy_obj.get("valid") != null);
    try std.testing.expect(policy_obj.get("present") != null);
}

test "status --check does not ensure-run the daemon" {
    const Spy = struct {
        var ensure_running: ?bool = null;
        fn check(_: std.mem.Allocator, ensure: bool) anyerror!void {
            ensure_running = ensure;
        }
    };
    Spy.ensure_running = null;
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    _ = try commandWithDeps(fakePacksFail, Spy.check, std.testing.io, &.{"--check"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(false, Spy.ensure_running.?);
}

test "status --check --json fails when daemon down and sets check true" {
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithDeps(fakePacksFail, mockDaemonDown, std.testing.io, &.{ "--check", "--json" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ready\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"state\": \"not_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"check\": true") != null);
}

test "status rejects unknown options" {
    var stdout_buf: [64]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithDeps(fakePacksHealthy, mockDaemonOk, std.testing.io, &.{"--nope"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help status") != null);
}

test "chooseNextStep requires valid policy for healthy copy" {
    const missing = try chooseNextStep(std.testing.allocator, .compatible, false, false, true);
    defer std.testing.allocator.free(missing);
    // Limited / no policy: teach public door `ryk start` first (not demoted `init`).
    try std.testing.expect(std.mem.indexOf(u8, missing, "ryk start") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "init") == null);

    const invalid = try chooseNextStep(std.testing.allocator, .compatible, true, false, true);
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "invalid policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "Protected path looks healthy") == null);

    const healthy = try chooseNextStep(std.testing.allocator, .compatible, true, true, true);
    defer std.testing.allocator.free(healthy);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "Protected path looks healthy") != null);
    // Healthy path: host alias + replay — not demoted `ryk run -- <agent>`.
    try std.testing.expect(std.mem.indexOf(u8, healthy, "ryk claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "ryk replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "ryk run") == null);
}

// Silence unused imports when tests are filtered
test {
    _ = orca_policy;
    _ = supervisor;
    _ = host_status;
    _ = readiness;
}
