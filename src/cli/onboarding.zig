const std = @import("std");

const core = @import("orca_core").core;
const supervisor = core.supervisor;

const exit_codes = @import("exit_codes.zig");
const init = @import("init.zig");
const plugin = @import("plugin.zig");
const daemon = @import("daemon.zig");
const shell_eval = @import("shell_eval.zig");
const resource_root = @import("../resource_root.zig");
const suggestions = @import("suggestions.zig");

pub const default_preset = "generic-agent";

/// Agent hosts wired during setup / quickstart integration.
pub const supported_hosts = [_][]const u8{ "codex", "claude", "opencode", "openclaw", "hermes" };

pub const Flags = struct {
    auto: bool = false,
    preset: []const u8 = default_preset,
};

/// Paid-beta protection paths configured by `ryk start`.
pub const ProtectionMode = enum {
    command_guard,
    firewall,
    maximum_protection,

    pub fn label(self: ProtectionMode) []const u8 {
        return switch (self) {
            .command_guard => "Command Guard",
            .firewall => "Firewall",
            .maximum_protection => "Maximum Protection",
        };
    }

    pub fn description(self: ProtectionMode) []const u8 {
        return switch (self) {
            .command_guard => "Hook-based shell command blocking via the in-process Zig shell_engine (fast, host-integrated).",
            .firewall => "Sandboxed sessions through `orca run` with network, file, and secret policies.",
            .maximum_protection => "Command Guard plus Firewall together (recommended).",
        };
    }

    pub fn needsCommandGuard(self: ProtectionMode) bool {
        return self == .command_guard or self == .maximum_protection;
    }

    pub fn needsFirewall(self: ProtectionMode) bool {
        return self == .firewall or self == .maximum_protection;
    }

    pub fn parse(text: []const u8) ?ProtectionMode {
        if (std.mem.eql(u8, text, "command-guard") or std.mem.eql(u8, text, "command_guard")) return .command_guard;
        if (std.mem.eql(u8, text, "firewall")) return .firewall;
        if (std.mem.eql(u8, text, "maximum") or std.mem.eql(u8, text, "maximum-protection") or std.mem.eql(u8, text, "maximum_protection")) return .maximum_protection;
        return null;
    }
};

pub const StartFlags = struct {
    auto: bool = false,
    preset: []const u8 = default_preset,
    protection: ?ProtectionMode = null,
    hosts_csv: ?[]const u8 = null,
    skip_verify: bool = false,
};

pub const DaemonHealthStatus = enum {
    compatible,
    unavailable,
    incompatible,
    degraded,

    pub fn label(self: DaemonHealthStatus) []const u8 {
        return switch (self) {
            .compatible => "healthy",
            .unavailable => "unavailable",
            .incompatible => "incompatible",
            .degraded => "degraded",
        };
    }
};

pub const DaemonCheck = struct {
    status: DaemonHealthStatus,
    detail: []const u8,
    remediation: []const u8,
};

pub const HostStatus = struct {
    name: []const u8,
    detected: bool,
    installed: bool,
};

pub const VerificationOutcome = struct {
    safe_allowed: bool,
    dangerous_denied: bool,
    hook_verified: ?bool = null,
    firewall_ready: ?bool = null,
    detail: []const u8,

    pub fn passed(self: VerificationOutcome) bool {
        if (!self.safe_allowed or !self.dangerous_denied) return false;
        if (self.hook_verified) |hook_ok| if (!hook_ok) return false;
        if (self.firewall_ready) |firewall_ok| if (!firewall_ok) return false;
        return true;
    }
};

pub const safe_verification_command = "git status";
pub const dangerous_verification_command = "rm -rf /";
pub const hook_safe_fixture = "tests/fixtures/hook-safe.json";
pub const hook_danger_fixture = "tests/fixtures/hook-danger.json";

pub const EnsurePolicyMessages = struct {
    missing: []const u8,
    exists: ?[]const u8 = null,
};

pub fn resolveWorkspaceRoot(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return resolveWorkspaceRootFromCwd(io, allocator, std.Io.Dir.cwd());
}

/// Resolves the Orca workspace root starting from a caller-provided working directory.
pub fn resolveWorkspaceRootFromCwd(io: std.Io, allocator: std.mem.Allocator, cwd: std.Io.Dir) ![]u8 {
    const cwd_path = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd_path);
    return supervisor.resolveWorkspaceRoot(io, allocator, null, cwd_path) catch try allocator.dupe(u8, cwd_path);
}

pub fn policyPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace_root, ".orca", "policy.yaml" });
}

pub fn policyExists(io: std.Io, workspace_root: []const u8) bool {
    const page_alloc = std.heap.page_allocator;
    const path = policyPath(page_alloc, workspace_root) catch return false;
    defer page_alloc.free(path);
    return plugin.fileExistsAbsolute(io, path);
}

/// Creates `.orca/policy.yaml` when missing. Never passes `--quiet` so init prints next steps.
pub fn ensurePolicy(
    io: std.Io,
    cwd: std.Io.Dir,
    workspace_root: []const u8,
    preset: []const u8,
    stdout: anytype,
    stderr: anytype,
    messages: EnsurePolicyMessages,
) !u8 {
    if (policyExists(io, workspace_root)) {
        if (messages.exists) |text| try stdout.writeAll(text);
        return exit_codes.success;
    }

    try stdout.writeAll(messages.missing);
    const init_argv = &[_][]const u8{ "--preset", preset };
    return init.command(io, cwd, init_argv, stdout, stderr);
}

/// Guided setup when both stdin and stdout are TTYs (matches quickstart auto-setup gate).
pub fn interactiveSetupDesired(io: std.Io) bool {
    return (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);
}

/// Parses `--auto`, `--yes` (optional alias), and `--preset` for setup-like commands.
pub fn parseFlags(argv: []const []const u8, stderr: anytype, command_label: []const u8, yes_is_auto: bool) !Flags {
    var flags: Flags = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--auto") or std.mem.eql(u8, arg, "--no-interact")) {
            flags.auto = true;
            continue;
        }
        if (yes_is_auto and std.mem.eql(u8, arg, "--yes")) {
            flags.auto = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--preset")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.print("{s}: --preset requires a preset name.\n", .{command_label});
                return error.Usage;
            }
            flags.preset = argv[index];
            continue;
        }
        const help_command = if (std.mem.eql(u8, command_label, "orca quickstart")) "quickstart" else "setup";
        if (yes_is_auto) {
            try suggestions.writeUnknownOption(stderr, command_label, arg, &.{ "--auto", "--no-interact", "--yes", "--preset" }, help_command);
        } else {
            try suggestions.writeUnknownOption(stderr, command_label, arg, &.{ "--auto", "--no-interact", "--preset" }, help_command);
        }
        return error.Usage;
    }
    return flags;
}

pub fn defaultProtectionMode() ProtectionMode {
    return .maximum_protection;
}

pub fn hostHookEvent(host: []const u8) ?[]const u8 {
    const host_status = @import("host_status.zig");
    return hookEventFromGate(host, host_status.shellGate(host));
}

fn hookEventFromGate(host: []const u8, gate: []const u8) ?[]const u8 {
    // shellGate also returns human-readable coverage labels for extension-managed hosts.
    // Only known hook event identifiers may enter hook installation or smoke paths.
    if (std.mem.eql(u8, host, "pi")) return null;
    const hook_events = [_][]const u8{
        "PreToolUse",
        "tool.execute.before",
        "tool.before",
        "pre_tool_call",
    };
    for (hook_events) |event| {
        if (std.mem.eql(u8, gate, event)) return gate;
    }
    return null;
}

pub fn isSupportedHost(name: []const u8) bool {
    for (supported_hosts) |host| {
        if (std.mem.eql(u8, host, name)) return true;
    }
    return false;
}

pub fn collectHostStatuses(io: std.Io, allocator: std.mem.Allocator, doctor_report: plugin.PluginDoctorReport) ![]HostStatus {
    var list: std.ArrayList(HostStatus) = .empty;
    errdefer list.deinit(allocator);

    for (supported_hosts) |host_name| {
        const detected = plugin.binaryInPath(io, allocator, host_name);
        const installed = plugin.hostPluginInstalledFromReport(host_name, doctor_report);
        try list.append(allocator, .{
            .name = host_name,
            .detected = detected,
            .installed = installed,
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn parseHostsCsv(allocator: std.mem.Allocator, csv: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;
        if (!isSupportedHost(trimmed)) return error.UnsupportedHost;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try list.toOwnedSlice(allocator);
}

pub fn deinitHostList(allocator: std.mem.Allocator, hosts: [][]const u8) void {
    for (hosts) |host| allocator.free(host);
    allocator.free(hosts);
}

pub fn daemonRemediation(status: DaemonHealthStatus) []const u8 {
    return switch (status) {
        .compatible => "Daemon is ready.",
        .unavailable => "Install orca-daemon beside orca, then run: orca doctor",
        .incompatible => "Upgrade orca and orca-daemon together, then run: orca doctor",
        .degraded => "Restart the daemon: orca shutdown --daemon && orca doctor",
    };
}

pub fn checkDaemonHealth(
    allocator: std.mem.Allocator,
    ensure_running: bool,
    check_fn: ?*const fn (std.mem.Allocator, bool) anyerror!void,
) !DaemonCheck {
    const checker = check_fn orelse defaultDaemonCheck;
    checker(allocator, ensure_running) catch |err| {
        const status: DaemonHealthStatus = if (err == error.ProtocolMismatch)
            .incompatible
        else if (err == error.MissingHandshake or err == error.HandshakeMalformed or err == error.DaemonProtocolError or err == error.ResponseParseFailed)
            .degraded
        else
            .unavailable;
        const detail = daemonCheckDetail(err);
        return .{
            .status = status,
            .detail = detail,
            .remediation = daemonRemediation(status),
        };
    };

    return .{
        .status = .compatible,
        .detail = "Daemon is reachable and protocol-compatible.",
        .remediation = daemonRemediation(.compatible),
    };
}

fn defaultDaemonCheck(allocator: std.mem.Allocator, ensure_running: bool) !void {
    if (ensure_running) {
        try daemon.ensureDaemonRunning(allocator);
    } else {
        try daemon.checkCompatibility(allocator);
    }
}

fn daemonCheckDetail(err: anyerror) []const u8 {
    return daemon.errors.onboardingDetail(err);
}

pub fn verifyShellEvaluation(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    evaluator: ?shell_eval.ShellCommandEvaluatorFn,
) !VerificationOutcome {
    const eval_fn = evaluator orelse shell_eval.defaultEvaluator;

    var safe = try shell_eval.evaluateCommand(
        allocator,
        .strict,
        &.{ "git", "status" },
        cwd,
        eval_fn,
        null,
        null,
        &.{},
    );
    defer safe.deinit(allocator);

    var dangerous = try shell_eval.evaluateCommand(
        allocator,
        .strict,
        &.{ "rm", "-rf", "/" },
        cwd,
        eval_fn,
        null,
        null,
        &.{},
    );
    defer dangerous.deinit(allocator);

    const safe_ok = safe.decision.result == .allow;
    const danger_ok = dangerous.decision.result == .deny;

    return .{
        .safe_allowed = safe_ok,
        .dangerous_denied = danger_ok,
        .detail = if (safe_ok and danger_ok)
            "Safe command allowed and dangerous command denied."
        else if (!safe_ok and !danger_ok)
            "Both safe and dangerous verification commands failed."
        else if (!safe_ok)
            "Safe command was unexpectedly denied."
        else
            "Dangerous command was not denied.",
    };
}

fn resolveHookFixture(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, relative_path: []const u8) ![]u8 {
    return resource_root.resolveResourcePath(io, allocator, .{ .workspace_root = workspace_root }, relative_path);
}

pub fn verifyHookPath(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, host: []const u8) !bool {
    _ = io;
    _ = workspace_root;
    const host_status = @import("host_status.zig");
    const smoke = host_status.runHostSmokePair(allocator, host) catch return false;
    return smoke.bothPassed();
}

pub fn verifyFirewallReady(io: std.Io, workspace_root: []const u8) bool {
    return policyExists(io, workspace_root);
}

pub fn runVerification(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    mode: ProtectionMode,
    selected_hosts: []const []const u8,
    evaluator: ?shell_eval.ShellCommandEvaluatorFn,
) !VerificationOutcome {
    var outcome = if (mode.needsCommandGuard())
        try verifyShellEvaluation(allocator, workspace_root, evaluator)
    else
        VerificationOutcome{
            .safe_allowed = true,
            .dangerous_denied = true,
            .detail = "Firewall-only mode: shell command verification skipped.",
        };
    outcome.hook_verified = if (mode.needsCommandGuard()) blk: {
        if (selected_hosts.len == 0) break :blk null;
        break :blk try verifyHookPath(io, allocator, workspace_root, selected_hosts[0]);
    } else null;
    outcome.firewall_ready = if (mode.needsFirewall()) verifyFirewallReady(io, workspace_root) else null;
    if (outcome.hook_verified == false or outcome.firewall_ready == false) {
        if (!outcome.passed()) {
            // detail already set by shell verification
        } else if (outcome.hook_verified == false) {
            outcome.detail = "Shell evaluation passed, but hook verification failed.";
        } else if (outcome.firewall_ready == false) {
            outcome.detail = "Shell evaluation passed, but firewall policy is missing.";
        }
    }
    return outcome;
}

/// Parses `ryk start` flags.
pub fn parseStartFlags(argv: []const []const u8, stderr: anytype) !StartFlags {
    var flags: StartFlags = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--auto") or std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--no-interact")) {
            flags.auto = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-verify")) {
            flags.skip_verify = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--preset")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("ryk start: --preset requires a preset name.\n");
                return error.Usage;
            }
            flags.preset = argv[index];
            continue;
        }
        // --protection is intentionally not a public flag (no grade menu on Safe Launch).
        // ProtectionMode is selected automatically via defaultProtectionMode(); tests/internal
        // callers may still set StartFlags.protection programmatically.
        if (std.mem.eql(u8, arg, "--hosts")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("ryk start: --hosts requires a comma-separated host list.\n");
                return error.Usage;
            }
            flags.hosts_csv = argv[index];
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk start", arg, &.{ "--auto", "--yes", "--no-interact", "--skip-verify", "--preset", "--hosts" }, "start");
        return error.Usage;
    }
    return flags;
}

test "onboarding policyPath and policyExists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try std.testing.expect(!policyExists(std.testing.io, root));

    const path = try policyPath(std.testing.allocator, root);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".orca/policy.yaml"));

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "version: 1\nmode: observe\n");
    }

    try std.testing.expect(policyExists(std.testing.io, root));
}

test "onboarding parseFlags accepts preset and auto" {
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = try parseFlags(
        &.{ "--auto", "--preset", "strict-local" },
        &stderr_writer,
        "orca setup",
        true,
    );
    try std.testing.expect(flags.auto);
    try std.testing.expectEqualStrings("strict-local", flags.preset);
}

test "onboarding protection mode parsing and requirements" {
    try std.testing.expectEqual(ProtectionMode.command_guard, ProtectionMode.parse("command-guard").?);
    try std.testing.expectEqual(ProtectionMode.firewall, ProtectionMode.parse("firewall").?);
    try std.testing.expectEqual(ProtectionMode.maximum_protection, ProtectionMode.parse("maximum").?);
    try std.testing.expect(ProtectionMode.command_guard.needsCommandGuard());
    try std.testing.expect(!ProtectionMode.firewall.needsCommandGuard());
    try std.testing.expect(ProtectionMode.maximum_protection.needsCommandGuard());
    try std.testing.expect(ProtectionMode.maximum_protection.needsFirewall());
}

test "onboarding hostHookEvent maps hooks and rejects Pi coverage labels" {
    try std.testing.expectEqualStrings("PreToolUse", hostHookEvent("codex").?);
    try std.testing.expectEqualStrings("PreToolUse", hostHookEvent("claude").?);
    try std.testing.expectEqualStrings("tool.execute.before", hostHookEvent("opencode").?);
    try std.testing.expectEqualStrings("tool.before", hostHookEvent("openclaw").?);
    try std.testing.expectEqualStrings("pre_tool_call", hostHookEvent("hermes").?);

    try std.testing.expect(hostHookEvent("pi") == null);
    try std.testing.expect(hookEventFromGate("pi", "evaluate bash") == null);
    try std.testing.expect(hookEventFromGate("pi", "bash+write+edit+read") == null);
    try std.testing.expect(hookEventFromGate("pi", "extension-managed (smoke not run)") == null);
    try std.testing.expect(hookEventFromGate("future-host", "bash+write") == null);
}

test "onboarding parseStartFlags accepts hosts and preset without protection flag" {
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = try parseStartFlags(
        &.{ "--auto", "--hosts", "codex,claude", "--preset", "generic-agent", "--skip-verify" },
        &stderr_writer,
    );
    try std.testing.expect(flags.auto);
    try std.testing.expect(flags.skip_verify);
    try std.testing.expect(flags.protection == null);
    try std.testing.expectEqualStrings("codex,claude", flags.hosts_csv.?);
    try std.testing.expectEqualStrings("generic-agent", flags.preset);
}

test "onboarding parseStartFlags rejects public protection flag" {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const result = parseStartFlags(&.{ "--auto", "--protection", "firewall" }, &stderr_writer);
    try std.testing.expectError(error.Usage, result);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--protection") != null or std.mem.indexOf(u8, stderr_writer.buffered(), "unknown option") != null);
}

test "onboarding default protection is maximum (best available Ask posture path)" {
    try std.testing.expectEqual(ProtectionMode.maximum_protection, defaultProtectionMode());
    try std.testing.expect(defaultProtectionMode().needsCommandGuard());
    try std.testing.expect(defaultProtectionMode().needsFirewall());
}

test "onboarding parseHostsCsv validates supported hosts" {
    const allocator = std.testing.allocator;
    const hosts = try parseHostsCsv(allocator, "codex, hermes");
    defer deinitHostList(allocator, hosts);
    try std.testing.expectEqual(@as(usize, 2), hosts.len);
    try std.testing.expectEqualStrings("codex", hosts[0]);
    try std.testing.expectEqualStrings("hermes", hosts[1]);
    try std.testing.expectError(error.UnsupportedHost, parseHostsCsv(allocator, "cursor"));
}

pub fn mockOnboardingEvaluator(allocator: std.mem.Allocator, shell_event: shell_eval.ShellCommandEvent) daemon.DaemonError!std.json.Parsed(daemon.DaemonResponse) {
    if (std.mem.indexOf(u8, shell_event.command, "rm -rf") != null) {
        return shell_eval.mockDaemonDenyEvaluator(allocator, shell_event);
    }
    return shell_eval.mockDaemonAllowEvaluator(allocator, shell_event);
}

test "onboarding verifyShellEvaluation with selective mock" {
    const allocator = std.testing.allocator;
    const outcome = try verifyShellEvaluation(allocator, null, mockOnboardingEvaluator);
    try std.testing.expect(outcome.safe_allowed);
    try std.testing.expect(outcome.dangerous_denied);
    try std.testing.expect(outcome.passed());
}

test "onboarding checkDaemonHealth reports unavailable from mock checker" {
    const failing_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {
            return error.DaemonBinaryNotFound;
        }
    }.check;

    const check = try checkDaemonHealth(std.testing.allocator, false, failing_checker);
    try std.testing.expectEqual(DaemonHealthStatus.unavailable, check.status);
    try std.testing.expect(std.mem.indexOf(u8, check.detail, "orca-daemon") != null);
}

test "onboarding checkDaemonHealth reports incompatible protocol" {
    const failing_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {
            return error.ProtocolMismatch;
        }
    }.check;

    const check = try checkDaemonHealth(std.testing.allocator, false, failing_checker);
    try std.testing.expectEqual(DaemonHealthStatus.incompatible, check.status);
}

test "onboarding verifyFirewallReady requires policy file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try std.testing.expect(!verifyFirewallReady(std.testing.io, root));
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    try std.testing.expect(verifyFirewallReady(std.testing.io, root));
}

test "onboarding runVerification for firewall skips shell evaluation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }

    const selected = [_][]const u8{};
    const outcome = try runVerification(
        std.testing.allocator,
        std.testing.io,
        root,
        .firewall,
        &selected,
        null,
    );
    try std.testing.expect(outcome.passed());
    try std.testing.expectEqualStrings("Firewall-only mode: shell command verification skipped.", outcome.detail);
}

test "onboarding runVerification for maximum protection with mocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }

    const selected = [_][]const u8{};
    var outcome = try runVerification(
        std.testing.allocator,
        std.testing.io,
        root,
        .maximum_protection,
        &selected,
        mockOnboardingEvaluator,
    );
    try std.testing.expect(outcome.passed());
}
