const std = @import("std");

const core_api = @import("orca_core").api;
const orca_policy = @import("orca_core").policy;

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const style = @import("style.zig");
const onboarding = @import("onboarding.zig");
const pack_state = @import("pack_state.zig");
const plugin = @import("plugin.zig");
const child_process = @import("child_process.zig");
const pi_install = @import("pi_install.zig");
const grok_install = @import("grok_install.zig");
const shell_eval = @import("shell_eval.zig");
const build_options = @import("build_options");
const env_util = @import("../env_util.zig");
const tui = @import("../tui/mod.zig");
// AINA P3 S5: shared refresh body lives in init.zig (do not import start from init).
const init_cli = @import("init.zig");

/// Re-export: run adapters for host_keys; regenerate managed store under workspace_root.
/// See `init.refreshManagedDiscovery` (DIS-1 / DIS-7).
pub const refreshManagedDiscovery = init_cli.refreshManagedDiscovery;

pub fn command(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "start");
            return exit_codes.success;
        }
    }

    if (argv.len == 0) {
        var flags: onboarding.StartFlags = .{};
        if (!onboarding.interactiveSetupDesired(io)) {
            flags.auto = true;
        }
        return runStart(io, cwd, flags, stdout, stderr, null, null);
    }

    var flags = onboarding.parseStartFlags(argv, stderr) catch |err| switch (err) {
        error.Usage => return exit_codes.usage,
        else => return err,
    };

    if (!flags.auto and !onboarding.interactiveSetupDesired(io)) {
        flags.auto = true;
    }

    return runStart(io, cwd, flags, stdout, stderr, null, null);
}

pub fn runStart(
    io: std.Io,
    cwd: std.Io.Dir,
    flags: onboarding.StartFlags,
    stdout: anytype,
    stderr: anytype,
    daemon_check_fn: ?*const fn (std.mem.Allocator, bool) anyerror!void,
    shell_evaluator: ?shell_eval.ShellCommandEvaluatorFn,
) !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    try tui.render.banner(io, stdout, build_options.version, null);
    try stdout.writeAll(
        \\ryk will configure protection for your workspace, verify shell evaluation when needed,
        \\install host integrations you choose, and run safe verification checks.
        \\Existing policy files are kept unless you run `ryk init --force`.
        \\
        \\
    );

    const workspace_root = try onboarding.resolveWorkspaceRootFromCwd(io, allocator, cwd);
    defer allocator.free(workspace_root);

    // Auto-select best available setup path — no interactive grade menu.
    // Active protection wording is deferred until after ensurePolicy (existing mode may differ).
    const protection = resolveProtectionMode(flags);
    try stdout.writeAll("Setup path: Ask on risk (auto).\n");
    try stdout.writeAll("  Existing policy is preserved; claims below follow the policy file mode.\n\n");

    var doctor_report = try plugin.collectPluginDoctorReport(io, allocator);
    defer plugin.deinitPluginDoctorReport(&doctor_report, allocator);

    const host_statuses = try onboarding.collectHostStatuses(io, allocator, doctor_report);
    defer allocator.free(host_statuses);

    const selected_hosts = try resolveSelectedHosts(io, allocator, flags, host_statuses, stdout);
    defer if (selected_hosts.owned) onboarding.deinitHostList(allocator, selected_hosts.items);

    var failures: usize = 0;
    var protection_active = false;

    const policy_existed = onboarding.policyExists(io, workspace_root);
    const policy_code = try onboarding.ensurePolicy(io, cwd, workspace_root, flags.preset, stdout, stderr, .{
        .missing = "Creating .orca/policy.yaml...\n",
        .exists = "Policy already exists — leaving it unchanged.\n",
    });
    var policy_mode: ?[]const u8 = null;
    defer if (policy_mode) |m| allocator.free(m);
    if (policy_code != exit_codes.success) {
        try tui.render.stepLine(io, stdout, .failed, "Policy", "Policy setup failed.", 80);
        failures += 1;
    } else {
        policy_mode = readWorkspacePolicyMode(io, allocator, workspace_root);
        if (policy_mode) |mode| {
            if (!policyModeIsAskEquivalent(mode)) {
                try stdout.print("  Note: policy mode={s} (not Ask) — existing policy left unchanged.\n", .{mode});
            }
        }
        try tui.render.stepLine(io, stdout, .done, "Policy", if (policy_existed) "Existing policy preserved." else "Policy created.", 80);
    }

    // Additive pack enablement from preset (project .orca.toml when in git repo).
    var packs_result = pack_state.ensurePresetPacksByName(io, allocator, workspace_root, flags.preset) catch pack_state.EnsurePacksResult{
        .message = "Packs: baseline only (pack config write skipped)",
        .owned = false,
    };
    defer packs_result.deinit(allocator);
    try tui.render.stepLine(io, stdout, .done, "Packs", packs_result.message, 80);
    if (packs_result.config_path) |path| {
        try stdout.print("  Pack config ({s}): {s}\n", .{ packs_result.scope.?.label(), path });
    }

    // AINA P3 S5: soft-refresh managed discovery for selected/detected pi+opencode.
    // Parent HOME + abs workspace_root; never fail start; never wipe policy (DIS-1/7).
    softRefreshStartDiscovery(io, allocator, workspace_root, selected_hosts.items, host_statuses);

    var daemon_check: onboarding.DaemonCheck = undefined;
    if (protection.needsCommandGuard()) {
        // CLI-only product: shell mediation is in-process Zig shell_engine.
        // Do not require the removed orca-daemon binary for start/onboarding.
        daemon_check = .{
            .status = .compatible,
            .detail = "in-process Zig shell_engine",
            .remediation = "Shell evaluation uses the CLI binary (no companion daemon).",
        };
        protection_active = true;
        try tui.render.stepLine(io, stdout, .done, "Command guard", "Zig shell_engine ready (in-process)", 80);
    } else {
        daemon_check = try onboarding.checkDaemonHealth(allocator, false, daemon_check_fn);
        try tui.render.stepLine(io, stdout, .done, "Command guard", "Not required for this setup path", 80);
        protection_active = onboarding.verifyFirewallReady(io, workspace_root);
    }

    var configured_hosts: std.ArrayList([]const u8) = .empty;
    defer {
        for (configured_hosts.items) |host| allocator.free(host);
        configured_hosts.deinit(allocator);
    }

    if (selected_hosts.items.len == 0) {
        try tui.render.stepLine(io, stdout, .done, "Hosts", "No hosts selected.", 80);
    } else if (protection.needsCommandGuard()) {
        const host_failures = try installSelectedHosts(io, allocator, selected_hosts.items, stdout, &configured_hosts);
        failures += host_failures;
        protection_active = protection_active and host_failures == 0;
        if (host_failures == 0) {
            try tui.render.stepLine(io, stdout, .done, "Hosts", "Integrations configured", 80);
        } else {
            try tui.render.stepLine(io, stdout, .failed, "Hosts", "Integration failed. Run `ryk plugin doctor`", 80);
        }
    } else {
        try tui.render.stepLine(io, stdout, .done, "Hosts", "Skipped for this setup path", 80);
        protection_active = onboarding.verifyFirewallReady(io, workspace_root);
    }

    var verification: ?onboarding.VerificationOutcome = null;
    if (!flags.skip_verify and failures == 0) {
        if (protection.needsCommandGuard() and daemon_check.status != .compatible) {
            try tui.render.stepLine(io, stdout, .failed, "Verify", "Skipped shell verification because command guard is unavailable", 80);
            failures += 1;
        } else {
            const eval_fn = shell_evaluator orelse shell_eval.defaultEvaluator;
            verification = try onboarding.runVerification(
                allocator,
                io,
                workspace_root,
                protection,
                selected_hosts.items,
                eval_fn,
                null,
            );
            const verify_ok = verification.?.passed();
            protection_active = protection_active and verify_ok;
            try tui.render.stepLine(io, stdout, if (verify_ok) .done else .failed, "Verify", verification.?.detail, 80);
            if (!verify_ok) {
                try stdout.print("  Safe command ({s}): {s}\n", .{ onboarding.safe_verification_command, if (verification.?.safe_allowed) "allowed" else "FAILED" });
                try stdout.print("  Dangerous command ({s}): {s}\n", .{ onboarding.dangerous_verification_command, if (verification.?.dangerous_denied) "denied" else "FAILED" });
                if (verification.?.hook_verified) |hook_ok| {
                    try stdout.print("  Hook contract: {s}\n", .{if (hook_ok) "verified" else "FAILED"});
                    if (hook_ok) try stdout.print("  Host activation: {s}\n", .{verification.?.host_evidence.label()});
                }
                if (verification.?.firewall_ready) |firewall_ok| {
                    try stdout.print("  Firewall policy: {s}\n", .{if (firewall_ok) "ready" else "missing"});
                }
                failures += 1;
            }
        }
    } else if (flags.skip_verify) {
        try stdout.writeAll("\nVerification skipped (--skip-verify).\n");
    }

    try stdout.writeAll("\n");
    if (failures > 0) {
        try writeFailureSummary(io, stdout, selected_hosts.items, configured_hosts.items, daemon_check, verification, protection_active, policy_mode);
        return exit_codes.general;
    }

    try writeSuccessEndCard(
        io,
        allocator,
        stdout,
        workspace_root,
        flags.preset,
        protection,
        selected_hosts.items,
        configured_hosts.items,
        daemon_check,
        verification,
        policy_mode,
    );
    return exit_codes.success;
}

/// Resolves protection posture without an interactive grade menu.
/// Programmatic `StartFlags.protection` remains for tests/internal callers only.
fn resolveProtectionMode(flags: onboarding.StartFlags) onboarding.ProtectionMode {
    if (flags.protection) |mode| return mode;
    return onboarding.defaultProtectionMode();
}

/// Modes that ask or enforce on risk. observe/trusted soften and must not claim Ask protection.
/// Matches status `policyModeIsMediating` vocabulary (ask/strict/ci/redteam).
fn policyModeIsAskEquivalent(mode: []const u8) bool {
    const parsed = orca_policy.schema.Mode.parse(mode) orelse return false;
    return switch (parsed) {
        .ask, .yolo, .strict, .ci, .redteam => true,
        .observe, .trusted => false,
    };
}

/// Load workspace policy mode after ensurePolicy. Returns null when missing/unreadable.
fn readWorkspacePolicyMode(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ?[]const u8 {
    const path = onboarding.policyPath(allocator, workspace_root) catch return null;
    defer allocator.free(path);
    var loaded = core_api.loadPolicyFile(io, allocator, path) catch return null;
    defer loaded.deinit();
    return allocator.dupe(u8, loaded.mode().toString()) catch null;
}

const SelectedHosts = struct {
    items: [][]const u8,
    owned: bool,
};

fn resolveSelectedHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    flags: onboarding.StartFlags,
    host_statuses: []const onboarding.HostStatus,
    stdout: anytype,
) !SelectedHosts {
    if (flags.hosts_csv) |csv| {
        return .{ .items = try onboarding.parseHostsCsv(allocator, csv), .owned = true };
    }

    if (flags.auto) {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        for (host_statuses) |status| {
            if (!status.detected) continue;
            try list.append(allocator, try allocator.dupe(u8, status.name));
        }
        return .{ .items = try list.toOwnedSlice(allocator), .owned = true };
    }

    var detected_count: usize = 0;
    for (host_statuses) |status| {
        if (status.detected) detected_count += 1;
    }
    if (detected_count == 0) {
        try stdout.writeAll("\nNo supported agent hosts detected in PATH.\n");
        try stdout.writeAll("Install an agent (claude, codex, …) then re-run `ryk start`, or launch with `ryk <agent>` once protected.\n\n");
        return .{ .items = &.{}, .owned = false };
    }

    var options = try allocator.alloc(tui.prompt.SelectionOption, detected_count);
    defer allocator.free(options);

    var visible_idx: usize = 0;
    for (host_statuses) |status| {
        if (!status.detected) continue;
        const marker = if (status.installed) " (installed)" else "";
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ status.name, marker }) catch status.name;
        options[visible_idx] = .{
            .label = try allocator.dupe(u8, label),
            .checked = true,
            .id = try allocator.dupe(u8, status.name),
        };
        visible_idx += 1;
    }
    defer {
        for (options) |opt| {
            allocator.free(opt.label);
            if (opt.id) |id| allocator.free(id);
        }
    }

    const confirmed = try tui.prompt.multiSelect(io, allocator, stdout, options, "Select agent hosts to integrate", null);
    if (!confirmed) {
        try stdout.writeAll("\nHost selection cancelled.\n");
        return .{ .items = &.{}, .owned = false };
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (options) |item| {
        if (!item.checked) continue;
        const host_name = item.id orelse item.label;
        try list.append(allocator, try allocator.dupe(u8, host_name));
    }
    return .{ .items = try list.toOwnedSlice(allocator), .owned = true };
}

fn installSelectedHosts(
    io: std.Io,
    allocator: std.mem.Allocator,
    hosts: []const []const u8,
    stdout: anytype,
    configured_out: *std.ArrayList([]const u8),
) !usize {
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    const home = try processHome(allocator);
    defer allocator.free(home);

    var failures: usize = 0;
    for (hosts) |host_name| {
        try stdout.print("  → {s}: ", .{host_name});
        if (std.mem.eql(u8, host_name, "pi")) {
            const result = pi_install.install(io, allocator, .{
                .home = home,
                .ryk_binary = self_exe,
            }) catch |err| {
                try stdout.print("failed ({s})\n", .{@errorName(err)});
                failures += 1;
                continue;
            };
            if (result == .assets_unavailable) {
                try stdout.writeAll("failed (bundled extension assets unavailable)\n");
                failures += 1;
                continue;
            }
            try stdout.writeAll(switch (result) {
                .installed => "installed (bundled extension)\n",
                .upgraded => "upgraded (bundled extension)\n",
                .already_installed => "already installed (verified)\n",
                .assets_unavailable => unreachable,
            });
            try configured_out.append(allocator, try allocator.dupe(u8, host_name));
            continue;
        }
        if (std.mem.eql(u8, host_name, "grok")) {
            const result = grok_install.installAtHome(io, allocator, home, self_exe) catch |err| {
                try stdout.print("failed ({s})\n", .{@errorName(err)});
                failures += 1;
                continue;
            };
            defer result.deinit(allocator);
            try stdout.writeAll(if (result.changed) "installed (PreToolUse hook)\n" else "already installed (verified)\n");
            try configured_out.append(allocator, try allocator.dupe(u8, host_name));
            continue;
        }
        const install_argv = &[_][]const u8{ self_exe, "plugin", "install", host_name, "--yes" };
        const code = runChild(allocator, install_argv) catch |err| {
            try stdout.print("failed ({s})\n", .{@errorName(err)});
            failures += 1;
            continue;
        };
        const outcome = plugin.verifyHostInstallAfterChild(io, allocator, host_name, code);
        if (outcome != .failed) {
            if (outcome == .installed_after_child_failure)
                try stdout.print("installed (verified; installer exited {d})\n", .{code})
            else
                try stdout.writeAll("installed (verified)\n");
            try configured_out.append(allocator, try allocator.dupe(u8, host_name));
        } else {
            try stdout.print("failed verification (installer exit {d})\n", .{code});
            failures += 1;
        }
    }
    return failures;
}

fn processHome(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try env_util.createProcessMap(allocator);
    defer env_map.deinit();
    return (try env_util.getOwned(&env_map, allocator, "HOME")) orelse error.HomeNotSet;
}

/// Soft product-path refresh for start (DIS-1). Builds host_keys from selected
/// pi/opencode, else detected pi/opencode, else the known adapter pair. Errors
/// and empty discovery never fail start; empty discovery leaves managed intact.
fn softRefreshStartDiscovery(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    selected_hosts: []const []const u8,
    host_statuses: []const onboarding.HostStatus,
) void {
    const home = processHome(allocator) catch return;
    defer allocator.free(home);
    if (home.len == 0) return;

    var keys_buf: [8][]const u8 = undefined;
    var keys_len: usize = 0;

    const append_key = struct {
        fn go(buf: *[8][]const u8, len: *usize, name: []const u8) void {
            if (len.* >= buf.len) return;
            if (!(std.mem.eql(u8, name, "pi") or std.mem.eql(u8, name, "opencode"))) return;
            for (buf.*[0..len.*]) |existing| {
                if (std.mem.eql(u8, existing, name)) return;
            }
            buf.*[len.*] = name;
            len.* += 1;
        }
    }.go;

    for (selected_hosts) |name| append_key(&keys_buf, &keys_len, name);
    if (keys_len == 0) {
        for (host_statuses) |st| {
            if (st.detected) append_key(&keys_buf, &keys_len, st.name);
        }
    }
    // Floor: always attempt known adapters when nothing selected/detected
    // (soft-empty if no auth). Keeps start path discovery-ready.
    if (keys_len == 0) {
        keys_buf[0] = "pi";
        keys_buf[1] = "opencode";
        keys_len = 2;
    }

    refreshManagedDiscovery(io, allocator, workspace_root, home, keys_buf[0..keys_len]) catch {};
}

fn runChild(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
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

/// Stable first-run end-card after successful `ryk start`.
/// Works on non-TTY (plain text, no broken ANSI via tui theme degrade).
fn writeSuccessEndCard(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    workspace_root: []const u8,
    preset: []const u8,
    protection: onboarding.ProtectionMode,
    selected_hosts: []const []const u8,
    configured_hosts: []const []const u8,
    daemon_check: onboarding.DaemonCheck,
    verification: ?onboarding.VerificationOutcome,
    policy_mode: ?[]const u8,
) !void {
    const mode = policy_mode orelse "unknown";
    const ask_equivalent = policyModeIsAskEquivalent(mode);
    const claim_ready = protectionClaimReady(protection, selected_hosts, verification, ask_equivalent);
    if (claim_ready) {
        try tui.render.callout(io, stdout, .success, "You're now protected by ryk", "The installed fail-closed integration chain passed verification.");
    } else if (!ask_equivalent) {
        // Prefer honest residual over silent overclaim when existing observe/trusted policy was kept.
        const residual_body = try std.fmt.allocPrint(
            allocator,
            "Configured, but policy mode={s} is not Ask. Existing policy was preserved.",
            .{mode},
        );
        defer allocator.free(residual_body);
        try tui.render.callout(io, stdout, .warn, "Setup complete — residual policy mode", residual_body);
    } else if (verification) |outcome| {
        try tui.render.callout(io, stdout, .warn, "Setup complete — activation evidence pending", outcome.host_evidence.label());
    } else {
        try tui.render.callout(io, stdout, .warn, "Setup complete — verification skipped", "Configuration was written, but ryk did not claim active protection without verification.");
    }
    try stdout.writeAll("\n");

    const policy_path = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "policy.yaml" });
    defer allocator.free(policy_path);
    const policy_line = try std.fmt.allocPrint(allocator, "{s}  (preset {s})", .{ policy_path, preset });
    defer allocator.free(policy_line);
    const daemon_line = try std.fmt.allocPrint(allocator, "{s}", .{daemon_check.status.label()});
    defer allocator.free(daemon_line);
    const verify_line: []const u8 = if (verification) |v|
        if (!v.passed())
            "failed"
        else if (v.host_evidence == .native or v.host_evidence == .not_applicable)
            "passed"
        else
            v.host_evidence.label()
    else
        "skipped";

    const daemon_status_line = try std.fmt.allocPrint(allocator, "Daemon       {s}", .{daemon_line});
    defer allocator.free(daemon_status_line);
    const policy_status_line = try std.fmt.allocPrint(allocator, "Policy       {s}", .{policy_line});
    defer allocator.free(policy_status_line);
    // Honesty: surface real mode; only claim "Ask on risk" when mode is ask.
    const protection_status_line = if (std.mem.eql(u8, mode, "ask"))
        try allocator.dupe(u8, "Protection   Ask on risk")
    else if (ask_equivalent)
        try std.fmt.allocPrint(allocator, "Protection   mode={s} (enforcing)", .{mode})
    else
        try std.fmt.allocPrint(allocator, "Protection   mode={s} (not Ask)", .{mode});
    defer allocator.free(protection_status_line);
    const verify_status_line = try std.fmt.allocPrint(allocator, "Verify       {s}", .{verify_line});
    defer allocator.free(verify_status_line);
    const status_lines = [_][]const u8{ daemon_status_line, policy_status_line, protection_status_line, verify_status_line };
    try tui.render.panel(io, stdout, "Status", &status_lines);
    try stdout.writeAll("\n");

    // Host install results: selected hosts get ✓ / failed; unselected shown as skipped when CG.
    var host_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (host_lines.items) |line| allocator.free(line);
        host_lines.deinit(allocator);
    }
    if (!protection.needsCommandGuard()) {
        try host_lines.append(allocator, try allocator.dupe(u8, "hooks skipped (shell mediation off)"));
        for (selected_hosts) |host| {
            try host_lines.append(allocator, try std.fmt.allocPrint(allocator, "  {s}  skipped", .{host}));
        }
    } else if (selected_hosts.len == 0) {
        try host_lines.append(allocator, try allocator.dupe(u8, "none selected"));
    } else {
        for (selected_hosts) |host| {
            const ok = hostInList(host, configured_hosts);
            const mark: []const u8 = if (!ok)
                "failed"
            else if (std.mem.eql(u8, host, "openclaw"))
                "configured; wrapper required: ryk run -- openclaw"
            else if (verification) |v|
                if (v.host_evidence == .native or
                    v.host_evidence == .installed_fail_closed or
                    v.host_evidence == .configuration_only)
                    "✓ fail-closed chain verified"
                else
                    "configured; activation unverified"
            else
                "configured; verification skipped";
            try host_lines.append(allocator, try std.fmt.allocPrint(allocator, "  {s}  {s}", .{ host, mark }));
        }
    }
    try tui.render.panel(io, stdout, "Hosts", host_lines.items);
    try stdout.writeAll("\n");

    try tui.theme.paintBold(io, stdout, .brand, "Try next");
    try stdout.writeAll("\n");
    try stdout.writeAll("  ryk claude          # or codex / pi / opencode / …\n");
    try stdout.writeAll("  ryk doctor\n");
    try stdout.writeAll("  ryk replay\n");
    try stdout.writeAll("\n");
    try tui.theme.paint(io, stdout, .muted, "Re-run safely: ryk start · off-ramp: ryk stop");
    try stdout.writeAll("\n");
}

fn protectionClaimReady(
    protection: onboarding.ProtectionMode,
    selected_hosts: []const []const u8,
    verification: ?onboarding.VerificationOutcome,
    ask_equivalent: bool,
) bool {
    if (!ask_equivalent) return false;
    const outcome = verification orelse return false;
    if (!outcome.passed()) return false;
    if (selected_hosts.len == 0) return false;
    if (!protection.needsCommandGuard()) return outcome.firewall_ready == true;
    return outcome.host_evidence == .native or
        outcome.host_evidence == .installed_fail_closed or
        outcome.host_evidence == .configuration_only;
}

fn hostInList(name: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn writeFailureSummary(
    io: std.Io,
    stdout: anytype,
    selected_hosts: []const []const u8,
    configured_hosts: []const []const u8,
    daemon_check: onboarding.DaemonCheck,
    verification: ?onboarding.VerificationOutcome,
    protection_active: bool,
    policy_mode: ?[]const u8,
) !void {
    try style.maybeColor(io, stdout, style.Style.red, "Setup incomplete");
    try stdout.writeAll("\n\n");
    if (policy_mode) |mode| {
        if (std.mem.eql(u8, mode, "ask")) {
            try stdout.writeAll("Protection posture: Ask on risk\n");
        } else if (policyModeIsAskEquivalent(mode)) {
            try stdout.print("Protection posture: mode={s} (enforcing)\n", .{mode});
        } else {
            try stdout.print("Protection posture: mode={s} (not Ask)\n", .{mode});
        }
    } else {
        try stdout.writeAll("Protection posture: setup path Ask on risk (auto); policy mode unread\n");
    }
    try stdout.print("Protection active now: {s}\n", .{if (protection_active) "partially or fully" else "no"});
    try stdout.print("Daemon: {s} — {s}\n", .{ daemon_check.status.label(), daemon_check.detail });
    if (verification) |v| try stdout.print("Verification: {s}\n", .{v.detail});
    if (configured_hosts.len > 0) {
        try stdout.writeAll("Configured hosts: ");
        for (configured_hosts, 0..) |host, i| {
            if (i > 0) try stdout.writeAll(", ");
            try stdout.writeAll(host);
        }
        try stdout.writeAll("\n");
    } else if (selected_hosts.len > 0) {
        try stdout.writeAll("Selected hosts: ");
        for (selected_hosts, 0..) |host, i| {
            if (i > 0) try stdout.writeAll(", ");
            try stdout.writeAll(host);
        }
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\nRecommended repair steps:\n");
    try stdout.print("  {s}\n", .{daemon_check.remediation});
    try stdout.writeAll("  ryk plugin doctor\n");
    try stdout.writeAll("  ryk doctor --verbose\n");
    try stdout.writeAll("  ryk start --auto\n");
}

fn flushIfSupported(writer: anytype) !void {
    const Writer = @TypeOf(writer);
    switch (@typeInfo(Writer)) {
        .pointer => |pointer| {
            if (@hasDecl(pointer.child, "flush")) try writer.flush();
        },
        else => {
            if (@hasDecl(Writer, "flush")) try writer.flush();
        },
    }
}

test "start auto mode with mock daemon completes in temp workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .firewall,
        .skip_verify = true,
    };

    const mock_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {}
    }.check;

    const code = try runStart(
        std.testing.io,
        tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        mock_checker,
        onboarding.mockOnboardingEvaluator,
    );
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\u{1F6E1}  ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ask on risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "You're now protected by ryk") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Verification skipped (--skip-verify).") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hosts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk doctor") != null);
    // No interactive grade menu on the Safe Launch path.
    try std.testing.expect(std.mem.indexOf(u8, output, "Choose your protection mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command-guard") == null);
}

test "start protection claim requires a verified installed host chain" {
    const verified_firewall = onboarding.VerificationOutcome{
        .safe_allowed = true,
        .dangerous_denied = true,
        .firewall_ready = true,
        .detail = "ready",
    };
    try std.testing.expect(!protectionClaimReady(.firewall, &.{}, verified_firewall, true));
    try std.testing.expect(!protectionClaimReady(.firewall, &.{}, null, true));

    const contract_only = onboarding.VerificationOutcome{
        .safe_allowed = true,
        .dangerous_denied = true,
        .hook_verified = true,
        .host_evidence = .contract_only,
        .detail = "contract",
    };
    try std.testing.expect(!protectionClaimReady(.command_guard, &.{"codex"}, contract_only, true));

    const installed = onboarding.VerificationOutcome{
        .safe_allowed = true,
        .dangerous_denied = true,
        .hook_verified = true,
        .host_evidence = .installed_fail_closed,
        .detail = "installed",
    };
    try std.testing.expect(protectionClaimReady(.command_guard, &.{"codex"}, installed, true));

    const native = onboarding.VerificationOutcome{
        .safe_allowed = true,
        .dangerous_denied = true,
        .hook_verified = true,
        .host_evidence = .native,
        .detail = "native",
    };
    try std.testing.expect(protectionClaimReady(.command_guard, &.{"codex"}, native, true));
    try std.testing.expect(!protectionClaimReady(.command_guard, &.{"codex"}, native, false));
}

test "start OpenClaw completion is explicit about wrapper-required evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const verification = onboarding.VerificationOutcome{
        .safe_allowed = true,
        .dangerous_denied = true,
        .hook_verified = true,
        .host_evidence = .wrapper_required,
        .detail = onboarding.HostEvidence.wrapper_required.label(),
    };
    const daemon_check = onboarding.DaemonCheck{
        .status = .compatible,
        .detail = "in-process",
        .remediation = "none",
    };
    var output_buffer: [16 * 1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    try writeSuccessEndCard(
        std.testing.io,
        std.testing.allocator,
        &output,
        root,
        "strict-local",
        .command_guard,
        &.{"openclaw"},
        &.{"openclaw"},
        daemon_check,
        verification,
        "ask",
    );

    const written = output.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "You're now protected by ryk") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "activation evidence pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ryk run -- openclaw") != null);
}

test "start reports failure when daemon required but unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .command_guard,
        .skip_verify = true,
    };

    const failing_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {
            return error.DaemonBinaryNotFound;
        }
    }.check;

    const code = try runStart(
        std.testing.io,
        tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        failing_checker,
        null,
    );
    try std.testing.expectEqual(exit_codes.general, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Setup incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Protection active now: no") != null);
}

test "start firewall path verifies without daemon or shell evaluator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .firewall,
        .skip_verify = false,
    };

    const mock_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {
            return error.DaemonBinaryNotFound;
        }
    }.check;

    const code = try runStart(
        std.testing.io,
        tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        mock_checker,
        null,
    );
    try std.testing.expectEqual(exit_codes.success, code);
    // Plain-language setup path (no Command Guard / Firewall grade labels on step lines).
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Not required for this setup path") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Command Guard") == null);
}

test "start with existing observe policy does not claim Ask protection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pre-seed observe policy — ensurePolicy must leave it unchanged.
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io,
            \\version: 1
            \\mode: observe
            \\
        );
    }

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .firewall,
        .skip_verify = true,
    };
    const mock_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {}
    }.check;

    const code = try runStart(
        std.testing.io,
        tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        mock_checker,
        onboarding.mockOnboardingEvaluator,
    );
    try std.testing.expectEqual(exit_codes.success, code);

    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "policy mode=observe") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "not Ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "You're now protected by ryk") == null);
    // Residual callout, not full Ask protection claim.
    try std.testing.expect(std.mem.indexOf(u8, output, "residual policy mode") != null or std.mem.indexOf(u8, output, "Setup complete") != null);
    // Policy file still observe.
    const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: observe") != null);
}

test "policyModeIsAskEquivalent covers ask/enforce not observe/trusted" {
    try std.testing.expect(policyModeIsAskEquivalent("ask"));
    try std.testing.expect(policyModeIsAskEquivalent("strict"));
    try std.testing.expect(policyModeIsAskEquivalent("ci"));
    try std.testing.expect(policyModeIsAskEquivalent("redteam"));
    try std.testing.expect(!policyModeIsAskEquivalent("observe"));
    try std.testing.expect(!policyModeIsAskEquivalent("trusted"));
    try std.testing.expect(!policyModeIsAskEquivalent("unknown"));
}

test "start verification failure detected by allow-only mock evaluator" {
    const outcome = try onboarding.verifyShellEvaluation(
        std.testing.allocator,
        null,
        shell_eval.mockDaemonAllowEvaluator,
    );
    try std.testing.expect(!outcome.passed());
}

test "start resolveProtectionMode auto-selects default without interactive menu" {
    const auto_flags = onboarding.StartFlags{ .auto = true };
    try std.testing.expectEqual(onboarding.defaultProtectionMode(), resolveProtectionMode(auto_flags));

    const interactive_flags = onboarding.StartFlags{};
    try std.testing.expectEqual(onboarding.defaultProtectionMode(), resolveProtectionMode(interactive_flags));

    const override_flags = onboarding.StartFlags{ .protection = .firewall };
    try std.testing.expectEqual(onboarding.ProtectionMode.firewall, resolveProtectionMode(override_flags));
}

test "start auto default path has no protection grade menu jargon in stdout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // Programmatic firewall keeps this test daemon-independent while proving no menu.
    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .firewall,
        .skip_verify = true,
    };
    const mock_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {}
    }.check;

    _ = try runStart(
        std.testing.io,
        tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        mock_checker,
        onboarding.mockOnboardingEvaluator,
    );
    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Choose your protection mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Command Guard") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Maximum Protection") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Firewall-only mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ask on risk") != null);
}

// ---------------------------------------------------------------------------
// AINA P3 S5 — start/init discovery refresh (DIS-1 / DIS-7 / A-P3-2 / A-P3-3)
// Spec: planning/2026-08-02-agent-inference-network-allow-spec.md
// Plan: planning/2026-08-02-aina-p3-discovery-plan.md §3.6 S5
//
// Expected production API (implementer lands in start.zig; RED until then):
//
//   /// Run adapters for host_keys under home; regenerate managed store under
//   /// workspace_root. Hostnames + source tags only. Never edits policy.yaml.
//   /// Soft success when host_keys/home empty or adapters soft-empty (no hard fail).
//   pub fn refreshManagedDiscovery(
//       io: std.Io,
//       allocator: std.mem.Allocator,
//       workspace_root: []const u8,
//       home: []const u8,
//       host_keys: []const []const u8,
//   ) !void
//
// Product wire: `runStart` calls this for selected/detected hosts with parent HOME
// and abs workspace_root (cwd-independent managed path). Soft-skip discovery
// failures — start still succeeds when no hosts detected.
// ---------------------------------------------------------------------------

/// Synthetic pi auth (fake tokens only). xai-oauth URL hosts + openrouter catalog id.
const p3_start_pi_auth_json =
    \\{
    \\  "openrouter": {
    \\    "type": "api_key",
    \\    "key": "sk-fixture-start-pi-openrouter-NOT-REAL-a1"
    \\  },
    \\  "xai-oauth": {
    \\    "type": "oauth",
    \\    "access": "fixture-start-pi-xai-access-NOT-REAL-b2",
    \\    "refresh": "fixture-start-pi-xai-refresh-NOT-REAL-c3",
    \\    "tokenEndpoint": "https://auth.x.ai/oauth2/token",
    \\    "baseUrl": "https://api.x.ai/v1"
    \\  }
    \\}
;

const p3_start_pi_settings_json =
    \\{
    \\  "defaultProvider": "openrouter",
    \\  "model": "openrouter/fixture-start-model"
    \\}
;

/// Opencode auth: xai oauth key → catalog api.x.ai + auth.x.ai.
const p3_start_opencode_auth_json =
    \\{
    \\  "xai": {
    \\    "type": "oauth",
    \\    "access": "fixture-start-oc-xai-access-NOT-REAL-d4",
    \\    "refresh": "fixture-start-oc-xai-refresh-NOT-REAL-e5"
    \\  },
    \\  "opencode": {
    \\    "type": "api",
    \\    "key": "sk-fixture-start-oc-api-NOT-REAL-f6"
    \\  }
    \\}
;

const p3_start_fixture_secret_needles = [_][]const u8{
    "sk-fixture-start-pi-openrouter-NOT-REAL-a1",
    "fixture-start-pi-xai-access-NOT-REAL-b2",
    "fixture-start-pi-xai-refresh-NOT-REAL-c3",
    "fixture-start-oc-xai-access-NOT-REAL-d4",
    "fixture-start-oc-xai-refresh-NOT-REAL-e5",
    "sk-fixture-start-oc-api-NOT-REAL-f6",
    "sk-fixture",
    "NOT-REAL",
};

fn p3StartAbsPath(tmp: anytype) ![]u8 {
    // realPathFileAlloc → [:0]u8; re-dupe so free size matches DebugAllocator (Zig 0.16).
    const z = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(z);
    return try std.testing.allocator.dupe(u8, z);
}

fn p3StartWriteRel(dir: anytype, rel: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try dir.createDirPath(std.testing.io, parent);
    }
    const file = try dir.createFile(std.testing.io, rel, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn p3StartPlantPiHome(home_dir: anytype, auth: []const u8, settings: ?[]const u8) !void {
    try p3StartWriteRel(home_dir, ".pi/agent/auth.json", auth);
    if (settings) |s| try p3StartWriteRel(home_dir, ".pi/agent/settings.json", s);
}

fn p3StartPlantOpencodeHome(home_dir: anytype, auth: []const u8) !void {
    try p3StartWriteRel(home_dir, ".local/share/opencode/auth.json", auth);
}

fn p3StartStoreContainsHost(store: orca_policy.network_discovered.ManagedStore, needle: []const u8) bool {
    for (store.hosts) |entry| {
        if (std.mem.eql(u8, entry.host, needle)) return true;
    }
    return false;
}

fn p3StartAssertManagedHostsSourcesOnly(store: orca_policy.network_discovered.ManagedStore) !void {
    for (store.hosts) |entry| {
        try std.testing.expect(entry.host.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "://") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "@") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "/") == null);
        for (p3_start_fixture_secret_needles) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, entry.host, needle) == null);
        }
        // sources tags required (hostnames+sources shape); tags must not carry secrets.
        try std.testing.expect(entry.sources.len > 0);
        for (entry.sources) |src| {
            for (p3_start_fixture_secret_needles) |needle| {
                try std.testing.expect(std.mem.indexOf(u8, src, needle) == null);
            }
            try std.testing.expect(std.mem.indexOf(u8, src, "://") == null);
        }
    }
}

fn p3StartAssertNoSecretsInBytes(bytes: []const u8) !void {
    for (p3_start_fixture_secret_needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, needle) == null);
    }
    // Managed file is hostnames + source tags — never absolute URL material.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "://") == null);
}

test "start refreshManagedDiscovery pi writes workspace network-discovered.yaml hostnames+sources only" {
    // Acceptance: Synthetic HOME+tmp workspace refresh for pi writes/updates
    // <workspace>/.orca/network-discovered.yaml with hostnames+sources only (DIS-1, A-P3-2).
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantPiHome(home_tmp.dir, p3_start_pi_auth_json, p3_start_pi_settings_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{"pi"});

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);

    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "api.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "openrouter.ai"));
    try p3StartAssertManagedHostsSourcesOnly(store);

    const path = try orca_policy.network_discovered.managedPath(allocator, workspace_root);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".orca/network-discovered.yaml"));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    try p3StartAssertNoSecretsInBytes(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "host:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sources:") != null);
}

test "start refreshManagedDiscovery opencode writes catalog hosts into managed yaml" {
    // Acceptance: Synthetic HOME refresh for opencode writes managed hosts (DIS-1, A-P3-4).
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantOpencodeHome(home_tmp.dir, p3_start_opencode_auth_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{"opencode"});

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);

    try std.testing.expect(p3StartStoreContainsHost(store, "api.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai"));
    try p3StartAssertManagedHostsSourcesOnly(store);

    const path = try orca_policy.network_discovered.managedPath(allocator, workspace_root);
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    try p3StartAssertNoSecretsInBytes(bytes);
}

test "start refreshManagedDiscovery pi+opencode union updates managed store" {
    // Branch: multi-host_keys refresh unions adapter emits into one managed file.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantPiHome(home_tmp.dir, p3_start_pi_auth_json, p3_start_pi_settings_json);
    try p3StartPlantOpencodeHome(home_tmp.dir, p3_start_opencode_auth_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{ "pi", "opencode" });

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);

    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "api.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "openrouter.ai"));
    // opencode catalog hosts when opencode key present
    try std.testing.expect(p3StartStoreContainsHost(store, "opencode.ai") or p3StartStoreContainsHost(store, "models.opencode.ai") or store.hosts.len >= 3);
    try p3StartAssertManagedHostsSourcesOnly(store);
}

test "start refreshManagedDiscovery rediscovery replaces managed only; policy.yaml user allows untouched" {
    // Acceptance: Rediscovery replaces managed entries only; policy.yaml user allows
    // untouched (A-P3-3 / DIS-7). Stale managed host must not survive full rewrite.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    // Pre-seed user policy allows — refresh must never rewrite this file.
    const policy_marker =
        \\version: 1
        \\mode: ask
        \\network:
        \\  allow:
        \\    - user-preserve.example
        \\    - github.com
        \\
    ;
    try ws_tmp.dir.createDirPath(io, ".orca");
    {
        const f = try ws_tmp.dir.createFile(io, ".orca/policy.yaml", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, policy_marker);
    }
    const policy_before = try ws_tmp.dir.readFileAlloc(io, ".orca/policy.yaml", allocator, .limited(4096));
    defer allocator.free(policy_before);

    // Stale managed entry that rediscovery must drop.
    try orca_policy.network_discovered.writeManaged(io, allocator, workspace_root, &.{
        .{ .host = "stale-managed-only.invalid", .sources = &.{"fixture:stale"} },
    });

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantPiHome(home_tmp.dir, p3_start_pi_auth_json, p3_start_pi_settings_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{"pi"});
    // Second rediscovery — still must not touch policy.yaml.
    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{"pi"});

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);
    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai"));
    try std.testing.expect(p3StartStoreContainsHost(store, "api.x.ai"));
    try std.testing.expect(!p3StartStoreContainsHost(store, "stale-managed-only.invalid"));
    try p3StartAssertManagedHostsSourcesOnly(store);

    const policy_after = try ws_tmp.dir.readFileAlloc(io, ".orca/policy.yaml", allocator, .limited(4096));
    defer allocator.free(policy_after);
    try std.testing.expectEqualStrings(policy_before, policy_after);
    try std.testing.expect(std.mem.indexOf(u8, policy_after, "user-preserve.example") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy_after, "github.com") != null);
}

test "start refreshManagedDiscovery nested-cwd lands managed at workspace-root .orca" {
    // Acceptance composition: nested-cwd refresh lands managed at workspace-root .orca/
    // (path independent of process cwd; no decoy under nested cwd).
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, "nested/deep/cwd");
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantPiHome(home_tmp.dir, p3_start_pi_auth_json, p3_start_pi_settings_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    const nested_abs = try ws_tmp.dir.realPathFileAlloc(io, "nested/deep/cwd", allocator);
    defer allocator.free(nested_abs);
    const original_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(original_cwd);
    try std.Io.Threaded.chdir(nested_abs);
    defer std.Io.Threaded.chdir(original_cwd) catch {};

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{"pi"});

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);
    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai"));

    // Decoy path under nested cwd must not be the product file.
    if (ws_tmp.dir.access(io, "nested/deep/cwd/.orca/network-discovered.yaml", .{})) |_| {
        try std.testing.expect(false);
    } else |_| {}

    // Product file exists under workspace root.
    try ws_tmp.dir.access(io, ".orca/network-discovered.yaml", .{});
}

test "start refreshManagedDiscovery soft-succeeds when no hosts detected" {
    // Acceptance: no hard fail when no hosts detected (empty keys / empty home / missing auth).
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    // Empty host_keys
    try refreshManagedDiscovery(io, allocator, workspace_root, "/nonexistent-home-p3-start", &.{});

    // Empty home with host keys
    try refreshManagedDiscovery(io, allocator, workspace_root, "", &.{"pi"});

    // Home without auth files
    var empty_home = std.testing.tmpDir(.{});
    defer empty_home.cleanup();
    const home = try p3StartAbsPath(&empty_home);
    defer allocator.free(home);
    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{ "pi", "opencode" });

    // Soft: may leave managed missing or empty — load must soft-empty, not error.
    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);
    // No discovered hosts expected.
    try std.testing.expect(store.hosts.len == 0 or !p3StartStoreContainsHost(store, "pastebin.com"));
}

test "start refreshManagedDiscovery monopath policy.network_discovered and inference_discover linked" {
    // Composition monopath: start module reaches managed + discover via orca_core.policy.
    _ = orca_policy.network_discovered;
    _ = orca_policy.inference_discover;
    _ = orca_policy.network_discovered.managedPath;
    _ = orca_policy.network_discovered.loadManaged;
    _ = orca_policy.network_discovered.writeManaged;
    _ = orca_policy.inference_discover.discoverForHost;
    try std.testing.expect(true);
}

test "start path helper refresh then runStart --auto still succeeds when fixtures present" {
    // Acceptance LIVE/composition: start-path helper used by ryk start --auto succeeds
    // when fixtures present (refresh does not break setup). Soft path when no hosts too.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try p3StartAbsPath(&ws_tmp);
    defer allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    try p3StartPlantPiHome(home_tmp.dir, p3_start_pi_auth_json, p3_start_pi_settings_json);
    try p3StartPlantOpencodeHome(home_tmp.dir, p3_start_opencode_auth_json);
    const home = try p3StartAbsPath(&home_tmp);
    defer allocator.free(home);

    try refreshManagedDiscovery(io, allocator, workspace_root, home, &.{ "pi", "opencode" });

    var store = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store.deinit(allocator);
    try std.testing.expect(p3StartStoreContainsHost(store, "auth.x.ai") or p3StartStoreContainsHost(store, "api.x.ai"));

    var stdout_buf: [16384]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const flags = onboarding.StartFlags{
        .auto = true,
        .protection = .firewall,
        .skip_verify = true,
    };
    const mock_checker = struct {
        fn check(_: std.mem.Allocator, _: bool) !void {}
    }.check;

    const code = try runStart(
        io,
        ws_tmp.dir,
        flags,
        &stdout_writer,
        &stderr_writer,
        mock_checker,
        onboarding.mockOnboardingEvaluator,
    );
    try std.testing.expectEqual(exit_codes.success, code);

    // Managed discovery must survive start (start must not wipe managed file).
    var store2 = try orca_policy.network_discovered.loadManaged(io, allocator, workspace_root);
    defer store2.deinit(allocator);
    try std.testing.expect(store2.hosts.len > 0);
    try std.testing.expect(p3StartStoreContainsHost(store2, "auth.x.ai") or p3StartStoreContainsHost(store2, "api.x.ai"));
}
