const std = @import("std");
const builtin = @import("builtin");
const env_util = @import("../env_util.zig");
const core = @import("orca_core").core;
const supervisor = core.supervisor;
const orca_mcp = @import("../mcp/mod.zig");
const orca_policy = @import("orca_core").policy;
const sandbox = @import("../sandbox/mod.zig");
const resource_root = @import("../resource_root.zig");
const tui = @import("../tui/mod.zig");
const style = @import("style.zig");

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const cli = @import("mod.zig");
const suggestions = @import("suggestions.zig");
const plugin = @import("plugin.zig");
const onboarding = @import("onboarding.zig");
const host_status = @import("host_status.zig");
const pack_state = @import("pack_state.zig");
const readiness = @import("readiness.zig");

const DoctorCapability = struct {
    label: []const u8,
    feature: ?sandbox.backend.Feature = null,
    capability: ?core.platform.Capability = null,
};

const doctor_capabilities = [_]DoctorCapability{
    .{ .label = "process supervision", .feature = .process_supervision },
    .{ .label = "env filtering", .feature = .env_filtering },
    .{ .label = "staged writes", .feature = .path_staging },
    .{ .label = "mcp stdio proxy", .feature = .mcp_stdio_proxy },
    .{ .label = "network policy engine", .capability = .network_policy_engine },
    .{ .label = "network observation", .feature = .network_observe },
    .{ .label = "transparent network enforcement", .feature = .network_enforce },
    .{ .label = "proxy-mediated enforcement", .capability = .network_proxy_enforce },
    .{ .label = "strong sandbox", .feature = .strong_sandbox },
};

const AgentBinary = struct {
    name: []const u8,
    command: []const u8,
};

const known_agent_binaries = [_]AgentBinary{
    .{ .name = "Claude Code", .command = "claude" },
    .{ .name = "Codex", .command = "codex" },
    .{ .name = "Cursor", .command = "cursor" },
    .{ .name = "OpenCode", .command = "opencode" },
    .{ .name = "Cline/Roo", .command = "cline" },
};

const IntegrationContext = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    git_present: bool,
    policy_present: bool,
    policy_valid: bool,
    policy_error: ?[]const u8 = null,
    agent_found: []const AgentBinary,
    mcp_manifest_count: usize,
    mcp_manifest_invalid_count: usize,
    ci_detected: bool,
    ci_provider: []const u8,
    shell_name: []const u8,
    audit_sessions_present: bool,
    redteam_fixtures_present: bool,
    daemon_binary_path: ?[]const u8 = null,
    daemon_binary_exists: bool = false,
    daemon_binary_executable: bool = false,
    daemon_binary_untrusted: bool = false,
    daemon_socket_path: ?[]const u8 = null,
    daemon_socket_exists: bool = false,
    daemon_pid_path: ?[]const u8 = null,
    daemon_pid_exists: bool = false,
    /// Canonical daemon health (enum — not stringly typed).
    daemon_health: onboarding.DaemonHealthStatus,
    daemon_detail: []const u8,
    /// Host integration snapshot for the doctor host table (owned slices).
    host_rows: []const HostDoctorRow = &.{},
    hermes_fail_open: bool = true,
    hermes_installed: bool = false,

    fn deinit(self: *IntegrationContext) void {
        self.allocator.free(self.workspace_root);
        if (self.policy_error) |value| self.allocator.free(value);
        if (self.agent_found.len > 0) self.allocator.free(self.agent_found);
        self.allocator.free(self.ci_provider);
        self.allocator.free(self.shell_name);
        if (self.daemon_binary_path) |value| self.allocator.free(value);
        if (self.daemon_socket_path) |value| self.allocator.free(value);
        if (self.daemon_pid_path) |value| self.allocator.free(value);
        self.allocator.free(self.daemon_detail);
        if (self.host_rows.len > 0) {
            for (self.host_rows) |row| {
                self.allocator.free(row.host);
                self.allocator.free(row.wired);
                self.allocator.free(row.shell_gate);
                self.allocator.free(row.fail_stance);
                self.allocator.free(row.smoke_allow);
                self.allocator.free(row.smoke_deny);
                self.allocator.free(row.fix);
            }
            self.allocator.free(self.host_rows);
        }
        self.* = undefined;
    }
};

const HostDoctorRow = struct {
    host: []const u8,
    wired: []const u8,
    shell_gate: []const u8,
    fail_stance: []const u8,
    smoke_allow: []const u8,
    smoke_deny: []const u8,
    fix: []const u8,
};

const DaemonHealth = struct {
    status: onboarding.DaemonHealthStatus,
    detail: []const u8,
};

const DoctorOptions = struct {
    verbose: bool = false,
    check: bool = false,
    json: bool = false,
};

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseDoctorOptions(argv, stderr) catch return exit_codes.usage;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "doctor");
            return exit_codes.success;
        }
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const os = core.platform.detectOs();
    const backend_report = sandbox.backend.detect(os);
    // --check/--json are probe contracts: never spawn/ensure the daemon.
    const ensure_running = !(options.check or options.json);
    var context = collectIntegrationContext(io, allocator, ensure_running) catch |err| {
        try stderr.print("ryk doctor: failed to collect integration context: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer context.deinit();

    const core_ready = readiness.assess(context.daemon_health, context.policy_present, context.policy_valid);
    if (options.json) {
        const policy_path = try std.fs.path.join(allocator, &.{ context.workspace_root, ".orca", "policy.yaml" });
        defer allocator.free(policy_path);
        try readiness.writeJsonEnvelope(stdout, .{
            .assessment = core_ready,
            .check = options.check,
            .daemon_status = readiness.daemonWireLabel(context.daemon_health),
            .daemon_detail = context.daemon_detail,
            .policy_path = policy_path,
            .policy_error = context.policy_error,
            .close_object = true,
        });
    } else {
        try writeReport(io, stdout, os, backend_report, context, options.verbose);
    }
    return core_ready.exitCode(options.check);
}

fn parseDoctorOptions(argv: []const []const u8, stderr: anytype) !DoctorOptions {
    var options: DoctorOptions = .{};
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) continue;
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk doctor", arg, &.{ "--verbose", "-v", "--check", "--json", "--help", "-h" }, "doctor");
        return error.Usage;
    }
    return options;
}

/// Strong sandbox: doctor must never surface probe-only `active`.
/// Live sessions may report active only after apply+attach handshake.
fn doctorDisplayLevel(feature: sandbox.backend.Feature, level: sandbox.backend.Level) sandbox.backend.Level {
    if (feature == .strong_sandbox and level == .active) return .unavailable;
    return level;
}

fn doctorDisplayNote(feature: sandbox.backend.Feature, level: sandbox.backend.Level, note: []const u8) []const u8 {
    if (feature == .strong_sandbox and level == .active) {
        return "capability probe claimed active without attach; reporting unavailable";
    }
    return note;
}

fn countCapabilitySummary(os: core.platform.Os, backend_report: sandbox.backend.ReportSet) struct { active: usize, limited: usize, unavailable: usize } {
    var active_count: usize = 0;
    var limited_count: usize = 0;
    var unavailable_count: usize = 0;

    for (doctor_capabilities) |item| {
        if (item.feature) |feature| {
            switch (doctorDisplayLevel(feature, backend_report.get(feature).level)) {
                .active => active_count += 1,
                .partial, .limited, .observe_only, .wrapper_only => limited_count += 1,
                .unavailable, .unsupported, .failed => unavailable_count += 1,
            }
        } else if (item.capability) |capability| {
            switch (core.platform.reportCapability(os, capability).state) {
                .active => active_count += 1,
                .partial, .limited, .observe => limited_count += 1,
                .unavailable, .unknown => unavailable_count += 1,
            }
        }
    }

    return .{ .active = active_count, .limited = limited_count, .unavailable = unavailable_count };
}

fn daemonStatusSummary(status: onboarding.DaemonHealthStatus) []const u8 {
    return switch (status) {
        .compatible => "daemon compatible",
        .unavailable => "daemon unavailable",
        .incompatible => "daemon incompatible",
        .degraded => "daemon degraded",
    };
}

fn secretBoundaryCapability(backend_report: sandbox.backend.ReportSet) []const u8 {
    const level = doctorDisplayLevel(.strong_sandbox, backend_report.get(.strong_sandbox).level);
    return switch (level) {
        .unavailable, .unsupported, .failed => "unavailable (empty-backpack requires live OS attach)",
        else => "available (live session attestation required; Anthropic/OpenAI gateway compiled)",
    };
}

fn daemonDetailFromError(allocator: std.mem.Allocator, err: anyerror) !DaemonHealth {
    return .{
        .status = cli.daemon.errors.doctorHealthStatus(err),
        .detail = try allocator.dupe(u8, cli.daemon.errors.doctorProbeDetail(err)),
    };
}

fn writeReport(io: std.Io, stdout: anytype, os: core.platform.Os, backend_report: sandbox.backend.ReportSet, context: IntegrationContext, verbose: bool) !void {
    try stdout.writeAll("ryk Doctor\n\n");

    const counts = countCapabilitySummary(os, backend_report);
    const policy_status = if (!context.policy_present)
        "no policy"
    else if (!context.policy_valid)
        "policy invalid"
    else
        "policy valid";

    if (style.useColor(io, stdout)) {
        try stdout.print("Summary: {s} · {s}{d} active{s} · {s}{d} limited{s} · {s}{d} unavailable{s} · {s} · {s}\n\n", .{
            os.toString(),
            style.Style.green,
            counts.active,
            style.Style.reset,
            style.Style.yellow,
            counts.limited,
            style.Style.reset,
            style.Style.red,
            counts.unavailable,
            style.Style.reset,
            policy_status,
            daemonStatusSummary(context.daemon_health),
        });
    } else {
        try stdout.print("Summary: {s} · {d} active · {d} limited · {d} unavailable · {s} · {s}\n\n", .{
            os.toString(),
            counts.active,
            counts.limited,
            counts.unavailable,
            policy_status,
            daemonStatusSummary(context.daemon_health),
        });
    }

    if (!verbose) {
        try writeDefaultPanels(io, stdout, os, backend_report, context, policy_status, counts);
        try writeHostStatusTable(io, stdout, context);
        try writePacksSection(io, stdout, context);
        try writeHermesFailOpenWarning(io, stdout, context);
        try writePiNote(stdout);
        try writeRecommendations(stdout, context);
        return;
    }

    try stdout.print("OS: {s}\n", .{os.toString()});
    try stdout.print("Version: {s}\n\n", .{cli.version});
    try writeIntegrationReport(io, stdout, context);
    try writeHostStatusTable(io, stdout, context);
    try writePacksSection(io, stdout, context);
    try writeHermesFailOpenWarning(io, stdout, context);
    try writePiNote(stdout);
    try stdout.print("Secret boundary: {s}\n\n", .{secretBoundaryCapability(backend_report)});
    try stdout.writeAll("Capabilities:\n");
    for (doctor_capabilities) |item| {
        if (item.feature) |feature| {
            const report = backend_report.get(feature);
            const display_level = doctorDisplayLevel(feature, report.level);
            const display_note = doctorDisplayNote(feature, report.level, report.note);
            const cg = levelColorAndGlyph(display_level);
            if (style.useColor(io, stdout)) {
                try stdout.print("  {s} {s}: {s}{s}{s} ({s})\n", .{ cg.glyph, item.label, cg.color, display_level.toString(), style.Style.reset, display_note });
            } else {
                try stdout.print("  {s} {s}: {s} ({s})\n", .{ cg.glyph, item.label, display_level.toString(), display_note });
            }
        } else if (item.capability) |capability| {
            const report = core.platform.reportCapability(os, capability);
            const cg = stateColorAndGlyph(report.state);
            if (style.useColor(io, stdout)) {
                try stdout.print("  {s} {s}: {s}{s}{s} ({s})\n", .{ cg.glyph, item.label, cg.color, report.state.toString(), style.Style.reset, report.note });
            } else {
                try stdout.print("  {s} {s}: {s} ({s})\n", .{ cg.glyph, item.label, report.state.toString(), report.note });
            }
        }
    }
    try stdout.writeByte('\n');
    if (os == .linux) {
        try stdout.writeAll("Linux backend:\n");
    } else if (os == .macos) {
        try stdout.writeAll("macOS backend:\n");
    } else if (os == .windows) {
        try stdout.writeAll("Windows backend:\n");
    } else {
        try stdout.writeAll("Backend:\n");
    }
    try stdout.print("  selected: {s}\n", .{backend_report.backend_name});
    try stdout.print("  fallback mode: {s} ({s})\n", .{ backend_report.fallback_level.toString(), backend_report.fallback_note });
    if (os == .windows) {
        try writeWindowsBackendReport(io, stdout, backend_report);
    } else {
        try writeBackendLine(io, stdout, backend_report, .policy_engine);
        try writeBackendLine(io, stdout, backend_report, .env_filtering);
        try writeBackendLine(io, stdout, backend_report, .path_staging);
        if (os == .macos) {
            try stdout.writeAll("  transparent file enforcement: limited (no transparent macOS filesystem monitor is installed; ryk-mediated staging and protected path matching are active)\n");
        }
        try writeBackendLine(io, stdout, backend_report, .shell_wrapping);
        try writeBackendLine(io, stdout, backend_report, .path_shims);
        try writeBackendLine(io, stdout, backend_report, .process_supervision);
        if (os == .linux) {
            try writeBackendLine(io, stdout, backend_report, .user_namespaces);
            try writeBackendLine(io, stdout, backend_report, .mount_namespaces);
            try writeBackendLine(io, stdout, backend_report, .seccomp);
            try writeBackendLine(io, stdout, backend_report, .landlock);
            try writeBackendLine(io, stdout, backend_report, .cgroups);
        }
        try writeBackendLine(io, stdout, backend_report, .network_enforce);
        try writeBackendLine(io, stdout, backend_report, .mcp_stdio_proxy);
        try writeBackendLine(io, stdout, backend_report, .strong_sandbox);
        try writeBackendLine(io, stdout, backend_report, .audit);
    }
    try writeRecommendations(stdout, context);
}

fn writeDefaultPanels(
    io: std.Io,
    stdout: anytype,
    os: core.platform.Os,
    backend_report: sandbox.backend.ReportSet,
    context: IntegrationContext,
    policy_status: []const u8,
    counts: anytype,
) !void {
    var health_storage: [6][128]u8 = undefined;
    const health_lines = [_][]const u8{
        try std.fmt.bufPrint(&health_storage[0], "Platform       {s}", .{os.toString()}),
        try std.fmt.bufPrint(&health_storage[1], "Policy         {s}", .{policy_status}),
        try std.fmt.bufPrint(&health_storage[2], "Daemon         {s}", .{daemonStatusSummary(context.daemon_health)}),
        try std.fmt.bufPrint(&health_storage[3], "Capabilities   {d} active · {d} limited", .{ counts.active, counts.limited }),
        try std.fmt.bufPrint(&health_storage[4], "Unavailable    {d}", .{counts.unavailable}),
        try std.fmt.bufPrint(&health_storage[5], "Secret boundary {s}", .{secretBoundaryCapability(backend_report)}),
    };
    try tui.render.panel(io, stdout, "System health", &health_lines);
    try stdout.writeByte('\n');

    var capability_storage: [doctor_capabilities.len][160]u8 = undefined;
    var capability_lines: [doctor_capabilities.len][]const u8 = undefined;
    for (doctor_capabilities, 0..) |item, index| {
        if (item.feature) |feature| {
            const report = backend_report.get(feature);
            const display_level = doctorDisplayLevel(feature, report.level);
            capability_lines[index] = try std.fmt.bufPrint(&capability_storage[index], "{s}  {s}: {s}", .{
                levelColorAndGlyph(display_level).glyph,
                item.label,
                display_level.toString(),
            });
        } else if (item.capability) |capability| {
            const report = core.platform.reportCapability(os, capability);
            capability_lines[index] = try std.fmt.bufPrint(&capability_storage[index], "{s}  {s}: {s}", .{
                stateColorAndGlyph(report.state).glyph,
                item.label,
                report.state.toString(),
            });
        }
    }
    try tui.render.panel(io, stdout, "Capabilities", &capability_lines);
    try stdout.writeAll(
        \\
        \\  Note: Doctor = host capability (probe ≠ live session).
        \\  Session grade = this run's env ORCA_SESSION_SANDBOX_GRADE
        \\  (strong-mediated | fs-attached | wrapper-only | unrestricted-escape).
        \\  Labels: network route-force, ORCA_TOOL_PACK, ORCA_PATH_FILTER, control roots (.orca + .git).
        \\
    );
}

fn writeIntegrationReport(io: std.Io, stdout: anytype, context: IntegrationContext) !void {
    _ = io;
    try stdout.writeAll("Integration checks:\n");
    try writeDynamicLine(stdout, "  workspace root: ", context.workspace_root, "\n");
    try stdout.print("  git repository: {s}\n", .{if (context.git_present) "detected" else "not detected"});
    if (context.policy_present) {
        if (context.policy_valid) {
            try stdout.writeAll("  .orca/policy.yaml: present and valid\n");
        } else {
            try writeDynamicLine(stdout, "  .orca/policy.yaml: invalid (", context.policy_error orelse "validation failed", ")\n");
        }
    } else {
        try stdout.writeAll("  .orca/policy.yaml: missing\n");
    }
    if (context.agent_found.len == 0) {
        try stdout.writeAll("  known agent binaries: none detected in PATH\n");
    } else {
        try stdout.writeAll("  known agent binaries: ");
        for (context.agent_found, 0..) |agent, index| {
            if (index > 0) try stdout.writeAll(", ");
            try tui.terminal_text.write(stdout, agent.command, .single_line);
        }
        try stdout.writeAll(" (presence only; not a security claim)\n");
    }
    if (context.mcp_manifest_count == 0) {
        try stdout.writeAll("  MCP manifests: none detected under .orca/mcp\n");
    } else {
        try stdout.print("  MCP manifests: {d} found, {d} invalid\n", .{ context.mcp_manifest_count, context.mcp_manifest_invalid_count });
    }
    try stdout.print("  CI environment: {s}", .{if (context.ci_detected) "detected" else "not detected"});
    if (context.ci_detected) {
        try stdout.writeAll(" (");
        try tui.terminal_text.write(stdout, context.ci_provider, .single_line);
        try stdout.writeByte(')');
    }
    try stdout.writeByte('\n');
    try writeDynamicLine(stdout, "  shell: ", context.shell_name, "\n");
    try stdout.print("  audit/replay: {s}\n", .{if (context.audit_sessions_present) "session artifacts present; replay available" else "replay available; no local sessions detected"});
    try stdout.print("  red-team fixtures: {s}\n", .{if (context.redteam_fixtures_present) "available" else "not found"});
    if (context.daemon_binary_path) |path| {
        try stdout.writeAll("  daemon binary: ");
        try tui.terminal_text.write(stdout, path, .single_line);
        try stdout.print(" ({s}, {s})\n", .{
            if (context.daemon_binary_exists) "present" else "missing",
            if (context.daemon_binary_executable) "executable" else "not executable",
        });
        if (context.daemon_binary_untrusted) {
            try stdout.writeAll("  daemon binary trust: world-writable ORCA_DAEMON path (refused for shell evaluation)\n");
        }
    } else {
        try stdout.writeAll("  daemon binary: unresolved\n");
    }
    if (context.daemon_socket_path) |path| {
        try stdout.writeAll("  daemon socket: ");
        try tui.terminal_text.write(stdout, path, .single_line);
        try stdout.print(" ({s})\n", .{if (context.daemon_socket_exists) "present" else "missing"});
    }
    if (context.daemon_pid_path) |path| {
        try stdout.writeAll("  daemon pid: ");
        try tui.terminal_text.write(stdout, path, .single_line);
        try stdout.print(" ({s})\n", .{if (context.daemon_pid_exists) "present" else "missing"});
    }
    try stdout.writeAll("  daemon health: ");
    try tui.terminal_text.write(stdout, readiness.daemonWireLabel(context.daemon_health), .single_line);
    try stdout.writeAll(" (");
    try tui.terminal_text.write(stdout, context.daemon_detail, .single_line);
    try stdout.writeAll(")\n\n");
}

fn writeDynamicLine(stdout: anytype, prefix: []const u8, value: []const u8, suffix: []const u8) !void {
    try stdout.writeAll(prefix);
    try tui.terminal_text.write(stdout, value, .single_line);
    try stdout.writeAll(suffix);
}

fn writeWindowsBackendReport(io: std.Io, stdout: anytype, backend_report: sandbox.backend.ReportSet) !void {
    try writeBackendLine(io, stdout, backend_report, .policy_engine);
    try writeBackendLine(io, stdout, backend_report, .env_filtering);
    try writeBackendLine(io, stdout, backend_report, .path_staging);
    try writeBackendLine(io, stdout, backend_report, .path_shims);
    const shell = backend_report.get(.shell_wrapping);
    const shell_cg = levelColorAndGlyph(shell.level);
    if (style.useColor(io, stdout)) {
        try stdout.print("  {s} cmd wrapper: {s}partial{s} ({s})\n", .{ shell_cg.glyph, style.Style.yellow, style.Style.reset, shell.note });
        try stdout.print("  {s} PowerShell wrapper: {s}partial{s} ({s})\n", .{ shell_cg.glyph, style.Style.yellow, style.Style.reset, shell.note });
    } else {
        try stdout.print("  cmd wrapper: partial ({s})\n", .{shell.note});
        try stdout.print("  PowerShell wrapper: partial ({s})\n", .{shell.note});
    }
    const cleanup = backend_report.get(.process_supervision);
    const cleanup_cg = levelColorAndGlyph(cleanup.level);
    if (style.useColor(io, stdout)) {
        try stdout.print("  {s} process cleanup: {s}{s}{s} ({s})\n", .{ cleanup_cg.glyph, cleanup_cg.color, cleanup.level.toString(), style.Style.reset, cleanup.note });
    } else {
        try stdout.print("  process cleanup: {s} ({s})\n", .{ cleanup.level.toString(), cleanup.note });
    }
    try stdout.writeAll("  transparent file enforcement: limited (no transparent Windows filesystem enforcement is installed; ryk-mediated staging and protected path matching are active)\n");
    try writeBackendLine(io, stdout, backend_report, .network_enforce);
    try writeBackendLine(io, stdout, backend_report, .strong_sandbox);
    try writeBackendLine(io, stdout, backend_report, .mcp_stdio_proxy);
    try writeBackendLine(io, stdout, backend_report, .audit);
    try stdout.writeByte('\n');
}

fn levelColorAndGlyph(level: sandbox.backend.Level) struct { color: []const u8, glyph: []const u8 } {
    return switch (level) {
        .active => .{ .color = style.Style.green, .glyph = "✓" },
        .partial, .limited, .observe_only, .wrapper_only => .{ .color = style.Style.yellow, .glyph = "◌" },
        .unavailable, .unsupported, .failed => .{ .color = style.Style.red, .glyph = "✗" },
    };
}

fn stateColorAndGlyph(state: core.platform.CapabilityState) struct { color: []const u8, glyph: []const u8 } {
    return switch (state) {
        .active => .{ .color = style.Style.green, .glyph = "✓" },
        .partial, .limited, .observe => .{ .color = style.Style.yellow, .glyph = "◌" },
        .unavailable, .unknown => .{ .color = style.Style.red, .glyph = "✗" },
    };
}

fn writeBackendLine(io: std.Io, stdout: anytype, backend_report: sandbox.backend.ReportSet, feature: sandbox.backend.Feature) !void {
    const report = backend_report.get(feature);
    // Strong sandbox: doctor reports capability level only. Live sessions may report
    // active only after apply+attach. Never imply OS-enforced from a probe.
    const display_level = doctorDisplayLevel(feature, report.level);
    const display_note = doctorDisplayNote(feature, report.level, report.note);
    const display_cg = levelColorAndGlyph(display_level);
    if (style.useColor(io, stdout)) {
        try stdout.print("  {s} {s}: {s}{s}{s} ({s})\n", .{ display_cg.glyph, report.feature.label(), display_cg.color, display_level.toString(), style.Style.reset, display_note });
    } else {
        try stdout.print("  {s} {s}: {s} ({s})\n", .{ display_cg.glyph, report.feature.label(), display_level.toString(), display_note });
    }
}

fn writeHostStatusTable(io: std.Io, stdout: anytype, context: IntegrationContext) !void {
    if (context.host_rows.len == 0) return;
    try stdout.writeAll("\n");
    try tui.theme.paintBold(io, stdout, .brand, "Host integrations");
    try stdout.writeAll("\n");
    var rows = try context.allocator.alloc([]const []const u8, context.host_rows.len);
    defer context.allocator.free(rows);
    for (context.host_rows, 0..) |row, i| {
        const cells = try context.allocator.alloc([]const u8, 6);
        cells[0] = row.host;
        cells[1] = row.wired;
        cells[2] = row.shell_gate;
        cells[3] = row.fail_stance;
        cells[4] = row.smoke_allow;
        cells[5] = row.smoke_deny;
        rows[i] = cells;
    }
    defer for (rows) |row| context.allocator.free(row);
    try tui.render.table(io, stdout, &.{
        .{ .name = "HOST" },
        .{ .name = "WIRED" },
        .{ .name = "SHELL GATE" },
        .{ .name = "FAIL STANCE" },
        .{ .name = "SMOKE ALLOW" },
        .{ .name = "SMOKE DENY" },
    }, rows);
    // Fix lines for every non-green row (wired != yes, smoke fail, or hermes fail-open).
    for (context.host_rows) |row| {
        const needs_fix = !std.mem.eql(u8, row.fix, "—") and row.fix.len > 0;
        if (!needs_fix) continue;
        try stdout.print("  fix {s}: {s}\n", .{ row.host, row.fix });
    }
}

fn writeHermesFailOpenWarning(io: std.Io, stdout: anytype, context: IntegrationContext) !void {
    if (!context.hermes_installed or !context.hermes_fail_open) return;
    try stdout.writeAll("\n");
    try tui.render.callout(
        io,
        stdout,
        .warn,
        "Hermes effective fail-open",
        "Hermes allows tools when ryk is missing/old. Not silent (warning each degraded allow). New installs write fail-closed stance; existing stay open until you set ORCA_HERMES_FAIL_OPEN=0 or use `ryk run -- hermes`. Gateway chats may omit the block reason — check agent tool errors.",
    );
}

fn writePiNote(stdout: anytype) !void {
    try stdout.writeAll("\nPi: bundled extension setup is managed by `ryk start` (no npm step).\n");
    try stdout.writeAll("  Process env/network isolation: ryk run -- pi · verify: ryk doctor\n");
}

fn writePacksSection(io: std.Io, stdout: anytype, context: IntegrationContext) !void {
    // Avoid spawning the daemon when health probe already failed (doctor stays fast).
    const config_path: ?[]const u8 = blk: {
        const root = onboarding.resolveWorkspaceRoot(io, context.allocator) catch break :blk null;
        defer context.allocator.free(root);
        const resolved = pack_state.resolvePackConfigPath(io, context.allocator, root) catch break :blk null;
        break :blk resolved.path;
    };
    defer if (config_path) |p| context.allocator.free(p);

    if (context.daemon_health != .compatible) {
        try pack_state.writeDoctorPacksSectionWithConfig(stdout, pack_state.unknownPacksSummary(), config_path, null);
        return;
    }
    var summary = pack_state.queryPacksSummaryDefault(io, context.allocator) catch pack_state.unknownPacksSummary();
    defer summary.deinit(context.allocator);
    try pack_state.writeDoctorPacksSectionWithConfig(stdout, summary, config_path, null);
}

/// Effective Hermes fail-open default matches integrations/hermes-plugin (default allow when degraded).
pub fn hermesFailOpenFromEnvValue(value: ?[]const u8) bool {
    return host_status.hermesFailOpenFromEnvValue(value);
}

fn hermesFailOpenFromEnv() bool {
    return host_status.hermesFailOpenFromEnv();
}

fn writeRecommendations(stdout: anytype, context: IntegrationContext) !void {
    try stdout.writeAll("\nRecommended next step:\n");
    if (context.daemon_health != .compatible) {
        try writeDynamicLine(stdout, "  Daemon health issue: ", context.daemon_detail, "\n");
        if (context.daemon_binary_untrusted) {
            try stdout.writeAll("  Remove the untrusted legacy companion override, then re-run `ryk doctor`.\n");
        } else if (context.daemon_binary_exists and !context.daemon_binary_executable) {
            try stdout.writeAll("  Restore companion-service execute permission or reinstall ryk, then re-run `ryk doctor`.\n");
        } else if (!context.daemon_binary_exists) {
            try stdout.writeAll("  Reinstall the complete ryk release, then re-run `ryk doctor`.\n");
            try stdout.writeAll("  For source builds, rebuild with `./scripts/build-all.sh`.\n");
        } else {
            try stdout.writeAll("  Reinstall ryk or rebuild with `./scripts/build-all.sh`, then re-run `ryk doctor`.\n");
        }
        if (!context.policy_present) {
            try stdout.writeAll("  Then run `ryk init --preset generic-agent` and review .orca/policy.yaml.\n");
        } else if (!context.policy_valid) {
            try stdout.writeAll("  After the daemon is healthy, fix `.orca/policy.yaml`, then run `ryk policy check .orca/policy.yaml`.\n");
        }
    } else if (!context.policy_present) {
        try stdout.writeAll("  Run `ryk init --preset generic-agent` and review .orca/policy.yaml.\n");
    } else if (!context.policy_valid) {
        try stdout.writeAll("  Fix `.orca/policy.yaml`, then run `ryk policy check .orca/policy.yaml`.\n");
    } else if (context.mcp_manifest_invalid_count > 0) {
        try stdout.writeAll("  Fix invalid MCP manifests with `ryk mcp manifest check <path>`.\n");
    } else if (!context.redteam_fixtures_present) {
        try stdout.writeAll("  Runtime assets (fixtures, integrations) not found.\n");
        try stdout.writeAll("  This is common after a fresh packaged install (curl|sh, Homebrew, npm).\n\n");
        try stdout.writeAll("  Paste these two lines in your current terminal (then re-run `ryk doctor`):\n\n");
        try stdout.writeAll("      export PATH=\"$HOME/.local/bin:$PATH\"\n");
        try stdout.writeAll("      export RYK_RESOURCE_ROOT=\"$HOME/.local/share/orca/current\"\n\n");
        try stdout.writeAll("  (Use the exact paths printed by your installer if they differ.)\n");
    } else {
        try stdout.writeAll("  Run `ryk run -- <command>` or `ryk redteam --ci` for a local smoke test.\n");
    }
}

fn collectIntegrationContext(io: std.Io, allocator: std.mem.Allocator, ensure_running: bool) !IntegrationContext {
    const workspace_root = supervisor.resolveWorkspaceRoot(io, allocator, null, ".") catch try allocator.dupe(u8, ".");
    errdefer allocator.free(workspace_root);
    return try collectIntegrationContextAt(io, allocator, workspace_root, ensure_running);
}

fn collectIntegrationContextAt(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, ensure_running: bool) !IntegrationContext {
    const git_present = hasPath(io, workspace_root, ".git");

    const policy_path = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "policy.yaml" });
    defer allocator.free(policy_path);
    var policy_assessment = try readiness.assessPolicyFile(io, allocator, policy_path);
    const policy_present = policy_assessment.present;
    const policy_valid = policy_assessment.valid;
    // Transfer ownership of error_name into IntegrationContext.policy_error.
    const policy_error = policy_assessment.error_name;
    policy_assessment.error_name = null;
    errdefer if (policy_error) |value| allocator.free(value);
    const manifests = countMcpManifests(io, allocator, workspace_root);
    const agents = try detectAgents(io, allocator);
    errdefer if (agents.len > 0) allocator.free(agents);
    const ci_status = try detectCi(allocator);
    errdefer allocator.free(ci_status.provider);
    const shell_name = try detectShell(allocator);
    errdefer allocator.free(shell_name);
    const daemon_inspection = cli.daemon.inspectDaemonBinary(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    defer if (daemon_inspection) |value| value.deinit(allocator);
    const daemon_paths = cli.daemon.runtimePaths(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    defer if (daemon_paths) |value| cli.daemon.freeRuntimePaths(allocator, value);
    // Shared onboarding health path (same as status/quickstart). Probe paths pass
    // ensure_running=false so --check never mutates daemon runtime.
    const daemon_health: DaemonHealth = blk: {
        const check = onboarding.checkDaemonHealth(allocator, ensure_running, null) catch |err| {
            break :blk try daemonDetailFromError(allocator, err);
        };
        break :blk .{
            .status = check.status,
            .detail = try allocator.dupe(u8, check.detail),
        };
    };
    errdefer allocator.free(daemon_health.detail);

    const host_snapshot = try collectHostDoctorRows(io, allocator);
    errdefer {
        for (host_snapshot.rows) |row| {
            allocator.free(row.host);
            allocator.free(row.wired);
            allocator.free(row.shell_gate);
            allocator.free(row.fail_stance);
            allocator.free(row.smoke_allow);
            allocator.free(row.smoke_deny);
            allocator.free(row.fix);
        }
        allocator.free(host_snapshot.rows);
    }

    return .{
        .allocator = allocator,
        .workspace_root = workspace_root,
        .git_present = git_present,
        .policy_present = policy_present,
        .policy_valid = policy_valid,
        .policy_error = policy_error,
        .agent_found = agents,
        .mcp_manifest_count = manifests.total,
        .mcp_manifest_invalid_count = manifests.invalid,
        .ci_detected = ci_status.detected,
        .ci_provider = ci_status.provider,
        .shell_name = shell_name,
        .audit_sessions_present = hasPath(io, workspace_root, ".orca/sessions"),
        .redteam_fixtures_present = resource_root.resourcePathExists(io, allocator, .{ .workspace_root = workspace_root }, "fixtures"),
        .daemon_binary_path = if (daemon_inspection) |value| try allocator.dupe(u8, value.path) else null,
        .daemon_binary_exists = if (daemon_inspection) |value| value.exists else false,
        .daemon_binary_executable = if (daemon_inspection) |value| value.executable else false,
        .daemon_binary_untrusted = if (daemon_inspection) |value|
            value.source == .env_override and value.untrusted
        else
            false,
        .daemon_socket_path = if (daemon_paths) |value| try allocator.dupe(u8, value.socket) else null,
        .daemon_socket_exists = if (daemon_paths) |value| fileExistsAbsolute(io, value.socket) else false,
        .daemon_pid_path = if (daemon_paths) |value| try allocator.dupe(u8, value.pid) else null,
        .daemon_pid_exists = if (daemon_paths) |value| fileExistsAbsolute(io, value.pid) else false,
        .daemon_health = daemon_health.status,
        .daemon_detail = daemon_health.detail,
        .host_rows = host_snapshot.rows,
        .hermes_fail_open = host_snapshot.hermes_fail_open,
        .hermes_installed = host_snapshot.hermes_installed,
    };
}

const HostDoctorSnapshot = struct {
    rows: []HostDoctorRow,
    hermes_fail_open: bool,
    hermes_installed: bool,
};

fn collectHostDoctorRows(io: std.Io, allocator: std.mem.Allocator) !HostDoctorSnapshot {
    // Skip live hook smoke here — plugin install / `ryk plugin doctor <host>` own latency.
    var doctor_report = try plugin.collectPluginDoctorReportWithHermesSmoke(io, allocator, true);
    defer plugin.deinitPluginDoctorReport(&doctor_report, allocator);

    const hermes_fail_open = hermesFailOpenFromEnv();
    var hermes_installed = false;

    var list: std.ArrayList(HostDoctorRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.host);
            allocator.free(row.wired);
            allocator.free(row.shell_gate);
            allocator.free(row.fail_stance);
            allocator.free(row.smoke_allow);
            allocator.free(row.smoke_deny);
            allocator.free(row.fix);
        }
        list.deinit(allocator);
    }

    for (host_status.managed_hosts) |host_name| {
        const installed = plugin.hostPluginInstalledFromReport(host_name, doctor_report);
        const detected = plugin.binaryInPath(io, allocator, host_name);
        if (std.mem.eql(u8, host_name, "hermes") and installed) hermes_installed = true;

        const wired: []const u8 = if (installed) "yes" else if (detected) "no" else "—";
        const shell_gate = host_status.shellGate(host_name);
        const fail_stance = host_status.failStance(host_name, hermes_fail_open);
        const smoke = host_status.HostSmokePair{};
        const fix = try host_status.formatFix(allocator, host_name, wired, smoke, hermes_fail_open);

        try list.append(allocator, .{
            .host = try allocator.dupe(u8, host_name),
            .wired = try allocator.dupe(u8, wired),
            .shell_gate = try allocator.dupe(u8, shell_gate),
            .fail_stance = try allocator.dupe(u8, fail_stance),
            .smoke_allow = try allocator.dupe(u8, smoke.allow.toString()),
            .smoke_deny = try allocator.dupe(u8, smoke.deny.toString()),
            .fix = fix,
        });
    }

    // Pi: first-class status line (honest coverage / install path; not plugin-managed).
    {
        const pi_status = host_status.inspectPi(io, allocator);
        const wired = pi_status.wiredLabel();
        const smoke = host_status.HostSmokePair{};
        const fix = try host_status.formatFix(allocator, "pi", wired, smoke, hermes_fail_open);
        try list.append(allocator, .{
            .host = try allocator.dupe(u8, "pi"),
            .wired = try allocator.dupe(u8, wired),
            .shell_gate = try allocator.dupe(u8, host_status.shellGate("pi")),
            .fail_stance = try allocator.dupe(u8, host_status.failStance("pi", hermes_fail_open)),
            .smoke_allow = try allocator.dupe(u8, smoke.allow.toString()),
            .smoke_deny = try allocator.dupe(u8, smoke.deny.toString()),
            .fix = fix,
        });
    }

    return .{
        .rows = try list.toOwnedSlice(allocator),
        .hermes_fail_open = hermes_fail_open,
        .hermes_installed = hermes_installed,
    };
}

fn hasPath(io: std.Io, root: []const u8, relative: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const path = std.fs.path.join(allocator, &.{ root, relative }) catch return false;
    defer allocator.free(path);
    return fileExistsAbsolute(io, path);
}

fn fileExistsAbsolute(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

const ManifestCounts = struct { total: usize = 0, invalid: usize = 0 };

fn countMcpManifests(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ManifestCounts {
    const mcp_dir_path = std.fs.path.join(allocator, &.{ workspace_root, ".orca", "mcp" }) catch return .{};
    defer allocator.free(mcp_dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, mcp_dir_path, .{ .iterate = true }) catch return .{};
    defer dir.close(io);

    var counts: ManifestCounts = .{};
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        counts.total += 1;
        const manifest_path = std.fs.path.join(allocator, &.{ mcp_dir_path, entry.name }) catch {
            counts.invalid += 1;
            continue;
        };
        defer allocator.free(manifest_path);
        var manifest = orca_mcp.manifests.loadFile(io, allocator, manifest_path) catch {
            counts.invalid += 1;
            continue;
        };
        manifest.deinit(allocator);
    }
    return counts;
}

fn detectAgents(io: std.Io, allocator: std.mem.Allocator) ![]const AgentBinary {
    var found: std.ArrayList(AgentBinary) = .empty;
    errdefer found.deinit(allocator);
    for (known_agent_binaries) |agent| {
        if (binaryInPath(io, allocator, agent.command)) try found.append(allocator, agent);
    }
    return try found.toOwnedSlice(allocator);
}

fn binaryInPath(io: std.Io, allocator: std.mem.Allocator, binary_name: []const u8) bool {
    var env_map = env_util.createProcessMap(allocator) catch return false;
    defer env_map.deinit();
    const path_owned = env_util.getOwned(&env_map, allocator, "PATH") catch return false;
    const path_value = path_owned orelse return false;
    defer allocator.free(path_value);
    var parts = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (parts.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ dir, binary_name }) catch continue;
        defer allocator.free(candidate);
        if (fileExistsAbsolute(io, candidate)) return true;
        if (builtin.os.tag == .windows) {
            const exe_candidate = std.fmt.allocPrint(allocator, "{s}.exe", .{candidate}) catch continue;
            defer allocator.free(exe_candidate);
            if (fileExistsAbsolute(io, exe_candidate)) return true;
        }
    }
    return false;
}

const CiStatus = struct {
    detected: bool,
    provider: []const u8,
};

fn detectCi(allocator: std.mem.Allocator) !CiStatus {
    var env_map = try env_util.createProcessMap(allocator);
    defer env_map.deinit();
    if (envPresent(&env_map, "GITHUB_ACTIONS")) return .{ .detected = true, .provider = try allocator.dupe(u8, "GitHub Actions") };
    if (envPresent(&env_map, "CI")) return .{ .detected = true, .provider = try allocator.dupe(u8, "generic CI") };
    return .{ .detected = false, .provider = try allocator.dupe(u8, "none") };
}

fn envPresent(env_map: *const std.process.Environ.Map, name: []const u8) bool {
    const value = env_map.get(name) orelse return false;
    return value.len > 0;
}

fn detectShell(allocator: std.mem.Allocator) ![]const u8 {
    var env_map = try env_util.createProcessMap(allocator);
    defer env_map.deinit();
    if (try env_util.getOwned(&env_map, allocator, "SHELL")) |value| {
        defer allocator.free(value);
        return try allocator.dupe(u8, std.fs.path.basename(value));
    }
    if (env_util.getOwned(&env_map, allocator, "COMSPEC") catch null) |value| {
        defer allocator.free(value);
        return try allocator.dupe(u8, std.fs.path.basename(value));
    }
    if (envPresent(&env_map, "PSModulePath")) return try allocator.dupe(u8, "powershell");
    return try allocator.dupe(u8, "unknown");
}

test "doctor renders verbose OS and planned capabilities from an injected context" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const os = core.platform.detectOs();
    const report = sandbox.backend.detect(os);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, os, report, context, true);

    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "ryk Doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Integration checks:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "OS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "process supervision:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "network policy engine: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "transparent network enforcement: unavailable") != null or std.mem.indexOf(u8, stdout_writer.buffered(), "transparent network enforcement: limited") != null or std.mem.indexOf(u8, stdout_writer.buffered(), "transparent network enforcement: observe-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "proxy-mediated enforcement: limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Backend:") != null or std.mem.indexOf(u8, stdout_writer.buffered(), "Linux backend:") != null or std.mem.indexOf(u8, stdout_writer.buffered(), "macOS backend:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "env filtering: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "strong sandbox:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Secret boundary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Secret boundary: active") == null);
}

test "doctor can render Linux backend details from an injected report" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);

    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Linux backend:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "user namespace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "mount namespace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "seccomp:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "landlock:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "transparent network enforcement: observe-only") != null);
}

test "doctor can render macOS backend details from an injected report" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.macos);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .macos, report, context, true);

    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "macOS backend:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "selected: macos") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "env filtering: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "path staging: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "transparent file enforcement: limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "shell shims: wrapper-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "process supervision: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "transparent network enforcement: unavailable") != null);
    // partial on matrix macOS with sandbox_init; unavailable outside matrix — never active from probe.
    const strong_unavail = std.mem.indexOf(u8, written, "strong sandbox: unavailable") != null;
    const strong_partial = std.mem.indexOf(u8, written, "strong sandbox: partial") != null;
    try std.testing.expect(strong_unavail or strong_partial);
    try std.testing.expect(std.mem.indexOf(u8, written, "strong sandbox: active") == null);
    // When attach is possible, doctor surfaces default residual grade (capability, not live).
    if (strong_partial) {
        try std.testing.expect(std.mem.indexOf(u8, written, "seatbelt_profile=hardened") != null);
        try std.testing.expect(std.mem.indexOf(u8, written, "default residual grade hardened") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, written, "mcp stdio proxy: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "audit/replay: active") != null);
}

// Internal id S-GLO-01: probe-only active must never reach operator-facing doctor output.
test "doctor never prints strong sandbox active from capability probe alone" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);

    // Forge a dishonest report that claims strong_sandbox active without attach.
    var reports = sandbox.backend.baseReports(.macos);
    sandbox.backend.setReport(&reports, .strong_sandbox, .active, "forged probe-only active");
    const forged: sandbox.backend.ReportSet = .{
        .os = .macos,
        .backend_name = "macos",
        .fallback_level = .partial,
        .fallback_note = "test",
        .reports = reports,
    };
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .macos, forged, context, true);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "strong sandbox: active") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "strong sandbox: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "without attach") != null);
    // Ticket IDs must not appear in operator-facing doctor text.
    try std.testing.expect(std.mem.indexOf(u8, written, "S-GLO-01") == null);
    // Forged probe note must not leak through after demotion.
    try std.testing.expect(std.mem.indexOf(u8, written, "forged probe-only active") == null);
    // Default doctor copy stays mechanism-neutral (verbose may name Landlock/Seatbelt later).
    try std.testing.expect(std.mem.indexOf(u8, written, "Seatbelt") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Landlock") == null);
}

test "doctor can render Windows backend details from an injected report" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.windows);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .windows, report, context, true);

    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Windows backend:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "selected: windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "env filtering: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "path staging: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PATH shims: wrapper-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "cmd wrapper: partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PowerShell wrapper: partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "process cleanup: partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "transparent file enforcement: limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "transparent network enforcement: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "strong sandbox: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "mcp stdio proxy: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "audit/replay: active") != null);
}

test "doctor detects valid policy in current workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path_z = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path_z);
    const tmp_path = try std.testing.allocator.dupe(u8, tmp_path_z);

    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, orca_policy.presets.agentPresetText(.generic_agent));
    }

    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    var context = try collectIntegrationContextAt(std.testing.io, std.testing.allocator, tmp_path, true);
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, core.platform.detectOs(), sandbox.backend.detect(core.platform.detectOs()), context, true);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), ".orca/policy.yaml: present and valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "git repository: detected") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "doctor reports invalid policy clearly without printing synthetic secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path_z = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path_z);
    const tmp_path = try std.testing.allocator.dupe(u8, tmp_path_z);

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io,
            \\version: 1
            \\mode: loose
            \\# synthetic secret should not appear in doctor output: ghp_fakeSecretShouldNotPrint
        );
    }

    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    var context = try collectIntegrationContextAt(std.testing.io, std.testing.allocator, tmp_path, true);
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, core.platform.detectOs(), sandbox.backend.detect(core.platform.detectOs()), context, true);
    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ".orca/policy.yaml: invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UnsupportedPolicyMode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ghp_fakeSecretShouldNotPrint") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "doctor renders a compact summary from an injected context" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const os = core.platform.detectOs();
    const report = sandbox.backend.detect(os);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, os, report, context, false);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "active") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Recommended next step:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Capabilities:") == null);
}

test "doctor renders a full report from an injected context" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const os = core.platform.detectOs();
    const report = sandbox.backend.detect(os);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, os, report, context, true);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Capabilities:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Integration checks:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "workspace root:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "daemon health:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fallback mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Recommended next step:") != null);
}

test "doctor integration collection returns allocator failures instead of panicking" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, collectIntegrationContextAt(std.testing.io, failing_allocator.allocator(), ".", true));
}

test "doctor output contains status glyphs in plain text mode" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);
    const written = stdout_writer.buffered();
    const has_check = std.mem.indexOf(u8, written, "✓") != null;
    const has_diamond = std.mem.indexOf(u8, written, "◌") != null;
    const has_cross = std.mem.indexOf(u8, written, "✗") != null;
    try std.testing.expect(has_check or has_diamond or has_cross);
}

test "doctor output has no ANSI codes in non-TTY mode" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[") == null);
}

test "doctor default renders compact health and capability panels" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);

    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "System health") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "process supervision") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "fallback mode:") == null);
}

test "doctor sanitizes hostile dynamic diagnostic text" {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();
    context.allocator.free(context.workspace_root);
    context.workspace_root = try context.allocator.dupe(u8, "repo\x1b[2J\rspoof");
    context.allocator.free(context.daemon_detail);
    context.daemon_detail = try context.allocator.dupe(u8, "offline\x1b]0;pwn\x07\nforged");

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);

    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOfScalar(u8, written, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pwn") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\nforged") == null);
}

test "doctor summary includes daemon availability" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .daemon_health = .unavailable,
        .daemon_detail = "no running daemon answered on the expected socket.",
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "daemon unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no running daemon answered on the expected socket") != null);
}

test "doctor integration report includes daemon health details" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .daemon_health = .incompatible,
        .daemon_detail = "daemon protocol version or capability set does not match this ryk CLI.",
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "daemon health: incompatible") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "does not match this ryk CLI") != null);
}

test "doctor integration report warns on world-writable ORCA_DAEMON path" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .daemon_health = .unavailable,
        .daemon_detail = "ORCA_DAEMON points at a world-writable path.",
        .daemon_binary_untrusted = true,
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, true);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "daemon binary trust: world-writable ORCA_DAEMON path") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ORCA_DAEMON points at a world-writable path.") != null);
}

test "doctor recommendations prioritize daemon remediation over missing policy" {
    var stdout_buf: [32768]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .policy_present = false,
        .daemon_health = .unavailable,
        .daemon_detail = "no running daemon answered on the expected socket.",
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Daemon health issue: no running daemon answered on the expected socket.") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "./scripts/build-all.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ryk init --preset generic-agent") != null);
}

test "doctor packs section is unknown when daemon is unavailable" {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .daemon_health = .unavailable,
        .daemon_detail = "no running daemon answered on the expected socket.",
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\nPacks\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "unknown (daemon unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "fails closed") != null);
}

test "doctor host table lists managed hosts and shell gates" {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{});
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Host integrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "opencode") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "openclaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hermes") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pre_tool_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "extension-managed (smoke not run)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "SMOKE ALLOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "SMOKE DENY") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Pi: bundled extension setup is managed by `ryk start`") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ryk run -- pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pi …") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "fix pi:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "run ryk start to install the bundled extension") != null);
}

test "doctor warns when Hermes is installed with fail-open default" {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const report = sandbox.backend.detect(.linux);
    var context = try testContext(std.testing.allocator, .{
        .hermes_installed = true,
        .hermes_fail_open = true,
    });
    defer context.deinit();

    try writeReport(std.testing.io, &stdout_writer, .linux, report, context, false);
    const written = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Hermes effective fail-open") != null or std.mem.indexOf(u8, written, "fail-open") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ORCA_HERMES_FAIL_OPEN=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ryk run -- hermes") != null);
}

test "hermesFailOpenFromEnvValue defaults to fail-open" {
    try std.testing.expect(hermesFailOpenFromEnvValue(null));
    try std.testing.expect(hermesFailOpenFromEnvValue("1"));
    try std.testing.expect(hermesFailOpenFromEnvValue("true"));
    try std.testing.expect(!hermesFailOpenFromEnvValue("0"));
    try std.testing.expect(!hermesFailOpenFromEnvValue("false"));
    try std.testing.expect(!hermesFailOpenFromEnvValue("off"));
}

test "doctor rejects unknown option" {
    var stdout_buf: [64]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try command(std.testing.io, &.{"--nope"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
}

test "doctor --json readiness includes ready and policy.valid" {
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // Without --check: always exit 0 for report render even if not ready.
    const code = try command(std.testing.io, &.{"--json"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"check\": false") != null);
}

test "doctor parseDoctorOptions accepts --check and --json" {
    var stderr_buf: [64]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const opts = try parseDoctorOptions(&.{ "--check", "--json", "--verbose" }, &stderr_writer);
    try std.testing.expect(opts.check);
    try std.testing.expect(opts.json);
    try std.testing.expect(opts.verbose);
}

const TestContextOptions = struct {
    policy_present: bool = true,
    policy_valid: bool = true,
    daemon_binary_exists: bool = true,
    daemon_binary_executable: bool = true,
    daemon_binary_untrusted: bool = false,
    daemon_health: onboarding.DaemonHealthStatus = .compatible,
    daemon_detail: []const u8 = "running daemon answered with a compatible handshake.",
    hermes_fail_open: bool = true,
    hermes_installed: bool = false,
};

fn testContext(allocator: std.mem.Allocator, options: TestContextOptions) !IntegrationContext {
    const host_rows = try testHostRows(allocator);
    return .{
        .allocator = allocator,
        .workspace_root = try allocator.dupe(u8, "."),
        .git_present = true,
        .policy_present = options.policy_present,
        .policy_valid = options.policy_valid,
        .policy_error = null,
        .agent_found = &.{},
        .mcp_manifest_count = 0,
        .mcp_manifest_invalid_count = 0,
        .ci_detected = false,
        .ci_provider = try allocator.dupe(u8, "none"),
        .shell_name = try allocator.dupe(u8, "zsh"),
        .audit_sessions_present = false,
        .redteam_fixtures_present = true,
        .daemon_binary_path = try allocator.dupe(u8, "/tmp/orca-daemon"),
        .daemon_binary_exists = options.daemon_binary_exists,
        .daemon_binary_executable = options.daemon_binary_executable,
        .daemon_binary_untrusted = options.daemon_binary_untrusted,
        .daemon_socket_path = try allocator.dupe(u8, "/tmp/daemon.sock"),
        .daemon_socket_exists = false,
        .daemon_pid_path = try allocator.dupe(u8, "/tmp/daemon.pid"),
        .daemon_pid_exists = false,
        .daemon_health = options.daemon_health,
        .daemon_detail = try allocator.dupe(u8, options.daemon_detail),
        .host_rows = host_rows,
        .hermes_fail_open = options.hermes_fail_open,
        .hermes_installed = options.hermes_installed,
    };
}

fn testHostRows(allocator: std.mem.Allocator) ![]HostDoctorRow {
    const hosts = [_]struct { name: []const u8, gate: []const u8, stance: []const u8 }{
        .{ .name = "codex", .gate = "PreToolUse", .stance = "fail-closed shell" },
        .{ .name = "claude", .gate = "PreToolUse", .stance = "fail-closed shell" },
        .{ .name = "opencode", .gate = "tool.execute.before", .stance = "fail-closed shell" },
        .{ .name = "openclaw", .gate = "tool.before", .stance = "fail-closed shell" },
        .{ .name = "hermes", .gate = "pre_tool_call", .stance = "fail-open (default)" },
        .{ .name = "pi", .gate = "extension-managed (smoke not run)", .stance = "mode-dependent" },
    };
    var list: std.ArrayList(HostDoctorRow) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.host);
            allocator.free(row.wired);
            allocator.free(row.shell_gate);
            allocator.free(row.fail_stance);
            allocator.free(row.smoke_allow);
            allocator.free(row.smoke_deny);
            allocator.free(row.fix);
        }
        list.deinit(allocator);
    }
    for (hosts) |h| {
        const fix = if (std.mem.eql(u8, h.name, "hermes"))
            try allocator.dupe(u8, "export ORCA_HERMES_FAIL_OPEN=0  # or: ryk run -- hermes")
        else if (std.mem.eql(u8, h.name, "pi"))
            try allocator.dupe(u8, "run ryk start to install the bundled extension")
        else
            try allocator.dupe(u8, "—");
        try list.append(allocator, .{
            .host = try allocator.dupe(u8, h.name),
            .wired = try allocator.dupe(u8, "—"),
            .shell_gate = try allocator.dupe(u8, h.gate),
            .fail_stance = try allocator.dupe(u8, h.stance),
            .smoke_allow = try allocator.dupe(u8, "not-run"),
            .smoke_deny = try allocator.dupe(u8, "not-run"),
            .fix = fix,
        });
    }
    return try list.toOwnedSlice(allocator);
}
