const std = @import("std");
const builtin = @import("builtin");
const core = @import("orca_core").core;
const supervisor = core.supervisor;
const core_api = @import("orca_core").api;
const sandbox = @import("orca").sandbox;

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const cli = @import("mod.zig");
const plugin_install = @import("plugin_install.zig");
const child_process = @import("child_process.zig");
const resource_root = @import("orca").resource_root;
const env_util = @import("orca").env_util;
const tui = @import("orca").tui;
const suggestions = @import("suggestions.zig");
const host_status = @import("host_status.zig");
const openclaw_status = @import("openclaw_status.zig");
const interactive = @import("interactive.zig");

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len > 0 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
        _ = try help.writeCommand(io, stdout, "plugin");
        return exit_codes.success;
    }
    if (argv.len == 0) {
        _ = try help.writeCommand(io, stderr, "plugin");
        return exit_codes.usage;
    }

    if (std.mem.eql(u8, argv[0], "doctor")) return doctorCommand(io, argv[1..], stdout, stderr);
    if (std.mem.eql(u8, argv[0], "list")) return listCommand(io, argv[1..], stdout, stderr);
    if (std.mem.eql(u8, argv[0], "manifest")) return manifestCommand(io, argv[1..], stdout, stderr);
    if (std.mem.eql(u8, argv[0], "install")) return installCommand(io, argv[1..], stdout, stderr);
    if (std.mem.eql(u8, argv[0], "mcp-server")) return mcpServerCommand(io, argv[1..], stdout, stderr);
    inline for (.{ "codex", "claude", "opencode", "openclaw", "hermes" }) |host| {
        if (std.mem.eql(u8, argv[0], host)) return installAliasCommand(io, host, argv[1..], stdout, stderr);
    }

    try suggestions.writeUnknownSubcommand(stderr, "ryk plugin", argv[0], &.{ "doctor", "list", "manifest", "install", "mcp-server", "codex", "claude", "opencode", "openclaw", "hermes" }, "plugin");
    return exit_codes.usage;
}

fn installAliasCommand(io: std.Io, host: []const u8, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const install_argv = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(install_argv);
    install_argv[0] = host;
    @memcpy(install_argv[1..], argv);
    return installCommand(io, install_argv, stdout, stderr);
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

const DoctorTarget = enum { all, codex, claude, opencode, openclaw, hermes };

fn doctorCommand(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var target: DoctorTarget = .all;
    var json_mode = false;

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(
                \\Usage:
                \\  ryk plugin doctor
                \\  ryk plugin doctor [--json]
                \\  ryk plugin doctor codex
                \\  ryk plugin doctor claude
                \\  ryk plugin doctor opencode
                \\  ryk plugin doctor openclaw
                \\  ryk plugin doctor hermes
                \\  ryk plugin doctor codex [--json]
                \\  ryk plugin doctor claude [--json]
                \\  ryk plugin doctor opencode [--json]
                \\  ryk plugin doctor openclaw [--json]
                \\  ryk plugin doctor hermes [--json]
                \\
            );
            return exit_codes.success;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "codex")) {
            target = .codex;
            continue;
        }
        if (std.mem.eql(u8, arg, "claude")) {
            target = .claude;
            continue;
        }
        if (std.mem.eql(u8, arg, "opencode")) {
            target = .opencode;
            continue;
        }
        if (std.mem.eql(u8, arg, "openclaw")) {
            target = .openclaw;
            continue;
        }
        if (std.mem.eql(u8, arg, "hermes") or std.mem.eql(u8, arg, "hermess")) {
            target = .hermes;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk plugin doctor", arg, &.{ "--json", "--help", "-h", "codex", "claude", "opencode", "openclaw", "hermes" }, "plugin");
        return exit_codes.usage;
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var report = try collectPluginDoctorReport(io, allocator);
    defer deinitPluginDoctorReport(&report, allocator);

    if (json_mode) {
        try writeDoctorJson(stdout, report, target);
    } else {
        try writeDoctorPlain(io, allocator, stdout, report, target);
    }
    return exit_codes.success;
}

// ---------------------------------------------------------------------------
// Plugin doctor report data
// ---------------------------------------------------------------------------

pub const PluginDirStatus = struct {
    codex: bool,
    claude: bool,
    opencode: bool,
    openclaw: bool,
    hermes: bool,
    common: bool,
};

pub const HostBinaryStatus = struct {
    codex: bool,
    claude: bool,
    opencode: bool,
    openclaw: bool,
    hermes: bool,
};

pub const OpenCodePaths = struct {
    project_plugin_exists: bool,
    global_plugin_exists: bool,
    config_references_plugin: bool,
};

pub const OpenClawHostInstall = struct {
    host_plugin_installed: bool,
    plugin_manifest_exists: bool,
    package_json_exists: bool,
    source_exists: bool,
    detection_note: []const u8,
};

pub const HermesPaths = struct {
    repo_manifest_exists: bool,
    repo_source_exists: bool,
    user_manifest_exists: bool,
    user_source_exists: bool,
    config_references_plugin: bool,
};

pub const MarketplaceStatus = struct {
    codex_marketplace: bool,
    claude_marketplace: bool,
    codex_plugin_manifest: bool,
    claude_plugin_manifest: bool,
    codex_user_plugin: bool,
    claude_user_plugin: bool,
};

pub const PluginDoctorReport = struct {
    orca_version: []const u8,
    orca_binary_path: ?[:0]u8,
    cwd: [:0]u8,
    workspace_root: []const u8,
    policy_present: bool,
    policy_valid: bool,
    policy_error: ?[]const u8,
    audit_replay_available: bool,
    mcp_support_status: []const u8,
    plugin_directories: PluginDirStatus,
    host_binaries: HostBinaryStatus,
    opencode_paths: OpenCodePaths,
    openclaw_paths: OpenClawHostInstall,
    hermes_paths: HermesPaths,
    hermes_hook_smoke_passed: bool,
    marketplace: MarketplaceStatus,
    platform_summary: []const u8,
    warnings: [][]const u8,
};

pub fn deinitPluginDoctorReport(report: *PluginDoctorReport, allocator: std.mem.Allocator) void {
    allocator.free(report.cwd);
    allocator.free(report.workspace_root);
    if (report.policy_error) |e| allocator.free(e);
    allocator.free(report.mcp_support_status);
    allocator.free(report.platform_summary);
    if (report.warnings.len > 0) {
        for (report.warnings) |w| allocator.free(w);
        allocator.free(report.warnings);
    }
    if (report.orca_binary_path) |p| allocator.free(p);
    report.* = undefined;
}

pub fn collectPluginDoctorReport(io: std.Io, allocator: std.mem.Allocator) !PluginDoctorReport {
    return collectPluginDoctorReportWithHermesSmoke(io, allocator, null);
}

fn listCommand(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len > 0) {
        if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
            try stdout.writeAll("Usage:\n  ryk plugin list\n");
            return exit_codes.success;
        }
        try suggestions.writeUnknownOption(stderr, "ryk plugin list", argv[0], &.{ "--help", "-h" }, "plugin");
        return exit_codes.usage;
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    var report = try collectPluginDoctorReport(io, allocator);
    defer deinitPluginDoctorReport(&report, allocator);
    try writePluginList(io, allocator, stdout, report);
    return exit_codes.success;
}

const PluginInventoryItem = struct {
    host: []const u8,
    detected: bool,
    installed: bool,
};

fn pluginInventory(report: PluginDoctorReport) [5]PluginInventoryItem {
    return .{
        .{ .host = "Codex", .detected = report.host_binaries.codex, .installed = hostPluginInstalledFromReport("codex", report) },
        .{ .host = "Claude Code", .detected = report.host_binaries.claude, .installed = hostPluginInstalledFromReport("claude", report) },
        .{ .host = "OpenCode", .detected = report.host_binaries.opencode, .installed = hostPluginInstalledFromReport("opencode", report) },
        .{ .host = "OpenClaw", .detected = report.host_binaries.openclaw, .installed = hostPluginInstalledFromReport("openclaw", report) },
        .{ .host = "Hermes", .detected = report.host_binaries.hermes, .installed = hostPluginInstalledFromReport("hermes", report) },
    };
}

fn writePluginList(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, report: PluginDoctorReport) !void {
    const inventory = pluginInventory(report);
    const rows = try allocator.alloc([]const []const u8, inventory.len);
    defer allocator.free(rows);
    var initialized: usize = 0;
    defer for (rows[0..initialized]) |row| allocator.free(row);
    var detected_count: usize = 0;
    var installed_count: usize = 0;

    for (inventory, 0..) |item, index| {
        if (item.detected) detected_count += 1;
        if (item.installed) installed_count += 1;
        const cells = try allocator.alloc([]const u8, 4);
        cells[0] = item.host;
        cells[1] = if (item.detected) "yes" else "no";
        cells[2] = if (item.installed) "yes" else "no";
        // Never claim "ready/protected" without smoke evidence (install/doctor own that).
        cells[3] = if (item.installed and item.detected)
            "installed"
        else if (item.installed)
            "installed; host missing"
        else if (item.detected)
            "not installed"
        else
            "host not detected";
        rows[index] = cells;
        initialized += 1;
    }

    try tui.render.table(io, stdout, &.{
        .{ .name = "HOST" }, .{ .name = "DETECTED" }, .{ .name = "INSTALLED" }, .{ .name = "STATUS" },
    }, rows);
    if (detected_count == 0) {
        try stdout.writeAll("\nNo supported host CLIs detected. Install a host, then run 'ryk plugin list' again.\n");
    }
    if (installed_count == 0) {
        try stdout.writeAll("Preview setup with 'ryk plugin codex --dry-run' (or replace codex with your host).\n");
    }
}

/// When `hermes_smoke_override` is non-null, skip spawning the Hermes hook smoke test
/// and use the provided boolean. Prefer this for lightweight host inventory paths
/// (e.g. `orca doctor` host table) that should not pay smoke-test latency.
pub fn collectPluginDoctorReportWithHermesSmoke(
    io: std.Io,
    allocator: std.mem.Allocator,
    hermes_smoke_override: ?bool,
) !PluginDoctorReport {
    const cwd: [:0]u8 = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch try allocator.dupeZ(u8, ".");
    errdefer allocator.free(cwd);
    const workspace_root = supervisor.resolveWorkspaceRoot(io, allocator, null, ".") catch try allocator.dupe(u8, cwd);
    errdefer allocator.free(workspace_root);

    const policy_path = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "policy.yaml" });
    defer allocator.free(policy_path);
    var policy_present = false;
    var policy_valid = false;
    var policy_error: ?[]const u8 = null;
    errdefer if (policy_error) |e| allocator.free(e);
    if (fileExistsAbsolute(io, policy_path)) {
        policy_present = true;
        if (core_api.loadPolicyFile(io, allocator, policy_path)) |loaded_policy| {
            var loaded = loaded_policy;
            loaded.deinit();
            policy_valid = true;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            policy_error = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
        }
    }

    const audit_replay_available = hasPath(workspace_root, ".orca/sessions");
    const mcp_support = "stdio proxy active; HTTP transport deferred";

    const plugin_dirs = PluginDirStatus{
        .codex = pluginDirExists(io, allocator, "integrations/codex-plugin"),
        .claude = pluginDirExists(io, allocator, "integrations/claude-code-plugin"),
        .opencode = pluginDirExists(io, allocator, "integrations/opencode-plugin"),
        .openclaw = pluginDirExists(io, allocator, "integrations/openclaw-plugin"),
        .hermes = pluginDirExists(io, allocator, "integrations/hermes-plugin"),
        .common = pluginDirExists(io, allocator, "integrations/common"),
    };

    // One PATH snapshot for all host lookups — avoids rebuilding the full process
    // env map five times (and multiplies badly under checkAllAllocationFailures).
    const path_value: ?[]u8 = blk: {
        var env_map = env_util.createProcessMap(allocator) catch break :blk null;
        defer env_map.deinit();
        break :blk env_util.getOwned(&env_map, allocator, "PATH") catch null;
    };
    defer if (path_value) |p| allocator.free(p);

    const host_bins = HostBinaryStatus{
        .codex = if (path_value) |p| binaryOnSearchPath(io, allocator, p, "codex") else false,
        .claude = if (path_value) |p| binaryOnSearchPath(io, allocator, p, "claude") else false,
        .opencode = if (path_value) |p| binaryOnSearchPath(io, allocator, p, "opencode") else false,
        .openclaw = if (path_value) |p| binaryOnSearchPath(io, allocator, p, "openclaw") else false,
        .hermes = if (path_value) |p| binaryOnSearchPath(io, allocator, p, "hermes") else false,
    };

    // Check OpenCode-specific plugin paths
    const opencode_project_path = try std.fs.path.join(allocator, &.{ workspace_root, ".opencode", "plugins", "orca.ts" });
    defer allocator.free(opencode_project_path);

    const opencode_global_path = blk: {
        var env_map = env_util.createProcessMap(allocator) catch {
            break :blk try std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
        };
        defer env_map.deinit();
        const home_owned = env_util.getOwned(&env_map, allocator, "HOME") catch {
            break :blk try std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
        };
        const home = home_owned orelse break :blk try std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".config", "opencode", "plugins", "orca.ts" });
    };
    defer allocator.free(opencode_global_path);

    const opencode_paths = OpenCodePaths{
        .project_plugin_exists = fileExistsAbsolute(io, opencode_project_path),
        .global_plugin_exists = fileExistsAbsolute(io, opencode_global_path),
        .config_references_plugin = false, // Safe detection deferred
    };

    const openclaw_paths = try detectOpenClawHostInstall(io, allocator, host_bins.openclaw);

    const hermes_plugin_dir = try resolveBundledPath(io, allocator, "integrations/hermes-plugin");
    defer allocator.free(hermes_plugin_dir);
    const hermes_repo_manifest_path = try std.fs.path.join(allocator, &.{ hermes_plugin_dir, "plugin.yaml" });
    defer allocator.free(hermes_repo_manifest_path);
    const hermes_repo_source_path = try std.fs.path.join(allocator, &.{ hermes_plugin_dir, "__init__.py" });
    defer allocator.free(hermes_repo_source_path);
    const hermes_user_root = try hermesUserPluginRoot(allocator);
    defer allocator.free(hermes_user_root);
    const hermes_user_manifest_path = try std.fs.path.join(allocator, &.{ hermes_user_root, "plugin.yaml" });
    defer allocator.free(hermes_user_manifest_path);
    const hermes_user_source_path = try std.fs.path.join(allocator, &.{ hermes_user_root, "__init__.py" });
    defer allocator.free(hermes_user_source_path);
    const hermes_config_path = try hermesConfigPath(allocator);
    defer allocator.free(hermes_config_path);

    const hermes_paths = HermesPaths{
        .repo_manifest_exists = fileExistsAbsolute(io, hermes_repo_manifest_path),
        .repo_source_exists = fileExistsAbsolute(io, hermes_repo_source_path),
        .user_manifest_exists = fileExistsAbsolute(io, hermes_user_manifest_path),
        .user_source_exists = fileExistsAbsolute(io, hermes_user_source_path),
        .config_references_plugin = fileContains(allocator, hermes_config_path, "orca"),
    };

    const codex_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "plugins", "marketplace.json" });
    defer allocator.free(codex_marketplace_path);
    const claude_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".claude-plugin", "marketplace.json" });
    defer allocator.free(claude_marketplace_path);
    const codex_user_plugin_path = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "plugins", "orca", ".codex-plugin", "plugin.json" });
    defer allocator.free(codex_user_plugin_path);
    const claude_user_plugin_path = try std.fs.path.join(allocator, &.{ workspace_root, ".claude", "plugins", "orca", ".claude-plugin", "plugin.json" });
    defer allocator.free(claude_user_plugin_path);
    const codex_bundled_manifest = try resolveBundledPath(io, allocator, "integrations/codex-plugin/.codex-plugin/plugin.json");
    defer allocator.free(codex_bundled_manifest);
    const claude_bundled_manifest = try resolveBundledPath(io, allocator, "integrations/claude-code-plugin/.claude-plugin/plugin.json");
    defer allocator.free(claude_bundled_manifest);

    const marketplace = MarketplaceStatus{
        .codex_marketplace = fileExistsAbsolute(io, codex_marketplace_path),
        .claude_marketplace = fileExistsAbsolute(io, claude_marketplace_path),
        .codex_plugin_manifest = fileExistsAbsolute(io, codex_bundled_manifest),
        .claude_plugin_manifest = fileExistsAbsolute(io, claude_bundled_manifest),
        .codex_user_plugin = fileExistsAbsolute(io, codex_user_plugin_path),
        .claude_user_plugin = fileExistsAbsolute(io, claude_user_plugin_path),
    };

    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
    }
    if (!plugin_dirs.common) try appendWarning(allocator, &warnings, "integrations/common directory missing");
    if (!plugin_dirs.codex) try appendWarning(allocator, &warnings, "Codex plugin directory not yet created");
    if (!plugin_dirs.claude) try appendWarning(allocator, &warnings, "Claude Code plugin directory not yet created");
    if (!plugin_dirs.opencode) try appendWarning(allocator, &warnings, "OpenCode plugin directory not yet created");
    if (!plugin_dirs.openclaw) try appendWarning(allocator, &warnings, "OpenClaw plugin directory not yet created");
    if (!plugin_dirs.hermes) try appendWarning(allocator, &warnings, "Hermes plugin directory not yet created");
    if (!host_bins.codex) try appendWarning(allocator, &warnings, "Codex host binary not found in PATH");
    if (!host_bins.claude) try appendWarning(allocator, &warnings, "Claude Code host binary not found in PATH");
    if (!host_bins.opencode) try appendWarning(allocator, &warnings, "OpenCode host binary not found in PATH");
    if (!host_bins.openclaw) try appendWarning(allocator, &warnings, "OpenClaw host binary not found in PATH");
    if (!host_bins.hermes) try appendWarning(allocator, &warnings, "Hermes host binary not found in PATH");

    const hermes_hook_smoke_passed = hermes_smoke_override orelse blk: {
        const result = smokeTestHook(allocator, "hermes", "pre_tool_call", "tests/fixtures/hook-safe.json", "allow") catch break :blk false;
        break :blk result.passed;
    };
    if (!hermes_hook_smoke_passed) {
        try appendWarning(allocator, &warnings, "Hermes hook smoke test failed: Orca may be too old for Hermes hooks (upgrade via ./scripts/install-orca-plugin.sh hermes)");
    }

    const os = core.platform.detectOs();
    const backend_report = sandbox.backend.detect(os);
    const platform_summary = try std.fmt.allocPrint(allocator, "{s} / {s} / fallback: {s}", .{
        os.toString(),
        backend_report.backend_name,
        backend_report.fallback_level.toString(),
    });
    errdefer allocator.free(platform_summary);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const binary_path = std.process.executablePathAlloc(threaded.io(), allocator) catch null;
    errdefer if (binary_path) |p| allocator.free(p);
    const mcp_support_status = try allocator.dupe(u8, mcp_support);
    errdefer allocator.free(mcp_support_status);
    const warning_items = try warnings.toOwnedSlice(allocator);

    return .{
        .orca_version = cli.version,
        .orca_binary_path = binary_path,
        .cwd = cwd,
        .workspace_root = workspace_root,
        .policy_present = policy_present,
        .policy_valid = policy_valid,
        .policy_error = policy_error,
        .audit_replay_available = audit_replay_available,
        .mcp_support_status = mcp_support_status,
        .plugin_directories = plugin_dirs,
        .host_binaries = host_bins,
        .opencode_paths = opencode_paths,
        .openclaw_paths = openclaw_paths,
        .hermes_paths = hermes_paths,
        .hermes_hook_smoke_passed = hermes_hook_smoke_passed,
        .marketplace = marketplace,
        .platform_summary = platform_summary,
        .warnings = warning_items,
    };
}

fn appendWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList([]const u8), message: []const u8) !void {
    const owned = try allocator.dupe(u8, message);
    errdefer allocator.free(owned);
    try warnings.append(allocator, owned);
}

// ---------------------------------------------------------------------------
// doctor plain output
// ---------------------------------------------------------------------------

fn writeDoctorPlain(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, report: PluginDoctorReport, target: DoctorTarget) !void {
    try stdout.writeAll("Orca Plugin Doctor\n\n");

    try stdout.print("Orca version: {s}\n", .{report.orca_version});
    if (report.orca_binary_path) |path| {
        try stdout.print("Orca binary: {s}\n", .{path});
    } else {
        try stdout.writeAll("Orca binary: unknown\n");
    }
    try stdout.print("Current directory: {s}\n", .{report.cwd});
    try stdout.print("Workspace root: {s}\n", .{report.workspace_root});

    try stdout.writeAll("\nPolicy:\n");
    if (report.policy_present) {
        if (report.policy_valid) {
            try stdout.writeAll("  .orca/policy.yaml: present and valid\n");
        } else {
            try stdout.print("  .orca/policy.yaml: invalid ({s})\n", .{report.policy_error orelse "validation failed"});
        }
    } else {
        try stdout.writeAll("  .orca/policy.yaml: missing\n");
        try stdout.writeAll("    → Fix: ryk init --preset generic-agent\n");
    }

    try stdout.writeAll("\nAudit / replay:\n");
    try stdout.print("  {s}\n", .{if (report.audit_replay_available) "session artifacts present" else "no local sessions detected"});

    try stdout.writeAll("\nMCP support:\n");
    try stdout.print("  {s}\n", .{report.mcp_support_status});

    // Unified host status table (same fields as `orca doctor`).
    try writeUnifiedHostStatusTable(io, allocator, stdout, report, target);

    try stdout.writeAll("\nPlugin directories:\n");
    try stdout.print("  integrations/common: {s}\n", .{if (report.plugin_directories.common) "found" else "missing"});
    if (!report.plugin_directories.common) try stdout.writeAll("    → Fix: ryk start or ryk plugin install all\n");
    try stdout.print("  integrations/codex-plugin: {s}\n", .{if (report.plugin_directories.codex) "found" else "missing"});
    if (!report.plugin_directories.codex) try stdout.writeAll("    → Fix: ryk start or ryk plugin install codex\n");
    try stdout.print("  integrations/claude-code-plugin: {s}\n", .{if (report.plugin_directories.claude) "found" else "missing"});
    if (!report.plugin_directories.claude) try stdout.writeAll("    → Fix: ryk start or ryk plugin install claude\n");
    try stdout.print("  integrations/opencode-plugin: {s}\n", .{if (report.plugin_directories.opencode) "found" else "missing"});
    if (!report.plugin_directories.opencode) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
    try stdout.print("  integrations/openclaw-plugin: {s}\n", .{if (report.plugin_directories.openclaw) "found" else "missing"});
    if (!report.plugin_directories.openclaw) try stdout.writeAll("    → Fix: ryk start or ryk plugin install openclaw\n");
    try stdout.print("  integrations/hermes-plugin: {s}\n", .{if (report.plugin_directories.hermes) "found" else "missing"});
    if (!report.plugin_directories.hermes) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");

    try stdout.writeAll("\nHost binaries:\n");
    try stdout.print("  codex: {s}\n", .{if (report.host_binaries.codex) "found in PATH" else "not found"});
    if (!report.host_binaries.codex) try stdout.writeAll("    → Fix: ryk start or ryk plugin install codex\n");
    try stdout.print("  claude: {s}\n", .{if (report.host_binaries.claude) "found in PATH" else "not found"});
    if (!report.host_binaries.claude) try stdout.writeAll("    → Fix: ryk start or ryk plugin install claude\n");
    try stdout.print("  opencode: {s}\n", .{if (report.host_binaries.opencode) "found in PATH" else "not found"});
    if (!report.host_binaries.opencode) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
    try stdout.print("  openclaw: {s}\n", .{if (report.host_binaries.openclaw) "found in PATH" else "not found"});
    if (!report.host_binaries.openclaw) try stdout.writeAll("    → Fix: ryk start or ryk plugin install openclaw\n");
    try stdout.print("  hermes: {s}\n", .{if (report.host_binaries.hermes) "found in PATH" else "not found"});
    if (!report.host_binaries.hermes) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");

    try stdout.writeAll("\nMarketplace files:\n");
    try stdout.print("  .agents/plugins/marketplace.json: {s}\n", .{if (report.marketplace.codex_marketplace) "present" else "missing"});
    if (!report.marketplace.codex_marketplace) try stdout.writeAll("    → Fix: ryk start or ryk plugin install codex\n");
    try stdout.print("  .claude-plugin/marketplace.json: {s}\n", .{if (report.marketplace.claude_marketplace) "present" else "missing"});
    if (!report.marketplace.claude_marketplace) try stdout.writeAll("    → Fix: ryk start or ryk plugin install claude\n");

    try stdout.writeAll("\nPlatform:\n");
    try stdout.print("  {s}\n", .{report.platform_summary});

    if (report.warnings.len > 0) {
        try stdout.writeAll("\nWarnings:\n");
        for (report.warnings) |w| {
            try stdout.print("  - {s}\n", .{w});
        }
    }

    // Target-specific section
    switch (target) {
        .all => {},
        .codex => {
            try stdout.writeAll("\nCodex plugin status:\n");
            try stdout.print("  host binary: {s}\n", .{if (report.host_binaries.codex) "detected" else "not detected"});
            if (!report.host_binaries.codex) try stdout.writeAll("    → Fix: install Codex and re-run ryk start or ryk plugin install codex\n");
            try stdout.print("  bundled plugin directory: {s}\n", .{if (report.plugin_directories.codex) "present" else "missing"});
            if (!report.plugin_directories.codex) try stdout.writeAll("    → Fix: install Orca runtime assets or set ORCA_RESOURCE_ROOT\n");
            try stdout.print("  user plugin registration: {s}\n", .{if (report.marketplace.codex_user_plugin) "installed" else "missing"});
            if (!report.marketplace.codex_user_plugin) try stdout.writeAll("    → Fix: ryk start or ryk plugin install codex\n");
            try stdout.print("  marketplace file: {s}\n", .{if (report.marketplace.codex_marketplace) "present" else "missing"});
            if (!report.marketplace.codex_marketplace) try stdout.writeAll("    → Fix: ryk start or ryk plugin install codex\n");
            try stdout.print("  bundled plugin manifest: {s}\n", .{if (report.marketplace.codex_plugin_manifest) "present" else "missing"});
            if (!report.marketplace.codex_plugin_manifest) try stdout.writeAll("    → Fix: install Orca runtime assets or set ORCA_RESOURCE_ROOT\n");
            try stdout.writeAll("  install: use 'ryk plugin install codex --dry-run' to preview\n");
        },
        .claude => {
            try stdout.writeAll("\nClaude Code plugin status:\n");
            try stdout.print("  host binary: {s}\n", .{if (report.host_binaries.claude) "detected" else "not detected"});
            if (!report.host_binaries.claude) try stdout.writeAll("    → Fix: install Claude Code and re-run ryk start or ryk plugin install claude\n");
            try stdout.print("  bundled plugin directory: {s}\n", .{if (report.plugin_directories.claude) "present" else "missing"});
            if (!report.plugin_directories.claude) try stdout.writeAll("    → Fix: install Orca runtime assets or set ORCA_RESOURCE_ROOT\n");
            try stdout.print("  user plugin registration: {s}\n", .{if (report.marketplace.claude_user_plugin) "installed" else "missing"});
            if (!report.marketplace.claude_user_plugin) try stdout.writeAll("    → Fix: ryk start or ryk plugin install claude\n");
            try stdout.print("  marketplace file: {s}\n", .{if (report.marketplace.claude_marketplace) "present" else "missing"});
            if (!report.marketplace.claude_marketplace) try stdout.writeAll("    → Fix: ryk start or ryk plugin install claude\n");
            try stdout.print("  bundled plugin manifest: {s}\n", .{if (report.marketplace.claude_plugin_manifest) "present" else "missing"});
            if (!report.marketplace.claude_plugin_manifest) try stdout.writeAll("    → Fix: install Orca runtime assets or set ORCA_RESOURCE_ROOT\n");
            try stdout.writeAll("  install: use 'ryk plugin install claude --dry-run' to preview\n");
        },
        .opencode => {
            try stdout.writeAll("\nOpenCode plugin status:\n");
            try stdout.print("  host binary: {s}\n", .{if (report.host_binaries.opencode) "detected" else "not detected"});
            if (!report.host_binaries.opencode) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
            try stdout.print("  plugin directory: {s}\n", .{if (report.plugin_directories.opencode) "present" else "not yet created"});
            if (!report.plugin_directories.opencode) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
            try stdout.print("  project plugin path (.opencode/plugins/orca.ts): {s}\n", .{if (report.opencode_paths.project_plugin_exists) "exists" else "not found"});
            if (!report.opencode_paths.project_plugin_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
            try stdout.print("  global plugin path (~/.config/opencode/plugins/orca.ts): {s}\n", .{if (report.opencode_paths.global_plugin_exists) "exists" else "not found"});
            if (!report.opencode_paths.global_plugin_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install opencode\n");
            try stdout.writeAll("  install: use 'ryk plugin install opencode --dry-run' to preview\n");
            try stdout.writeAll("  note: OpenCode plugin uses TypeScript hooks, not a manifest file\n");
        },
        .openclaw => {
            try stdout.writeAll("\nOpenClaw plugin status:\n");
            try stdout.print("  host binary: {s}\n", .{if (report.host_binaries.openclaw) "detected" else "not detected"});
            if (!report.host_binaries.openclaw) try stdout.writeAll("    → Fix: install OpenClaw and re-run ryk start or ryk plugin install openclaw\n");
            try stdout.print("  bundled plugin directory: {s}\n", .{if (report.plugin_directories.openclaw) "present" else "missing"});
            if (!report.plugin_directories.openclaw) try stdout.writeAll("    → Fix: install Orca runtime assets or set ORCA_RESOURCE_ROOT\n");
            try stdout.print("  host plugin installed: {s}\n", .{if (report.openclaw_paths.host_plugin_installed) "yes" else "no"});
            if (!report.openclaw_paths.host_plugin_installed) try stdout.writeAll("    → Fix: ryk start or ryk plugin install openclaw\n");
            try stdout.print("  host plugin manifest (openclaw.plugin.json): {s}\n", .{if (report.openclaw_paths.plugin_manifest_exists) "exists" else "not found"});
            if (!report.openclaw_paths.plugin_manifest_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install openclaw\n");
            try stdout.print("  host package.json: {s}\n", .{if (report.openclaw_paths.package_json_exists) "exists" else "not found"});
            try stdout.print("  host source (src/index.ts): {s}\n", .{if (report.openclaw_paths.source_exists) "exists" else "not found"});
            try stdout.print("  detection note: {s}\n", .{report.openclaw_paths.detection_note});
            try openclaw_status.writeDoctorHonesty(stdout);
        },
        .hermes => {
            try stdout.writeAll("\nHermes plugin status:\n");
            try stdout.print("  host binary: {s}\n", .{if (report.host_binaries.hermes) "detected" else "not detected"});
            if (!report.host_binaries.hermes) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            try stdout.print("  plugin directory: {s}\n", .{if (report.plugin_directories.hermes) "present" else "not yet created"});
            if (!report.plugin_directories.hermes) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            try stdout.print("  repo plugin.yaml: {s}\n", .{if (report.hermes_paths.repo_manifest_exists) "exists" else "not found"});
            if (!report.hermes_paths.repo_manifest_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            try stdout.print("  repo __init__.py: {s}\n", .{if (report.hermes_paths.repo_source_exists) "exists" else "not found"});
            if (!report.hermes_paths.repo_source_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            try stdout.print("  user plugin path (~/.hermes/plugins/orca/plugin.yaml): {s}\n", .{if (report.hermes_paths.user_manifest_exists) "exists" else "not found"});
            if (!report.hermes_paths.user_manifest_exists) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            try stdout.print("  config references plugin: {s}\n", .{if (report.hermes_paths.config_references_plugin) "yes" else "unknown/no"});
            if (!report.hermes_paths.config_references_plugin) try stdout.writeAll("    → Fix: ryk start or ryk plugin install hermes\n");
            const hermes_fail_open = host_status.hermesFailOpenFromEnv();
            try stdout.print("  fail stance: {s}\n", .{host_status.failStance("hermes", hermes_fail_open)});
            if (hermes_fail_open) {
                try stdout.writeAll("    → WARN: Hermes is fail-open when Orca is degraded (default product stance).\n");
                try stdout.writeAll("    → Fix: export ORCA_HERMES_FAIL_OPEN=0  # or: ryk run -- hermes\n");
            }
            try stdout.print("  hook smoke test (pre_tool_call allow): {s}\n", .{if (report.hermes_hook_smoke_passed) "passed" else "FAILED"});
            if (!report.hermes_hook_smoke_passed) try stdout.writeAll("    → Fix: upgrade Orca (./scripts/install-orca-plugin.sh hermes) or set ORCA_BIN to a build with Hermes host support\n");
            try stdout.writeAll("  install: use 'ryk plugin install hermes --dry-run' to preview\n");
            try stdout.writeAll("  note: Hermes hooks are additive; strongest protection remains 'ryk run -- hermes'\n");
            try stdout.writeAll("  note: Gateway (Telegram/Discord) may omit the block reason in chat; check agent tool errors.\n");
        },
    }

    try stdout.writeAll("\n");
}

fn hostBinaryDetected(report: PluginDoctorReport, host_name: []const u8) bool {
    if (std.mem.eql(u8, host_name, "codex")) return report.host_binaries.codex;
    if (std.mem.eql(u8, host_name, "claude")) return report.host_binaries.claude;
    if (std.mem.eql(u8, host_name, "opencode")) return report.host_binaries.opencode;
    if (std.mem.eql(u8, host_name, "openclaw")) return report.host_binaries.openclaw;
    if (std.mem.eql(u8, host_name, "hermes")) return report.host_binaries.hermes;
    return false;
}

fn smokeForPluginDoctor(
    allocator: std.mem.Allocator,
    report: PluginDoctorReport,
    host_name: []const u8,
    target: DoctorTarget,
) host_status.HostSmokePair {
    // Live allow+deny only for single-host doctor (avoids multi-host latency).
    if (target != .all and std.mem.eql(u8, host_name, @tagName(target))) {
        return host_status.runHostSmokePair(allocator, host_name) catch .{ .allow = .fail, .deny = .fail };
    }
    if (std.mem.eql(u8, host_name, "hermes")) {
        return .{
            .allow = if (report.hermes_hook_smoke_passed) .pass else .fail,
            .deny = .not_run,
        };
    }
    return .{};
}

fn writeUnifiedHostStatusTable(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    report: PluginDoctorReport,
    target: DoctorTarget,
) !void {
    try stdout.writeAll("\nHost status:\n");
    const hermes_fail_open = host_status.hermesFailOpenFromEnv();

    var row_hosts: std.ArrayList([]const u8) = .empty;
    defer row_hosts.deinit(allocator);
    for (host_status.managed_hosts) |host_name| {
        if (target != .all and !std.mem.eql(u8, host_name, @tagName(target))) continue;
        try row_hosts.append(allocator, host_name);
    }
    // Pi always listed on full doctor; include when targeting is all only.
    const include_pi = target == .all;
    const row_count = row_hosts.items.len + @as(usize, if (include_pi) 1 else 0);

    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    var rows = try allocator.alloc([]const []const u8, row_count);
    defer {
        for (rows) |row| allocator.free(row);
        allocator.free(rows);
    }
    var fix_lines: std.ArrayList(struct { host: []const u8, fix: []const u8 }) = .empty;
    defer fix_lines.deinit(allocator);

    for (row_hosts.items, 0..) |host_name, i| {
        const installed = hostPluginInstalledFromReport(host_name, report);
        const detected = hostBinaryDetected(report, host_name);
        const wired: []const u8 = if (installed) "yes" else if (detected) "no" else "—";
        const smoke = smokeForPluginDoctor(allocator, report, host_name, target);
        const allow_s = try allocator.dupe(u8, smoke.allow.toString());
        try owned.append(allocator, allow_s);
        const deny_s = try allocator.dupe(u8, smoke.deny.toString());
        try owned.append(allocator, deny_s);
        const fix = try host_status.formatFix(allocator, host_name, wired, smoke, hermes_fail_open);
        try owned.append(allocator, fix);
        if (!std.mem.eql(u8, fix, "—")) {
            try fix_lines.append(allocator, .{ .host = host_name, .fix = fix });
        }
        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = host_name;
        cells[1] = wired;
        cells[2] = host_status.shellGate(host_name);
        cells[3] = host_status.failStance(host_name, hermes_fail_open);
        cells[4] = allow_s;
        cells[5] = deny_s;
        rows[i] = cells;
    }

    if (include_pi) {
        const pi_status = host_status.inspectPi(io, allocator);
        const wired = pi_status.wiredLabel();
        const smoke = host_status.HostSmokePair{};
        const allow_s = try allocator.dupe(u8, smoke.allow.toString());
        try owned.append(allocator, allow_s);
        const deny_s = try allocator.dupe(u8, smoke.deny.toString());
        try owned.append(allocator, deny_s);
        const fix = try host_status.formatFix(allocator, "pi", wired, smoke, hermes_fail_open);
        try owned.append(allocator, fix);
        if (!std.mem.eql(u8, fix, "—")) {
            try fix_lines.append(allocator, .{ .host = "pi", .fix = fix });
        }
        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = "pi";
        cells[1] = wired;
        cells[2] = host_status.shellGate("pi");
        cells[3] = host_status.failStance("pi", hermes_fail_open);
        cells[4] = allow_s;
        cells[5] = deny_s;
        rows[row_hosts.items.len] = cells;
    }

    try tui.render.table(io, stdout, &.{
        .{ .name = "HOST" },
        .{ .name = "WIRED" },
        .{ .name = "SHELL GATE" },
        .{ .name = "FAIL STANCE" },
        .{ .name = "SMOKE ALLOW" },
        .{ .name = "SMOKE DENY" },
    }, rows);

    for (fix_lines.items) |line| {
        try stdout.print("  fix {s}: {s}\n", .{ line.host, line.fix });
    }
    if (include_pi) {
        try stdout.writeAll("  note pi: not managed by `ryk plugin install`; extension coverage unknown until live smoke\n");
        try stdout.writeAll("    → install: pi install npm:@orca-sec/pi-orca · process: ryk run -- pi\n");
    }
    if (hostPluginInstalledFromReport("hermes", report) and hermes_fail_open and (target == .all or target == .hermes)) {
        try stdout.writeAll("  warn hermes: effective fail-open when Orca degraded — set ORCA_HERMES_FAIL_OPEN=0 or use ryk run -- hermes\n");
    }
}

// ---------------------------------------------------------------------------
// doctor JSON output
// ---------------------------------------------------------------------------

fn writeDoctorJson(stdout: anytype, report: PluginDoctorReport, target: DoctorTarget) !void {
    try stdout.writeAll("{\n");
    try stdout.writeAll("  \"orca_version\": ");
    try writeJsonString(stdout, report.orca_version);
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"orca_binary_path\": ");
    if (report.orca_binary_path) |path| {
        try writeJsonString(stdout, path);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\n");

    try stdout.print("  \"cwd\": ", .{});
    try writeJsonString(stdout, report.cwd);
    try stdout.writeAll(",\n");

    try stdout.print("  \"workspace_root\": ", .{});
    try writeJsonString(stdout, report.workspace_root);
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"policy\": {\n");
    try stdout.print("    \"present\": {s},\n", .{if (report.policy_present) "true" else "false"});
    try stdout.print("    \"valid\": {s}\n", .{if (report.policy_valid) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"audit_replay_available\": ");
    try stdout.writeAll(if (report.audit_replay_available) "true" else "false");
    try stdout.writeAll(",\n");

    try stdout.print("  \"mcp_support_status\": ", .{});
    try writeJsonString(stdout, report.mcp_support_status);
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"plugin_directories\": {\n");
    try stdout.print("    \"codex\": {s},\n", .{if (report.plugin_directories.codex) "true" else "false"});
    try stdout.print("    \"claude\": {s},\n", .{if (report.plugin_directories.claude) "true" else "false"});
    try stdout.print("    \"opencode\": {s},\n", .{if (report.plugin_directories.opencode) "true" else "false"});
    try stdout.print("    \"openclaw\": {s},\n", .{if (report.plugin_directories.openclaw) "true" else "false"});
    try stdout.print("    \"hermes\": {s},\n", .{if (report.plugin_directories.hermes) "true" else "false"});
    try stdout.print("    \"common\": {s}\n", .{if (report.plugin_directories.common) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"host_binaries\": {\n");
    try stdout.print("    \"codex\": {s},\n", .{if (report.host_binaries.codex) "true" else "false"});
    try stdout.print("    \"claude\": {s},\n", .{if (report.host_binaries.claude) "true" else "false"});
    try stdout.print("    \"opencode\": {s},\n", .{if (report.host_binaries.opencode) "true" else "false"});
    try stdout.print("    \"openclaw\": {s},\n", .{if (report.host_binaries.openclaw) "true" else "false"});
    try stdout.print("    \"hermes\": {s}\n", .{if (report.host_binaries.hermes) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"opencode_paths\": {\n");
    try stdout.print("    \"project_plugin_exists\": {s},\n", .{if (report.opencode_paths.project_plugin_exists) "true" else "false"});
    try stdout.print("    \"global_plugin_exists\": {s},\n", .{if (report.opencode_paths.global_plugin_exists) "true" else "false"});
    try stdout.print("    \"config_references_plugin\": {s}\n", .{if (report.opencode_paths.config_references_plugin) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"openclaw_paths\": {\n");
    try stdout.print("    \"host_plugin_installed\": {s},\n", .{if (report.openclaw_paths.host_plugin_installed) "true" else "false"});
    try stdout.print("    \"plugin_manifest_exists\": {s},\n", .{if (report.openclaw_paths.plugin_manifest_exists) "true" else "false"});
    try stdout.print("    \"package_json_exists\": {s},\n", .{if (report.openclaw_paths.package_json_exists) "true" else "false"});
    try stdout.print("    \"source_exists\": {s},\n", .{if (report.openclaw_paths.source_exists) "true" else "false"});
    try stdout.writeAll("    \"detection_note\": ");
    try writeJsonString(stdout, report.openclaw_paths.detection_note);
    try stdout.writeAll(",\n");
    try openclaw_status.writePathsJsonHonesty(stdout);
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"hermes_paths\": {\n");
    try stdout.print("    \"repo_manifest_exists\": {s},\n", .{if (report.hermes_paths.repo_manifest_exists) "true" else "false"});
    try stdout.print("    \"repo_source_exists\": {s},\n", .{if (report.hermes_paths.repo_source_exists) "true" else "false"});
    try stdout.print("    \"user_manifest_exists\": {s},\n", .{if (report.hermes_paths.user_manifest_exists) "true" else "false"});
    try stdout.print("    \"user_source_exists\": {s},\n", .{if (report.hermes_paths.user_source_exists) "true" else "false"});
    try stdout.print("    \"config_references_plugin\": {s}\n", .{if (report.hermes_paths.config_references_plugin) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.writeAll("  \"hermes_hook_smoke_passed\": ");
    try stdout.writeAll(if (report.hermes_hook_smoke_passed) "true" else "false");
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"marketplace\": {\n");
    try stdout.print("    \"codex_marketplace\": {s},\n", .{if (report.marketplace.codex_marketplace) "true" else "false"});
    try stdout.print("    \"claude_marketplace\": {s},\n", .{if (report.marketplace.claude_marketplace) "true" else "false"});
    try stdout.print("    \"codex_plugin_manifest\": {s},\n", .{if (report.marketplace.codex_plugin_manifest) "true" else "false"});
    try stdout.print("    \"claude_plugin_manifest\": {s},\n", .{if (report.marketplace.claude_plugin_manifest) "true" else "false"});
    try stdout.print("    \"codex_user_plugin\": {s},\n", .{if (report.marketplace.codex_user_plugin) "true" else "false"});
    try stdout.print("    \"claude_user_plugin\": {s}\n", .{if (report.marketplace.claude_user_plugin) "true" else "false"});
    try stdout.writeAll("  },\n");

    try stdout.print("  \"platform_summary\": ", .{});
    try writeJsonString(stdout, report.platform_summary);
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"target\": ");
    try writeJsonString(stdout, @tagName(target));
    try stdout.writeAll(",\n");

    try stdout.writeAll("  \"warnings\": [\n");
    for (report.warnings, 0..) |w, i| {
        try stdout.writeAll("    ");
        try writeJsonString(stdout, w);
        if (i < report.warnings.len - 1) try stdout.writeAll(",");
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("  ]\n");

    try stdout.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------------

const ManifestTarget = enum { codex, claude, opencode, openclaw, hermes, all };

fn manifestCommand(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var target: ManifestTarget = .all;
    var json_mode = false;

    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(
                \\Usage:
                \\  ryk plugin manifest codex
                \\  ryk plugin manifest claude
                \\  ryk plugin manifest opencode
                \\  ryk plugin manifest openclaw
                \\  ryk plugin manifest hermes
                \\  ryk plugin manifest all
                \\  ryk plugin manifest <target> [--json]
                \\
            );
            return exit_codes.success;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "codex")) {
            target = .codex;
            continue;
        }
        if (std.mem.eql(u8, arg, "claude")) {
            target = .claude;
            continue;
        }
        if (std.mem.eql(u8, arg, "opencode")) {
            target = .opencode;
            continue;
        }
        if (std.mem.eql(u8, arg, "openclaw")) {
            target = .openclaw;
            continue;
        }
        if (std.mem.eql(u8, arg, "hermes") or std.mem.eql(u8, arg, "hermess")) {
            target = .hermes;
            continue;
        }
        if (std.mem.eql(u8, arg, "all")) {
            target = .all;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk plugin manifest", arg, &.{ "--json", "--help", "-h", "codex", "claude", "opencode", "openclaw", "hermes", "all" }, "plugin");
        return exit_codes.usage;
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const manifest_allocator = gpa_state.allocator();
    const workspace_root = try plugin_install.resolveWorkspaceInstallRoot(io, manifest_allocator);
    defer manifest_allocator.free(workspace_root);

    if (json_mode) {
        try writeManifestJson(io, manifest_allocator, workspace_root, stdout, target);
    } else {
        try writeManifestPlain(io, manifest_allocator, workspace_root, stdout, target);
    }
    return exit_codes.success;
}

fn writeManifestPlain(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, stdout: anytype, target: ManifestTarget) !void {
    const codex_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "plugins", "marketplace.json" });
    defer allocator.free(codex_marketplace_path);
    const claude_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".claude-plugin", "marketplace.json" });
    defer allocator.free(claude_marketplace_path);

    switch (target) {
        .codex => {
            const path = try resolveBundledPath(io, allocator, "integrations/codex-plugin/.codex-plugin/plugin.json");
            defer allocator.free(path);
            const marketplace_path = codex_marketplace_path;
            const marketplace_exists = fileExistsAbsolute(io, marketplace_path);
            try stdout.writeAll("Codex plugin manifest:\n");
            try stdout.print("  expected path: {s}\n", .{path});
            try stdout.print("  status: {s}\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.print("  marketplace: {s} ({s})\n", .{ marketplace_path, if (marketplace_exists) "exists" else "missing" });
            if (fileExistsAbsolute(io, path)) {
                try stdout.writeAll("  note: validation of manifest shape is deferred to host-specific checks\n");
            }
        },
        .claude => {
            const path = try resolveBundledPath(io, allocator, "integrations/claude-code-plugin/.claude-plugin/plugin.json");
            defer allocator.free(path);
            const marketplace_path = claude_marketplace_path;
            const marketplace_exists = fileExistsAbsolute(io, marketplace_path);
            try stdout.writeAll("Claude Code plugin manifest:\n");
            try stdout.print("  expected path: {s}\n", .{path});
            try stdout.print("  status: {s}\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.print("  marketplace: {s} ({s})\n", .{ marketplace_path, if (marketplace_exists) "exists" else "missing" });
            if (fileExistsAbsolute(io, path)) {
                try stdout.writeAll("  note: validation of manifest shape is deferred to host-specific checks\n");
            }
        },
        .opencode => {
            const path = try resolveBundledPath(io, allocator, "integrations/opencode-plugin/orca.ts");
            defer allocator.free(path);
            try stdout.writeAll("OpenCode plugin manifest:\n");
            try stdout.print("  expected path: {s}\n", .{path});
            try stdout.print("  status: {s}\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.writeAll("  note: OpenCode uses TypeScript plugins, not a JSON manifest\n");
        },
        .openclaw => {
            const manifest_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/openclaw.plugin.json");
            defer allocator.free(manifest_path);
            const pkg_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/package.json");
            defer allocator.free(pkg_path);
            try stdout.writeAll("OpenClaw plugin manifest:\n");
            try stdout.print("  expected manifest path: {s}\n", .{manifest_path});
            try stdout.print("  manifest status: {s}\n", .{if (fileExistsAbsolute(io, manifest_path)) "exists" else "missing"});
            try stdout.print("  package.json: {s} ({s})\n", .{ pkg_path, if (fileExistsAbsolute(io, pkg_path)) "exists" else "missing" });
            if (fileExistsAbsolute(io, manifest_path)) {
                try stdout.writeAll("  note: validation of manifest shape is deferred to host-specific checks\n");
            }
        },
        .hermes => {
            // Use resolveBundledPath so this works for both source trees and packaged installs
            // (where ORCA_RESOURCE_ROOT points at the installed runtime assets).
            const manifest_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/plugin.yaml");
            defer allocator.free(manifest_path);
            const source_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/__init__.py");
            defer allocator.free(source_path);
            const manifest_exists = fileExistsAbsolute(io, manifest_path);
            const source_exists = fileExistsAbsolute(io, source_path);
            try stdout.writeAll("Hermes plugin manifest:\n");
            try stdout.print("  expected manifest path: {s}\n", .{manifest_path});
            try stdout.print("  manifest status: {s}\n", .{if (manifest_exists) "exists" else "missing"});
            try stdout.print("  source: {s} ({s})\n", .{ source_path, if (source_exists) "exists" else "missing" });
            try stdout.writeAll("  user install path: ~/.hermes/plugins/orca/\n");
        },
        .all => {
            try stdout.writeAll("Plugin manifests:\n");
            // Bundled plugin manifests must go through resolveBundledPath for packaged installs.
            const codex_path = try resolveBundledPath(io, allocator, "integrations/codex-plugin/.codex-plugin/plugin.json");
            defer allocator.free(codex_path);
            const claude_path = try resolveBundledPath(io, allocator, "integrations/claude-code-plugin/.claude-plugin/plugin.json");
            defer allocator.free(claude_path);
            const opencode_path = try resolveBundledPath(io, allocator, "integrations/opencode-plugin/orca.ts");
            defer allocator.free(opencode_path);
            const openclaw_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/openclaw.plugin.json");
            defer allocator.free(openclaw_path);
            const hermes_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/plugin.yaml");
            defer allocator.free(hermes_path);
            try stdout.print("  codex:    {s} ({s})\n", .{ codex_path, if (fileExistsAbsolute(io, codex_path)) "exists" else "missing" });
            try stdout.print("  claude:   {s} ({s})\n", .{ claude_path, if (fileExistsAbsolute(io, claude_path)) "exists" else "missing" });
            try stdout.print("  opencode: {s} ({s})\n", .{ opencode_path, if (fileExistsAbsolute(io, opencode_path)) "exists" else "missing" });
            try stdout.print("  openclaw: {s} ({s})\n", .{ openclaw_path, if (fileExistsAbsolute(io, openclaw_path)) "exists" else "missing" });
            try stdout.print("  hermes:   {s} ({s})\n", .{ hermes_path, if (fileExistsAbsolute(io, hermes_path)) "exists" else "missing" });
            try stdout.writeAll("\nMarketplace files:\n");
            try stdout.print("  codex:    {s} ({s})\n", .{ codex_marketplace_path, if (fileExistsAbsolute(io, codex_marketplace_path)) "exists" else "missing" });
            try stdout.print("  claude:   {s} ({s})\n", .{ claude_marketplace_path, if (fileExistsAbsolute(io, claude_marketplace_path)) "exists" else "missing" });
        },
    }
}

fn writeManifestJson(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, stdout: anytype, target: ManifestTarget) !void {
    const codex_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "plugins", "marketplace.json" });
    defer allocator.free(codex_marketplace_path);
    const claude_marketplace_path = try std.fs.path.join(allocator, &.{ workspace_root, ".claude-plugin", "marketplace.json" });
    defer allocator.free(claude_marketplace_path);

    try stdout.writeAll("{\n");
    switch (target) {
        .codex => {
            // Use resolve (now robust) so JSON output is truthful for packaged installs
            // (matches the hermes case and the plain writer).
            const path = try resolveBundledPath(io, allocator, "integrations/codex-plugin/.codex-plugin/plugin.json");
            defer allocator.free(path);
            const marketplace_path = codex_marketplace_path;
            try stdout.writeAll("  \"codex\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.print("    \"marketplace_path\": ", .{});
            try writeJsonString(stdout, marketplace_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"marketplace_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, marketplace_path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
        .claude => {
            const path = try resolveBundledPath(io, allocator, "integrations/claude-code-plugin/.claude-plugin/plugin.json");
            defer allocator.free(path);
            const marketplace_path = claude_marketplace_path;
            try stdout.writeAll("  \"claude\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.print("    \"marketplace_path\": ", .{});
            try writeJsonString(stdout, marketplace_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"marketplace_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, marketplace_path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
        .opencode => {
            const path = try resolveBundledPath(io, allocator, "integrations/opencode-plugin/orca.ts");
            defer allocator.free(path);
            try stdout.writeAll("  \"opencode\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
        .openclaw => {
            const manifest_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/openclaw.plugin.json");
            defer allocator.free(manifest_path);
            const pkg_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/package.json");
            defer allocator.free(pkg_path);
            try stdout.writeAll("  \"openclaw\": {\n");
            try stdout.print("    \"manifest_path\": ", .{});
            try writeJsonString(stdout, manifest_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"manifest_status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, manifest_path)) "exists" else "missing"});
            try stdout.print("    \"package_path\": ", .{});
            try writeJsonString(stdout, pkg_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"package_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, pkg_path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
        .hermes => {
            // Use resolveBundledPath so --json output is truthful for packaged installs.
            const manifest_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/plugin.yaml");
            defer allocator.free(manifest_path);
            const source_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/__init__.py");
            defer allocator.free(source_path);
            try stdout.writeAll("  \"hermes\": {\n");
            try stdout.print("    \"manifest_path\": ", .{});
            try writeJsonString(stdout, manifest_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"manifest_status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, manifest_path)) "exists" else "missing"});
            try stdout.print("    \"source_path\": ", .{});
            try writeJsonString(stdout, source_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"source_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, source_path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
        .all => {
            // Bundled paths must resolve via ORCA_RESOURCE_ROOT for packaged installs.
            const codex_path = try resolveBundledPath(io, allocator, "integrations/codex-plugin/.codex-plugin/plugin.json");
            defer allocator.free(codex_path);
            const claude_path = try resolveBundledPath(io, allocator, "integrations/claude-code-plugin/.claude-plugin/plugin.json");
            defer allocator.free(claude_path);
            const opencode_path = try resolveBundledPath(io, allocator, "integrations/opencode-plugin/orca.ts");
            defer allocator.free(opencode_path);
            const openclaw_manifest_path = try resolveBundledPath(io, allocator, "integrations/openclaw-plugin/openclaw.plugin.json");
            defer allocator.free(openclaw_manifest_path);
            const hermes_manifest_path = try resolveBundledPath(io, allocator, "integrations/hermes-plugin/plugin.yaml");
            defer allocator.free(hermes_manifest_path);
            const codex_marketplace = codex_marketplace_path;
            const claude_marketplace = claude_marketplace_path;
            try stdout.writeAll("  \"codex\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, codex_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, codex_path)) "exists" else "missing"});
            try stdout.print("    \"marketplace_path\": ", .{});
            try writeJsonString(stdout, codex_marketplace);
            try stdout.writeAll(",\n");
            try stdout.print("    \"marketplace_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, codex_marketplace)) "exists" else "missing"});
            try stdout.writeAll("  },\n");
            try stdout.writeAll("  \"claude\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, claude_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\",\n", .{if (fileExistsAbsolute(io, claude_path)) "exists" else "missing"});
            try stdout.print("    \"marketplace_path\": ", .{});
            try writeJsonString(stdout, claude_marketplace);
            try stdout.writeAll(",\n");
            try stdout.print("    \"marketplace_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, claude_marketplace)) "exists" else "missing"});
            try stdout.writeAll("  },\n");
            try stdout.writeAll("  \"opencode\": {\n");
            try stdout.print("    \"path\": ", .{});
            try writeJsonString(stdout, opencode_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, opencode_path)) "exists" else "missing"});
            try stdout.writeAll("  },\n");
            try stdout.writeAll("  \"openclaw\": {\n");
            try stdout.print("    \"manifest_path\": ", .{});
            try writeJsonString(stdout, openclaw_manifest_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"manifest_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, openclaw_manifest_path)) "exists" else "missing"});
            try stdout.writeAll("  },\n");
            try stdout.writeAll("  \"hermes\": {\n");
            try stdout.print("    \"manifest_path\": ", .{});
            try writeJsonString(stdout, hermes_manifest_path);
            try stdout.writeAll(",\n");
            try stdout.print("    \"manifest_status\": \"{s}\"\n", .{if (fileExistsAbsolute(io, hermes_manifest_path)) "exists" else "missing"});
            try stdout.writeAll("  }\n");
        },
    }
    try stdout.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

const InstallTarget = enum { codex, claude, opencode, openclaw, hermes, all };
const InstallScope = enum { project, global };

fn installCommand(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var target: InstallTarget = .all;
    var target_explicit = false;
    var dry_run = true; // default to safe dry-run
    var dry_run_explicit = false;
    var custom_path: ?[]const u8 = null;
    var yes = false;
    var all_detected = false;
    var scope: InstallScope = .project;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(
                \\Usage:
                \\  ryk plugin install                     # dry-run preview of all hosts (no mutation)
                \\  ryk plugin install codex [--dry-run|--yes]
                \\  ryk plugin install claude [--dry-run|--yes]
                \\  ryk plugin install opencode [--dry-run|--yes]
                \\  ryk plugin install openclaw [--dry-run|--yes]
                \\  ryk plugin install hermes [--dry-run|--yes]
                \\  ryk plugin install all [--dry-run|--yes]
                \\  ryk plugin install all --all-detected [--dry-run|--yes]
                \\  ryk plugin install <target> --path <plugin-path> [--dry-run|--yes]
                \\  ryk plugin install opencode --scope project|global [--dry-run|--yes]
                \\
                \\Primary flow: `ryk start` (guided auto-select on TTY). For advanced installs: `ryk plugin install <host>`. Mutation requires an explicit host or `all` plus --yes (or interactive confirm default No).
                \\Options:
                \\  --dry-run       Preview changes without mutating host config
                \\  --all-detected  Only install for hosts found in PATH
                \\  --path          Use a custom plugin path instead of the default
                \\  --scope         OpenCode install scope: project|global (default: project)
                \\  --yes           Confirm mutation (required for non-TTY install)
                \\
            );
            return exit_codes.success;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            dry_run_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            if (!dry_run_explicit) dry_run = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all-detected")) {
            all_detected = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--path")) {
            if (index + 1 >= argv.len) {
                try stderr.writeAll("ryk plugin install: --path requires a value.\n");
                return exit_codes.usage;
            }
            custom_path = argv[index + 1];
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scope")) {
            if (index + 1 >= argv.len) {
                try stderr.writeAll("ryk plugin install: --scope requires a value.\n");
                return exit_codes.usage;
            }
            const value = argv[index + 1];
            if (std.mem.eql(u8, value, "project")) {
                scope = .project;
            } else if (std.mem.eql(u8, value, "global")) {
                scope = .global;
            } else {
                try suggestions.writeInvalidValue(stderr, "ryk plugin install", "--scope", value, &.{ "project", "global" }, "plugin");
                return exit_codes.usage;
            }
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "codex")) {
            target = .codex;
            target_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "claude")) {
            target = .claude;
            target_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "opencode")) {
            target = .opencode;
            target_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "openclaw")) {
            target = .openclaw;
            target_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "hermes") or std.mem.eql(u8, arg, "hermess")) {
            target = .hermes;
            target_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "all")) {
            target = .all;
            target_explicit = true;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk plugin install", arg, &.{ "--dry-run", "--yes", "--all-detected", "--path", "--scope", "--help", "-h", "codex", "claude", "opencode", "openclaw", "hermes", "all" }, "plugin");
        return exit_codes.usage;
    }

    // Bare install (no host / all): dry-run preview only — never mutate all hosts by default.
    if (!target_explicit) {
        if (yes and !dry_run_explicit) {
            try stderr.writeAll(
                "ryk plugin install: mutation requires an explicit host or `all` (e.g. `ryk plugin install codex --yes`).\n" ++
                    "Bare `ryk plugin install` is a dry-run preview only.\n",
            );
            return exit_codes.usage;
        }
        dry_run = true;
        target = .all;
    } else if (!dry_run_explicit and !yes) {
        const stdin = std.Io.File.stdin();
        if ((stdin.isTty(io) catch false)) {
            const host_label = if (target == .all and all_detected) "all detected" else if (target == .all) "all" else @tagName(target);
            var prompt_buf: [64]u8 = undefined;
            const prompt = std.fmt.bufPrint(&prompt_buf, "Install {s} plugin?", .{host_label}) catch "Install plugin?";
            // Canonical confirm: empty Enter = default No (cancel).
            const accepted = interactive.askConfirmInteractive(io, stdout, prompt, false) catch |err| {
                try stderr.print("ryk plugin install: confirmation failed: {s}\n", .{@errorName(err)});
                return exit_codes.general;
            };
            if (!accepted) {
                try stdout.writeAll("canceled\n");
                return exit_codes.success;
            }
            dry_run = false;
        } else {
            try stderr.writeAll("ryk plugin install: actual installation requires --yes or --dry-run to preview.\n");
            return exit_codes.usage;
        }
    }

    try stdout.writeAll("Orca Plugin Install\n\n");

    const workspace_root = try plugin_install.resolveWorkspaceInstallRoot(io, allocator);
    defer allocator.free(workspace_root);

    var smoke_deny_failed = false;
    var smoke_degraded = false;
    var detected_targets: [5]InstallTarget = undefined;
    var detected_count: usize = 0;

    const targets = switch (target) {
        .codex => &[_]InstallTarget{.codex},
        .claude => &[_]InstallTarget{.claude},
        .opencode => &[_]InstallTarget{.opencode},
        .openclaw => &[_]InstallTarget{.openclaw},
        .hermes => &[_]InstallTarget{.hermes},
        .all => if (all_detected) blk: {
            if (binaryInPath(io, allocator, "codex")) {
                detected_targets[detected_count] = .codex;
                detected_count += 1;
            }
            if (binaryInPath(io, allocator, "claude")) {
                detected_targets[detected_count] = .claude;
                detected_count += 1;
            }
            if (binaryInPath(io, allocator, "opencode")) {
                detected_targets[detected_count] = .opencode;
                detected_count += 1;
            }
            if (binaryInPath(io, allocator, "openclaw")) {
                detected_targets[detected_count] = .openclaw;
                detected_count += 1;
            }
            if (binaryInPath(io, allocator, "hermes")) {
                detected_targets[detected_count] = .hermes;
                detected_count += 1;
            }
            break :blk detected_targets[0..detected_count];
        } else &[_]InstallTarget{ .codex, .claude, .opencode, .openclaw, .hermes },
    };

    for (targets) |t| {
        try stdout.print("Target: {s}\n", .{@tagName(t)});
        try stdout.print("  mode: {s}\n", .{if (dry_run) "dry-run (no changes made)" else "install"});

        if (custom_path) |p| {
            try stdout.print("  custom path: {s}\n", .{p});
        }
        if (t == .opencode) {
            try stdout.print("  scope: {s}\n", .{@tagName(scope)});
        }

        const plugin_dir = if (custom_path) |path| try allocator.dupe(u8, path) else switch (t) {
            .codex => try resolveBundledPath(io, allocator, "integrations/codex-plugin"),
            .claude => try resolveBundledPath(io, allocator, "integrations/claude-code-plugin"),
            .opencode => try resolveBundledPath(io, allocator, "integrations/opencode-plugin"),
            .openclaw => try resolveBundledPath(io, allocator, "integrations/openclaw-plugin"),
            .hermes => try resolveBundledPath(io, allocator, "integrations/hermes-plugin"),
            .all => unreachable,
        };
        defer allocator.free(plugin_dir);

        if (!dirExists(plugin_dir)) {
            try stdout.print("  plugin directory: missing ({s})\n", .{plugin_dir});
            try stdout.writeAll("  next step: create the plugin directory and manifest before installing\n");
            if (!dry_run) return exit_codes.general;
        } else {
            try stdout.print("  plugin directory: found ({s})\n", .{plugin_dir});

            if (t == .opencode) {
                // OpenCode-specific install guidance
                const source_path = try std.fs.path.join(allocator, &.{ plugin_dir, "orca.ts" });
                defer allocator.free(source_path);
                const destination_path = try resolveOpenCodeDestination(allocator, workspace_root, scope);
                defer allocator.free(destination_path);

                try stdout.writeAll("  install paths for OpenCode:\n");
                try stdout.writeAll("    project: .opencode/plugins/orca.ts\n");
                try stdout.writeAll("    global:  ~/.config/opencode/plugins/orca.ts\n");
                if (dry_run) {
                    try stdout.writeAll("  action: no changes made (dry-run)\n");
                    try stdout.print("  next step: copy {s} to {s}\n", .{ source_path, destination_path });
                } else {
                    if (!fileExistsAbsolute(io, source_path)) {
                        try stdout.print("  action: failed (source missing: {s})\n", .{source_path});
                        return exit_codes.general;
                    }
                    const installed = installFileIfSafe(allocator, source_path, destination_path) catch |err| switch (err) {
                        error.RefusingToOverwriteDifferentFile => {
                            try stdout.print("  action: failed (destination exists and differs: {s})\n", .{destination_path});
                            return exit_codes.general;
                        },
                        else => return err,
                    };
                    if (installed) {
                        try stdout.print("  action: installed to {s}\n", .{destination_path});
                    } else {
                        try stdout.print("  action: already up-to-date at {s}\n", .{destination_path});
                    }
                }
            } else if (t == .openclaw) {
                // OpenClaw-specific install guidance
                const install_command = try std.fmt.allocPrint(allocator, "openclaw plugins install {s}", .{plugin_dir});
                defer allocator.free(install_command);
                try openclaw_status.writeInstallPaths(stdout);
                if (dry_run) {
                    try stdout.writeAll("  action: no changes made (dry-run)\n");
                    try stdout.print("  next step: run '{s}' if OpenClaw is installed\n", .{install_command});
                } else {
                    if (!binaryInPath(io, allocator, "openclaw")) {
                        try stdout.writeAll("  action: failed (openclaw binary not found in PATH)\n");
                        return exit_codes.general;
                    }
                    const status = try runOpenClawInstall(allocator, plugin_dir);
                    if (status == 0) {
                        try stdout.writeAll("  action: installed via openclaw host command\n");
                    } else {
                        try stdout.print("  action: failed (openclaw exit code: {d})\n", .{status});
                        return exit_codes.child_failure;
                    }
                }
            } else if (t == .hermes) {
                const destination_path = try hermesUserPluginRoot(allocator);
                defer allocator.free(destination_path);
                const manifest_source = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.yaml" });
                defer allocator.free(manifest_source);
                const source_source = try std.fs.path.join(allocator, &.{ plugin_dir, "__init__.py" });
                defer allocator.free(source_source);
                const manifest_destination = try std.fs.path.join(allocator, &.{ destination_path, "plugin.yaml" });
                defer allocator.free(manifest_destination);
                const source_destination = try std.fs.path.join(allocator, &.{ destination_path, "__init__.py" });
                defer allocator.free(source_destination);
                // Existing install: plugin source already present (hybrid L4 — do not silent-flip).
                const hermes_was_existing = fileExistsAbsolute(io, source_destination);

                try stdout.writeAll("  install paths for Hermes:\n");
                try stdout.print("    user: {s}\n", .{destination_path});
                try stdout.writeAll("    enable: hermes plugins enable orca\n");
                if (dry_run) {
                    try stdout.writeAll("  action: no changes made (dry-run)\n");
                    try stdout.print("  next step: copy {s} to {s}\n", .{ plugin_dir, destination_path });
                    if (!hermes_was_existing) {
                        try stdout.writeAll("  fail stance (new install): fail-closed via .orca_fail_stance\n");
                    }
                } else {
                    if (!fileExistsAbsolute(io, manifest_source) or !fileExistsAbsolute(io, source_source)) {
                        try stdout.writeAll("  action: failed (Hermes plugin files missing)\n");
                        return exit_codes.general;
                    }
                    const manifest_installed = installFileIfSafe(allocator, manifest_source, manifest_destination) catch |err| switch (err) {
                        error.RefusingToOverwriteDifferentFile => {
                            try stdout.print("  action: failed (destination exists and differs: {s})\n", .{manifest_destination});
                            return exit_codes.general;
                        },
                        else => return err,
                    };
                    const source_installed = installFileIfSafe(allocator, source_source, source_destination) catch |err| switch (err) {
                        error.RefusingToOverwriteDifferentFile => {
                            try stdout.print("  action: failed (destination exists and differs: {s})\n", .{source_destination});
                            return exit_codes.general;
                        },
                        else => return err,
                    };
                    if (manifest_installed or source_installed) {
                        try stdout.print("  action: installed to {s}\n", .{destination_path});
                    } else {
                        try stdout.print("  action: already up-to-date at {s}\n", .{destination_path});
                    }
                    // Hybrid L4: new installs get fail-closed stance file; existing keep prior stance/default.
                    if (!hermes_was_existing) {
                        try writeHermesFailClosedStance(allocator, destination_path);
                        try stdout.writeAll("  fail stance: fail-closed (new install default)\n");
                        try stdout.writeAll("    → Written: ~/.hermes/plugins/orca/.orca_fail_stance\n");
                        try stdout.writeAll("    → Override: export ORCA_HERMES_FAIL_OPEN=1  (or: ryk run -- hermes for process wrap)\n");
                    } else {
                        try stdout.writeAll("  fail stance: left unchanged (existing install; product default is fail-open unless env/stance set)\n");
                        try stdout.writeAll("    → Safer path: export ORCA_HERMES_FAIL_OPEN=0  # or: ryk run -- hermes\n");
                    }
                    if (binaryInPath(io, allocator, "hermes")) {
                        const status = try runHermesEnable(allocator);
                        if (status == 0) {
                            try stdout.writeAll("  enable: completed via hermes plugins enable orca\n");
                        } else {
                            try stdout.print("  enable: failed (hermes exit code: {d})\n", .{status});
                            try writeHermesEnableHelper(allocator, destination_path);
                        }
                    } else {
                        try stdout.writeAll("  enable: hermes binary not found in PATH\n");
                        try writeHermesEnableHelper(allocator, destination_path);
                    }
                }
            } else if (t == .codex or t == .claude) {
                const marketplace_host: plugin_install.MarketplaceHost = if (t == .codex) .codex else .claude;
                const template_rel = if (t == .codex)
                    "integrations/codex-plugin/examples/marketplace.json"
                else
                    "integrations/claude-code-plugin/examples/marketplace.json";
                const bundled_source = if (t == .codex)
                    "./integrations/codex-plugin"
                else
                    "./integrations/claude-code-plugin";
                const install_source = if (t == .codex) "./orca" else "../.claude/plugins/orca";
                const template_path = try resolveBundledPath(io, allocator, template_rel);
                defer allocator.free(template_path);
                const marketplace_json = try plugin_install.loadMarketplaceTemplate(
                    io,
                    allocator,
                    template_path,
                    bundled_source,
                    install_source,
                );
                defer allocator.free(marketplace_json);

                if (dry_run) {
                    const spec = try plugin_install.marketplaceHostInstallSpec(allocator, workspace_root, marketplace_host, marketplace_json);
                    defer {
                        allocator.free(spec.plugin_dest);
                        allocator.free(spec.marketplace_path);
                    }
                    try plugin_install.printMarketplaceHostInstallPlan(stdout, spec, plugin_dir);
                    try stdout.writeAll("  action: no changes made (dry-run)\n");
                } else if (t == .codex) {
                    plugin_install.installCodexPlugin(io, allocator, plugin_dir, workspace_root, marketplace_json, stdout) catch |err| switch (err) {
                        error.RefusingToOverwriteDifferentFile => {
                            try stdout.writeAll("  action: failed (destination exists and differs)\n");
                            return exit_codes.general;
                        },
                        else => return err,
                    };
                    try stdout.writeAll("  action: installed Codex plugin and marketplace registration\n");
                } else {
                    plugin_install.installClaudePlugin(io, allocator, plugin_dir, workspace_root, marketplace_json, stdout) catch |err| switch (err) {
                        error.RefusingToOverwriteDifferentFile => {
                            try stdout.writeAll("  action: failed (destination exists and differs)\n");
                            return exit_codes.general;
                        },
                        else => return err,
                    };
                    try stdout.writeAll("  action: installed Claude Code plugin and marketplace registration\n");
                }
            } else {
                if (dry_run) {
                    try stdout.writeAll("  action: no changes made (dry-run)\n");
                    try stdout.writeAll("  next step: host install command is not yet known; manual integration required\n");
                } else {
                    try stdout.writeAll("  action: failed (host plugin installation is not yet implemented)\n");
                    try stdout.writeAll("  note: use --dry-run for integration guidance until this host installer is implemented\n");
                    return exit_codes.unsupported;
                }
            }
        }

        // Safety notes (always printed)
        try stdout.writeAll("  safety: host config will not be silently overwritten\n");
        try stdout.writeAll("  safety: no credentials or telemetry will be stored\n");

        // P1 install smoke: safe allow + dangerous deny on the host veto path.
        if (!dry_run and t != .all) {
            const host_name = @tagName(t);
            try stdout.writeAll("  smoke:\n");
            const smoke = host_status.runHostSmokePair(allocator, host_name) catch host_status.HostSmokePair{ .allow = .fail, .deny = .fail };
            try host_status.writeHostSmokeReport(stdout, host_name, smoke);
            if (smoke.denyFailed()) {
                smoke_deny_failed = true;
            } else if (smoke.isDegraded()) {
                smoke_degraded = true;
            }
            if (t == .hermes and host_status.hermesFailOpenFromEnv()) {
                try stdout.writeAll("  warn: Hermes effective stance is fail-open — tools may run if Orca is degraded.\n");
                try stdout.writeAll("    → export ORCA_HERMES_FAIL_OPEN=0  # or: ryk run -- hermes\n");
            }
        }
    }

    // Pi is never managed by plugin install / install-all (honest non-management).
    if (!dry_run and (target == .all or all_detected)) {
        try stdout.writeAll("\nPi: not managed by `ryk plugin install`; extension coverage requires live smoke.\n");
        try stdout.writeAll("  Install: pi install npm:@orca-sec/pi-orca · process: ryk run -- pi\n");
        try stdout.writeAll("  Live check: ./scripts/host-live-e2e.sh pi\n");
    }

    try stdout.writeAll("\n");
    // Exit non-zero only when install claimed success but deny smoke failed.
    if (smoke_deny_failed) {
        try stdout.writeAll("Install completed but smoke deny failed — host is NOT protected.\n");
        try stdout.writeAll("Run: ryk plugin doctor <host>\n");
        return exit_codes.general;
    }
    if (smoke_degraded) {
        try stdout.writeAll("Install completed but smoke is DEGRADED (deny ok, allow failed).\n");
        try stdout.writeAll("Host is safe/fail-closed but NOT ready — fix daemon: orca doctor\n");
        // Exit 0: protection proof (deny) passed; yellow is messaging-only per L3.
    }
    return exit_codes.success;
}

// ---------------------------------------------------------------------------
// mcp-server
// ---------------------------------------------------------------------------

fn mcpServerCommand(_: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(
                \\Usage:
                \\  ryk plugin mcp-server [--help]
                \\
                \\Status: limited / deferred
                \\  The Orca MCP plugin server is planned but not yet active.
                \\  When implemented, it will expose safe read-only Orca capabilities as MCP tools:
                \\    - orca_doctor
                \\    - orca_plugin_doctor
                \\    - orca_policy_check
                \\    - orca_policy_explain
                \\    - orca_redteam
                \\    - orca_replay_summary
                \\    - orca_capabilities
                \\  The following will NOT be exposed by default:
                \\    - arbitrary shell execution
                \\    - arbitrary file writes
                \\    - raw audit log dumping without redaction
                \\    - credential access
                \\    - policy mutation without explicit approval
                \\
            );
            return exit_codes.success;
        }
        try suggestions.writeUnknownOption(stderr, "ryk plugin mcp-server", arg, &.{ "--help", "-h" }, "plugin");
        return exit_codes.usage;
    }

    try stdout.writeAll("Orca Plugin MCP Server\n\n");
    try stdout.writeAll("Status: limited / deferred\n");
    try stdout.writeAll("  The Orca MCP plugin server is planned but not yet active.\n");
    try stdout.writeAll("  It does not listen on any port or transport.\n\n");
    try stdout.writeAll("Planned safe tools (when implemented):\n");
    try stdout.writeAll("  - orca_doctor\n");
    try stdout.writeAll("  - orca_plugin_doctor\n");
    try stdout.writeAll("  - orca_policy_check\n");
    try stdout.writeAll("  - orca_policy_explain\n");
    try stdout.writeAll("  - orca_redteam\n");
    try stdout.writeAll("  - orca_replay_summary\n");
    try stdout.writeAll("  - orca_capabilities\n");
    try stdout.writeAll("\n");
    try stdout.writeAll("Blocked by default (not exposed):\n");
    try stdout.writeAll("  - arbitrary shell execution\n");
    try stdout.writeAll("  - arbitrary file writes\n");
    try stdout.writeAll("  - raw audit log dumping without redaction\n");
    try stdout.writeAll("  - credential access\n");
    try stdout.writeAll("  - policy mutation without explicit approval\n\n");
    try stdout.writeAll("Use 'ryk plugin mcp-server --help' for full details.\n");
    return exit_codes.success;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

pub fn fileExistsAbsolute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn pluginDirExists(io: std.Io, allocator: std.mem.Allocator, relative_path: []const u8) bool {
    const resolved = resolveBundledPath(io, allocator, relative_path) catch return false;
    defer allocator.free(resolved);
    return dirExists(resolved);
}

pub fn resolveBundledPath(io: std.Io, allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    // Delegate to the robust resolver used by redteam/doctor (workspace → ORCA_RESOURCE_ROOT
    // env → self-exe fallbacks including $PREFIX/share/orca/current). This fixes the
    // long-standing inconsistency where `plugin manifest` reported "missing" for hermes
    // (and peers) after a correct install even when the assets were present and doctor/redteam
    // worked. We preserve the old contract: on total failure we still return the relative
    // string so callers can print a sensible "expected path" + "missing" status.
    const workspace_root: [:0]u8 = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch try allocator.dupeZ(u8, ".");
    defer allocator.free(workspace_root);

    if (resource_root.resolveResourcePath(io, allocator, .{ .workspace_root = workspace_root }, relative_path)) |resolved| {
        return resolved;
    } else |err| switch (err) {
        error.ResourceNotFound => return allocator.dupe(u8, relative_path),
        else => return err,
    }
}

pub fn openClawPluginListedInJson(allocator: std.mem.Allocator, output: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch return false;
    defer parsed.deinit();
    return openClawPluginListed(parsed.value);
}

fn openClawPluginListed(value: std.json.Value) bool {
    switch (value) {
        .array => |items| {
            for (items.items) |item| {
                if (openClawPluginEntryMatches(item)) return true;
            }
            return false;
        },
        .object => |obj| {
            if (obj.get("plugins")) |plugins| return openClawPluginListed(plugins);
            if (obj.get("items")) |items| return openClawPluginListed(items);
            return openClawPluginEntryMatches(value);
        },
        else => return false,
    }
}

fn openClawPluginEntryMatches(value: std.json.Value) bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return false,
    };
    if (obj.get("id")) |id| {
        if (id == .string and std.mem.eql(u8, id.string, "orca")) return true;
    }
    if (obj.get("name")) |name| {
        if (name == .string and (std.mem.eql(u8, name.string, "orca") or std.mem.eql(u8, name.string, "orca-openclaw-plugin"))) return true;
    }
    if (obj.get("package")) |pkg| {
        if (pkg == .string and (std.mem.eql(u8, pkg.string, "orca") or std.mem.eql(u8, pkg.string, "orca-openclaw-plugin"))) return true;
    }
    return false;
}

pub fn detectOpenClawHostInstall(io: std.Io, allocator: std.mem.Allocator, openclaw_in_path: bool) !OpenClawHostInstall {
    var env_map = env_util.createProcessMap(allocator) catch {
        return .{
            .host_plugin_installed = false,
            .plugin_manifest_exists = false,
            .package_json_exists = false,
            .source_exists = false,
            .detection_note = "HOME not set; host install unknown",
        };
    };
    defer env_map.deinit();
    const home_owned = try env_util.getOwned(&env_map, allocator, "HOME");
    const home = home_owned orelse return .{
        .host_plugin_installed = false,
        .plugin_manifest_exists = false,
        .package_json_exists = false,
        .source_exists = false,
        .detection_note = "HOME not set; host install unknown",
    };
    defer allocator.free(home);

    const extension_root = try std.fs.path.join(allocator, &.{ home, ".openclaw", "extensions", "orca" });
    defer allocator.free(extension_root);
    const manifest_path = try std.fs.path.join(allocator, &.{ extension_root, "openclaw.plugin.json" });
    defer allocator.free(manifest_path);
    const package_json_path = try std.fs.path.join(allocator, &.{ extension_root, "package.json" });
    defer allocator.free(package_json_path);
    const source_path = try std.fs.path.join(allocator, &.{ extension_root, "src", "index.ts" });
    defer allocator.free(source_path);

    const manifest_exists = fileExistsAbsolute(io, manifest_path);
    const package_exists = fileExistsAbsolute(io, package_json_path);
    const source_exists = fileExistsAbsolute(io, source_path);
    var host_plugin_installed = manifest_exists or package_exists or source_exists;
    var detection_note: []const u8 = "checked host extension directory";

    if (!host_plugin_installed and openclaw_in_path) {
        const list_output = captureChildOutput(allocator, &.{ "openclaw", "plugins", "list", "--json" }) catch null;
        if (list_output) |output| {
            defer allocator.free(output);
            if (openClawPluginListedInJson(allocator, output)) {
                host_plugin_installed = true;
                detection_note = "checked openclaw plugins list";
            }
        }
    } else if (!openclaw_in_path) {
        detection_note = "openclaw binary not found in PATH";
    }

    return .{
        .host_plugin_installed = host_plugin_installed,
        .plugin_manifest_exists = manifest_exists,
        .package_json_exists = package_exists,
        .source_exists = source_exists,
        .detection_note = detection_note,
    };
}

pub fn captureChildOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const run_result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(0),
    });
    defer allocator.free(run_result.stderr);
    const term = run_result.term;
    if (term != .exited or term.exited != 0) return error.ChildFailed;
    return run_result.stdout;
}

pub fn hostPluginInstalledFromReport(host_name: []const u8, report: PluginDoctorReport) bool {
    if (std.mem.eql(u8, host_name, "hermes")) return report.hermes_paths.user_manifest_exists;
    if (std.mem.eql(u8, host_name, "openclaw")) return report.openclaw_paths.host_plugin_installed;
    if (std.mem.eql(u8, host_name, "opencode")) {
        return report.opencode_paths.project_plugin_exists or report.opencode_paths.global_plugin_exists;
    }
    if (std.mem.eql(u8, host_name, "codex")) return report.marketplace.codex_user_plugin;
    if (std.mem.eql(u8, host_name, "claude")) return report.marketplace.claude_user_plugin;
    return false;
}

pub const HostInstallOutcome = enum {
    installed,
    installed_after_child_failure,
    failed,
};

pub fn classifyHostInstallOutcome(child_exit_code: u8, installed_after: bool) HostInstallOutcome {
    if (!installed_after) return .failed;
    return if (child_exit_code == 0) .installed else .installed_after_child_failure;
}

pub fn verifyHostInstallAfterChild(
    io: std.Io,
    allocator: std.mem.Allocator,
    host_name: []const u8,
    child_exit_code: u8,
) HostInstallOutcome {
    var report = collectPluginDoctorReport(io, allocator) catch return .failed;
    defer deinitPluginDoctorReport(&report, allocator);
    return classifyHostInstallOutcome(child_exit_code, hostPluginInstalledFromReport(host_name, report));
}

pub fn hostPluginInstalledFromDoctorJson(host_name: []const u8, root: std.json.Value) bool {
    if (std.mem.eql(u8, host_name, "hermes")) {
        const paths = root.object.get("hermes_paths") orelse return false;
        return jsonBoolField(paths.object, "user_manifest_exists");
    }
    if (std.mem.eql(u8, host_name, "openclaw")) {
        const paths = root.object.get("openclaw_paths") orelse return false;
        return jsonBoolField(paths.object, "host_plugin_installed");
    }
    if (std.mem.eql(u8, host_name, "opencode")) {
        const paths = root.object.get("opencode_paths") orelse return false;
        return jsonBoolField(paths.object, "project_plugin_exists") or
            jsonBoolField(paths.object, "global_plugin_exists");
    }
    if (std.mem.eql(u8, host_name, "codex")) {
        const marketplace = root.object.get("marketplace") orelse return false;
        return jsonBoolField(marketplace.object, "codex_user_plugin");
    }
    if (std.mem.eql(u8, host_name, "claude")) {
        const marketplace = root.object.get("marketplace") orelse return false;
        return jsonBoolField(marketplace.object, "claude_user_plugin");
    }
    return false;
}

fn jsonBoolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |enabled| enabled,
        else => false,
    };
}

pub fn resolveOpenCodeDestination(allocator: std.mem.Allocator, workspace_root: []const u8, scope: InstallScope) ![]u8 {
    return switch (scope) {
        .project => std.fs.path.join(allocator, &.{ workspace_root, ".opencode", "plugins", "orca.ts" }),
        .global => blk: {
            var env_map = env_util.createProcessMap(allocator) catch return std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
            defer env_map.deinit();
            const home = env_util.getOwned(&env_map, allocator, "HOME") catch return std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
            const home_owned = home orelse return std.fs.path.join(allocator, &.{ "~", ".config", "opencode", "plugins", "orca.ts" });
            defer allocator.free(home_owned);
            break :blk std.fs.path.join(allocator, &.{ home_owned, ".config", "opencode", "plugins", "orca.ts" });
        },
    };
}

pub fn hermesUserPluginRoot(allocator: std.mem.Allocator) ![]u8 {
    var env_map = env_util.createProcessMap(allocator) catch return std.fs.path.join(allocator, &.{ "~", ".hermes", "plugins", "orca" });
    defer env_map.deinit();
    const home = env_util.getOwned(&env_map, allocator, "HOME") catch return std.fs.path.join(allocator, &.{ "~", ".hermes", "plugins", "orca" });
    const home_owned = home orelse return std.fs.path.join(allocator, &.{ "~", ".hermes", "plugins", "orca" });
    defer allocator.free(home_owned);
    return std.fs.path.join(allocator, &.{ home_owned, ".hermes", "plugins", "orca" });
}

pub fn hermesConfigPath(allocator: std.mem.Allocator) ![]u8 {
    var env_map = env_util.createProcessMap(allocator) catch return std.fs.path.join(allocator, &.{ "~", ".hermes", "config.yaml" });
    defer env_map.deinit();
    const home = env_util.getOwned(&env_map, allocator, "HOME") catch return std.fs.path.join(allocator, &.{ "~", ".hermes", "config.yaml" });
    const home_owned = home orelse return std.fs.path.join(allocator, &.{ "~", ".hermes", "config.yaml" });
    defer allocator.free(home_owned);
    return std.fs.path.join(allocator, &.{ home_owned, ".hermes", "config.yaml" });
}

pub fn installFileIfSafe(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    if (fileExistsAbsolute(io, destination_path)) {
        const same = try filesEqual(allocator, source_path, destination_path);
        if (same) return false;
        return error.RefusingToOverwriteDifferentFile;
    }

    const parent = std.fs.path.dirname(destination_path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);
    const dest_file = try std.Io.Dir.cwd().createFile(io, destination_path, .{ .exclusive = true });
    defer dest_file.close(io);
    try dest_file.writeStreamingAll(io, source);
    try dest_file.sync(io);
    return true;
}

pub fn filesEqual(allocator: std.mem.Allocator, lhs_path: []const u8, rhs_path: []const u8) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const lhs = try std.Io.Dir.cwd().readFileAlloc(io, lhs_path, allocator, .limited(1024 * 1024));
    defer allocator.free(lhs);
    const rhs = try std.Io.Dir.cwd().readFileAlloc(io, rhs_path, allocator, .limited(1024 * 1024));
    defer allocator.free(rhs);
    return std.mem.eql(u8, lhs, rhs);
}

pub fn runOpenClawInstall(allocator: std.mem.Allocator, plugin_dir: []const u8) !u8 {
    const argv = [_][]const u8{ "openclaw", "plugins", "install", plugin_dir };
    const result = try child_process.runHostCommandTimed(allocator, &argv, 10_000, null, null);
    defer child_process.deinitHostCommandResult(result, allocator);
    return if (result.timed_out) 255 else result.exit_code;
}

pub fn runHermesEnable(allocator: std.mem.Allocator) !u8 {
    const argv = [_][]const u8{ "hermes", "plugins", "enable", "orca" };
    const result = try child_process.runHostCommandTimed(allocator, &argv, 10_000, null, null);
    defer child_process.deinitHostCommandResult(result, allocator);
    return if (result.timed_out) 255 else result.exit_code;
}

pub fn fileContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, needle) != null;
}

pub fn dirExists(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    return true;
}

pub fn hasPath(root: []const u8, relative: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.heap.page_allocator;
    const path = std.fs.path.join(allocator, &.{ root, relative }) catch return false;
    defer allocator.free(path);
    return fileExistsAbsolute(io, path);
}

/// Walk a pre-resolved PATH string for `binary_name` (and `.exe` on Windows).
pub fn binaryOnSearchPath(io: std.Io, allocator: std.mem.Allocator, path_value: []const u8, binary_name: []const u8) bool {
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

pub fn binaryInPath(io: std.Io, allocator: std.mem.Allocator, binary_name: []const u8) bool {
    var env_map = env_util.createProcessMap(allocator) catch return false;
    defer env_map.deinit();
    const path_owned = env_util.getOwned(&env_map, allocator, "PATH") catch return false;
    const path_value = path_owned orelse return false;
    defer allocator.free(path_value);
    return binaryOnSearchPath(io, allocator, path_value, binary_name);
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

pub const SmokeResult = struct {
    passed: bool,
};

pub fn smokeTestHook(allocator: std.mem.Allocator, host: []const u8, event: []const u8, fixture_path: []const u8, expected_decision: []const u8) !SmokeResult {
    // Pipe spawn needs Threaded Io (single-threaded reports OOM).
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    const argv = &[_][]const u8{ self_exe, "hook", host, event };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const fixture = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .limited(256 * 1024));
    defer allocator.free(fixture);
    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(io, fixture);
        stdin.close(io);
        child.stdin = null;
    }

    const stdout = if (child.stdout) |out| blk: {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var buf: [4096]u8 = undefined;
        var reader = out.reader(io, &buf);
        while (list.items.len < 256 * 1024) {
            const n = reader.interface.readSliceShort(buf[0..@min(buf.len, 256 * 1024 - list.items.len)]) catch break;
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
        break :blk try list.toOwnedSlice(allocator);
    } else try allocator.dupe(u8, "");
    defer allocator.free(stdout);
    const term = try child.wait(io);
    const exit_code: u8 = if (term == .exited) term.exited else 255;
    const passed = host_status.interpretSmokeOutcome(host, expected_decision, exit_code, stdout, "");
    return .{ .passed = passed };
}

// ---------------------------------------------------------------------------
// Hermes enable helper
// ---------------------------------------------------------------------------

fn writeHermesEnableHelper(allocator: std.mem.Allocator, plugin_dir: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    // Guard: hermesUserPluginRoot can return a path with literal ~ if HOME is unset
    const resolved_dir = if (std.mem.startsWith(u8, plugin_dir, "~/")) blk: {
        var env_map = env_util.createProcessMap(allocator) catch return;
        defer env_map.deinit();
        const home = env_util.getOwned(&env_map, allocator, "HOME") catch return;
        const home_owned = home orelse return;
        defer allocator.free(home_owned);
        break :blk try std.fs.path.join(allocator, &.{ home_owned, plugin_dir[2..] });
    } else try allocator.dupe(u8, plugin_dir);
    defer allocator.free(resolved_dir);

    const help_path = try std.fs.path.join(allocator, &.{ resolved_dir, "ENABLE.txt" });
    defer allocator.free(help_path);
    if (std.fs.path.dirname(help_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    const file = try std.Io.Dir.cwd().createFile(io, help_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "Orca plugin files are installed.\nTo enable, run:\n  hermes plugins enable orca\n");
    try file.sync(io);
}

/// New Hermes installs: write fail-closed stance next to the plugin (hybrid L4).
/// Env `ORCA_HERMES_FAIL_OPEN` always overrides this file at runtime.
fn writeHermesFailClosedStance(allocator: std.mem.Allocator, plugin_dir: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const resolved_dir = if (std.mem.startsWith(u8, plugin_dir, "~/")) blk: {
        var env_map = env_util.createProcessMap(allocator) catch return;
        defer env_map.deinit();
        const home = env_util.getOwned(&env_map, allocator, "HOME") catch return;
        const home_owned = home orelse return;
        defer allocator.free(home_owned);
        break :blk try std.fs.path.join(allocator, &.{ home_owned, plugin_dir[2..] });
    } else try allocator.dupe(u8, plugin_dir);
    defer allocator.free(resolved_dir);

    const stance_path = try std.fs.path.join(allocator, &.{ resolved_dir, host_status.hermes_fail_stance_filename });
    defer allocator.free(stance_path);
    if (std.fs.path.dirname(stance_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    const file = try std.Io.Dir.cwd().createFile(io, stance_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io,
        \\fail-closed
        \\# Written by `ryk plugin install hermes` for new installs.
        \\# Env ORCA_HERMES_FAIL_OPEN overrides this file (0=fail-closed, 1=fail-open).
        \\# Easy full protection: ryk run -- hermes
        \\
    );
    try file.sync(io);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "plugin command help and invalid subcommands are stable" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const help_code = try command(std.testing.io, &.{"--help"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "plugin") != null);

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const bad_code = try command(std.testing.io, &.{"unknown"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, bad_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "unknown subcommand") != null);
}

test "plugin doctor prints expected sections" {
    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Orca Plugin Doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Orca version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SMOKE ALLOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk run -- pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pi …") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plugin directories:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host binaries:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Drone workstream:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Platform:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "host install outcome trusts refreshed doctor state over child exit" {
    try std.testing.expectEqual(HostInstallOutcome.installed, classifyHostInstallOutcome(0, true));
    try std.testing.expectEqual(HostInstallOutcome.installed_after_child_failure, classifyHostInstallOutcome(17, true));
    try std.testing.expectEqual(HostInstallOutcome.failed, classifyHostInstallOutcome(0, false));
    try std.testing.expectEqual(HostInstallOutcome.failed, classifyHostInstallOutcome(17, false));
}

/// Owned-field graph that mirrors `PluginDoctorReport` ownership (cwd, paths,
/// warnings, binary path, policy_error) without full FS/PATH/doctor discovery.
///
/// Full `collectPluginDoctorReportWithHermesSmoke` must **not** be wrapped in
/// `checkAllAllocationFailures`: that re-runs PATH/env/FS work once per alloc
/// site and freezes `test-lib` for minutes with no progress output (false hang).
fn pluginDoctorReportOwnedFieldsHarness(allocator: std.mem.Allocator) !void {
    const cwd = try allocator.dupeZ(u8, ".");
    errdefer allocator.free(cwd);
    const workspace_root = try allocator.dupe(u8, ".");
    errdefer allocator.free(workspace_root);
    const mcp_support_status = try allocator.dupe(u8, "stdio proxy active; HTTP transport deferred");
    errdefer allocator.free(mcp_support_status);
    const platform_summary = try allocator.dupe(u8, "test-os / none / none");
    errdefer allocator.free(platform_summary);
    const policy_error = try allocator.dupe(u8, "sample-policy-error");
    errdefer allocator.free(policy_error);
    const binary_path = try allocator.dupeZ(u8, "/tmp/orca-test-bin");
    errdefer allocator.free(binary_path);

    var warnings: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (warnings.items) |w| allocator.free(w);
        warnings.deinit(allocator);
    }
    try appendWarning(allocator, &warnings, "first warning");
    try appendWarning(allocator, &warnings, "second warning");
    const warning_items = try warnings.toOwnedSlice(allocator);

    var report: PluginDoctorReport = .{
        .orca_version = "test",
        .orca_binary_path = binary_path,
        .cwd = cwd,
        .workspace_root = workspace_root,
        .policy_present = true,
        .policy_valid = false,
        .policy_error = policy_error,
        .audit_replay_available = false,
        .mcp_support_status = mcp_support_status,
        .plugin_directories = .{ .codex = true, .claude = true, .opencode = true, .openclaw = true, .hermes = true, .common = true },
        .host_binaries = .{ .codex = false, .claude = false, .opencode = false, .openclaw = false, .hermes = false },
        .opencode_paths = .{ .project_plugin_exists = false, .global_plugin_exists = false, .config_references_plugin = false },
        .openclaw_paths = .{
            .host_plugin_installed = false,
            .plugin_manifest_exists = false,
            .package_json_exists = false,
            .source_exists = false,
            .detection_note = "test",
        },
        .hermes_paths = .{
            .repo_manifest_exists = false,
            .repo_source_exists = false,
            .user_manifest_exists = false,
            .user_source_exists = false,
            .config_references_plugin = false,
        },
        .hermes_hook_smoke_passed = true,
        .marketplace = .{
            .codex_marketplace = false,
            .claude_marketplace = false,
            .codex_plugin_manifest = true,
            .claude_plugin_manifest = true,
            .codex_user_plugin = false,
            .claude_user_plugin = false,
        },
        .platform_summary = platform_summary,
        .warnings = warning_items,
    };
    defer deinitPluginDoctorReport(&report, allocator);
}

test "plugin doctor report cleans up allocation failure paths" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pluginDoctorReportOwnedFieldsHarness, .{});
}

test "binaryOnSearchPath finds names on a synthetic PATH" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    // Empty dir → miss.
    try std.testing.expect(!binaryOnSearchPath(io, allocator, dir_path, "orca-not-present-xyz"));

    // Create a file that looks like a binary entry.
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-host-bin", .data = "x" });
    try std.testing.expect(binaryOnSearchPath(io, allocator, dir_path, "fake-host-bin"));
}

test "plugin doctor --json emits valid JSON" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"--json"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const json = stdout_writer.buffered();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("orca_version") != null);
    try std.testing.expect(parsed.value.object.get("policy") != null);
    try std.testing.expect(parsed.value.object.get("plugin_directories") != null);
    try std.testing.expect(parsed.value.object.get("host_binaries") != null);
    try std.testing.expect(parsed.value.object.get("hermes_paths") != null);
    try std.testing.expect(parsed.value.object.get("hermes_hook_smoke_passed") != null);
    try std.testing.expect(parsed.value.object.get("hermes_hook_smoke_passed").? == .bool);
    try std.testing.expect(parsed.value.object.get("drone") == null);
    try std.testing.expect(parsed.value.object.get("warnings") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Orca Plugin Doctor") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor plain output does not expose Edge or drone workstream state" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Drone workstream") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "live control") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor codex shows codex-specific section" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"codex"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Codex plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host binary:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor claude shows claude-specific section" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"claude"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Claude Code plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host binary:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor opencode shows opencode-specific section" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"opencode"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "OpenCode plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host binary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "project plugin path") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "global plugin path") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor openclaw shows openclaw-specific section" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"openclaw"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "OpenClaw plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host binary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "package.json") != null);
    // Invariant tokens (not full marketing slogans).
    try std.testing.expect(std.mem.indexOf(u8, output, "unprotected") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, openclaw_status.preferred_wrapper) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "installed != protected") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor openclaw --json includes enforcement_note and hook_grade unverified" {
    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{ "openclaw", "--json" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"enforcement_note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unprotected") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hook_grade\": \"unverified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"npm_path\": \"unprotected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hook_enforcing") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor hermes shows hermes-specific section" {
    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"hermes"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Hermes plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "repo plugin.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "~/.hermes/plugins/orca/plugin.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hook smoke test (pre_tool_call allow):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fail stance:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Host status:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor does not print raw env values or secrets" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"--json"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    // Should not contain any obviously secret-looking values
    try std.testing.expect(std.mem.indexOf(u8, output, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sk-") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "secret") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest codex reports expected path" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"codex"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/codex-plugin/.codex-plugin/plugin.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "exists") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest claude reports expected path" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"claude"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/claude-code-plugin/.claude-plugin/plugin.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "exists") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest opencode reports expected path" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"opencode"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/opencode-plugin/orca.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "OpenCode uses TypeScript plugins") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest openclaw reports expected paths" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"openclaw"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/openclaw-plugin/openclaw.plugin.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "package.json") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest hermes reports expected paths" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"hermes"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/hermes-plugin/plugin.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "integrations/hermes-plugin/__init__.py") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest all reports all five" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"all"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "codex:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "claude:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "opencode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "openclaw:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hermes:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest --json emits valid JSON" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{ "all", "--json" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const json = stdout_writer.buffered();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("codex") != null);
    try std.testing.expect(parsed.value.object.get("claude") != null);
    try std.testing.expect(parsed.value.object.get("opencode") != null);
    try std.testing.expect(parsed.value.object.get("openclaw") != null);
    try std.testing.expect(parsed.value.object.get("hermes") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Orca Plugin") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install codex --dry-run reports safe preview" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "codex", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no changes made") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "safety:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install claude --dry-run reports safe preview" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "claude", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no changes made") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install opencode --dry-run reports safe preview with paths" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "opencode", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no changes made") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".opencode/plugins/orca.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "~/.config/opencode/plugins/orca.ts") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install openclaw --dry-run reports safe preview" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "openclaw", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no changes made") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: openclaw") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install hermes --dry-run reports safe preview" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "hermes", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: hermes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".hermes/plugins/orca") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install all --dry-run reports all five targets" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "all", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: opencode") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: openclaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target: hermes") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install without --yes or --dry-run in non-TTY returns usage" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{"codex"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);

    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--yes or --dry-run") != null);
}

test "plugin install bare does not mutate (dry-run preview of all)" {
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no changes made") != null or std.mem.indexOf(u8, output, "mode: dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: install") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install bare --yes without host fails closed" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{"--yes"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "explicit host") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "mode: install") == null);
}

test "plugin install all without --yes in non-TTY fails" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{"all"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--yes or --dry-run") != null);
}

test "plugin install --yes switches out of dry-run when dry-run is not explicit" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "codex", "--path", "does-not-exist-orca-test-plugin", "--yes" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: install") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin directory: missing") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install codex --yes installs plugin and marketplace" {
    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "codex", "--yes" }, &stdout_writer, &stderr_writer);
    // Success if install completed; non-zero only when smoke *deny* fails (not when not-run under zig test).
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: install") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "installed Codex plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke deny:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "not yet implemented") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install claude --yes installs plugin and marketplace" {
    var stdout_buf: [32768]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "claude", "--yes" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: install") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "installed Claude Code plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "smoke deny:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "interpretSmokeOutcome codex deny vs flexible host is covered by host_status" {
    // Anchors the install-smoke policy: codex deny is exit-code based.
    try std.testing.expect(host_status.interpretSmokeOutcome("codex", "block", 2, "", ""));
    try std.testing.expect(host_status.interpretSmokeOutcome("claude", "block", 0, "{\"decision\":\"block\"}", ""));
}

test "plugin install explicit dry-run wins over --yes" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "codex", "--yes", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: dry-run") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin install rejects invalid scope" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "opencode", "--scope", "workspace" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "invalid --scope value") != null);
}

test "plugin install opencode --scope global is accepted in dry-run" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try installCommand(std.testing.io, &.{ "opencode", "--scope", "global", "--dry-run" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "scope: global") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin mcp-server reports limited status honestly" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try mcpServerCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "deferred") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "not yet active") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "orca_doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_safety_status") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "live drone") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin mcp-server does not claim to expose drone actuation" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try mcpServerCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "live drone actuation") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MCP server is active") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor reports marketplace status" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Marketplace files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".agents/plugins/marketplace.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".claude-plugin/marketplace.json") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor codex reports marketplace and manifest status" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"codex"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Codex plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "marketplace file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin manifest:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin doctor claude reports marketplace and manifest status" {
    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try doctorCommand(std.testing.io, &.{"claude"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Claude Code plugin status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "marketplace file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plugin manifest:") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest codex reports marketplace path" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"codex"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ".agents/plugins/marketplace.json") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest claude reports marketplace path" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"claude"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ".claude-plugin/marketplace.json") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "plugin manifest all reports marketplace files" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try manifestCommand(std.testing.io, &.{"all"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Marketplace files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".agents/plugins/marketplace.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ".claude-plugin/marketplace.json") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

fn pluginListTestReport() PluginDoctorReport {
    return .{
        .orca_version = "test",
        .orca_binary_path = null,
        .cwd = @constCast("."),
        .workspace_root = ".",
        .policy_present = false,
        .policy_valid = false,
        .policy_error = null,
        .audit_replay_available = false,
        .mcp_support_status = "",
        .plugin_directories = .{ .codex = true, .claude = true, .opencode = true, .openclaw = true, .hermes = true, .common = true },
        .host_binaries = .{ .codex = false, .claude = false, .opencode = false, .openclaw = false, .hermes = false },
        .opencode_paths = .{ .project_plugin_exists = false, .global_plugin_exists = false, .config_references_plugin = false },
        .openclaw_paths = .{ .host_plugin_installed = false, .plugin_manifest_exists = false, .package_json_exists = false, .source_exists = false, .detection_note = "" },
        .hermes_paths = .{ .repo_manifest_exists = false, .repo_source_exists = false, .user_manifest_exists = false, .user_source_exists = false, .config_references_plugin = false },
        .hermes_hook_smoke_passed = false,
        .marketplace = .{ .codex_marketplace = false, .claude_marketplace = false, .codex_plugin_manifest = true, .claude_plugin_manifest = true, .codex_user_plugin = false, .claude_user_plugin = false },
        .platform_summary = "",
        .warnings = &.{},
    };
}

fn pluginListAllocationFailureHarness(allocator: std.mem.Allocator) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writePluginList(std.testing.io, allocator, &writer, pluginListTestReport());
}

test "plugin list cleans up allocation failure paths" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pluginListAllocationFailureHarness, .{});
}

test "plugin list renders deterministic host inventory and empty guidance" {
    const report = pluginListTestReport();
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writePluginList(std.testing.io, std.testing.allocator, &writer, report);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "HOST") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Codex").? < std.mem.indexOf(u8, output, "Claude Code").?);
    try std.testing.expect(std.mem.indexOf(u8, output, "Claude Code").? < std.mem.indexOf(u8, output, "OpenCode").?);
    try std.testing.expect(std.mem.indexOf(u8, output, "No supported host CLIs detected") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk plugin codex --dry-run") != null);
}

test "friendly plugin host alias preserves install dry-run output" {
    var alias_stdout_buf: [8192]u8 = undefined;
    var alias_stderr_buf: [256]u8 = undefined;
    var direct_stdout_buf: [8192]u8 = undefined;
    var direct_stderr_buf: [256]u8 = undefined;
    var alias_stdout: std.Io.Writer = .fixed(&alias_stdout_buf);
    var alias_stderr: std.Io.Writer = .fixed(&alias_stderr_buf);
    var direct_stdout: std.Io.Writer = .fixed(&direct_stdout_buf);
    var direct_stderr: std.Io.Writer = .fixed(&direct_stderr_buf);

    const alias_code = try command(std.testing.io, &.{ "codex", "--dry-run" }, &alias_stdout, &alias_stderr);
    const direct_code = try installCommand(std.testing.io, &.{ "codex", "--dry-run" }, &direct_stdout, &direct_stderr);

    try std.testing.expectEqual(direct_code, alias_code);
    try std.testing.expectEqualStrings(direct_stdout.buffered(), alias_stdout.buffered());
    try std.testing.expectEqualStrings(direct_stderr.buffered(), alias_stderr.buffered());
}
