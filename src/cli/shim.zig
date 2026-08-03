const std = @import("std");

const core = @import("orca_core").core;
const core_api = @import("orca_core").api;
const intercept = @import("../intercept/mod.zig");
const policy = @import("orca_core").policy;
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const shell_eval = @import("shell_eval.zig");
const rust_visibility = @import("rust_visibility.zig");

const ShimOptions = struct {
    command_argv: []const []const u8 = &.{},
};

pub fn command(io: std.Io, environ_map: *const std.process.Environ.Map, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseOptions(io, argv, stdout, stderr) catch |err| switch (err) {
        error.HelpShown => return exit_codes.success,
        error.Usage => return exit_codes.usage,
        else => return err,
    };
    return exec(io, environ_map, options.command_argv, stdout, stderr);
}

fn exec(io: std.Io, environ_map: *const std.process.Environ.Map, command_argv: []const []const u8, _: anytype, stderr: anytype) !u8 {
    if (command_argv.len == 0) {
        try stderr.writeAll("ryk shim exec: missing command after '--'.\n");
        return exit_codes.usage;
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    return execWithEnv(io, allocator, command_argv, environ_map, stderr, null);
}

fn execWithEnv(io: std.Io, allocator: std.mem.Allocator, command_argv: []const []const u8, env_map: *const std.process.Environ.Map, stderr: anytype, shell_evaluator: ?shell_eval.ShellCommandEvaluatorFn) !u8 {
    const session_id = env_map.get("ORCA_SESSION_ID") orelse {
        try stderr.writeAll("ryk shim exec: missing ORCA_SESSION_ID; shims only work inside a ryk session.\n");
        return exit_codes.general;
    };
    const workspace_root = env_map.get("ORCA_WORKSPACE_ROOT") orelse {
        try stderr.writeAll("ryk shim exec: missing ORCA_WORKSPACE_ROOT; shims only work inside a ryk session.\n");
        return exit_codes.general;
    };
    const shim_dir = env_map.get("ORCA_SHIM_DIR") orelse {
        try stderr.writeAll("ryk shim exec: missing ORCA_SHIM_DIR; refusing unsafe delegation.\n");
        return exit_codes.general;
    };
    const path_value = env_map.get("PATH") orelse "";
    const adjusted_path = try intercept.commands.pathWithoutShimAlloc(allocator, path_value, shim_dir);
    defer allocator.free(adjusted_path);

    const display = try intercept.commands.displayArgvAlloc(allocator, command_argv);
    defer allocator.free(display);

    var selected = loadPolicyForShim(io, allocator, workspace_root, session_id, env_map) catch |err| switch (err) {
        error.UntrustedPolicyPath => {
            const decision: core.decision.Decision = .{
                .result = .deny,
                .reason = "untrusted ORCA_POLICY_PATH; refusing child-controlled policy override",
                .risk_score = 90,
                .ci_may_proceed = false,
            };
            // Deny still wins when in-sandbox audit cannot open (control write-deny).
            var untrusted_audit = openShimAuditBestEffort(io, allocator, workspace_root, session_id, stderr, env_map) catch return exit_codes.general;
            if (untrusted_audit) |*writer| {
                defer writer.deinit();
                try appendCommandEvent(io, writer, session_id, .command_attempt, display, null);
                try appendCommandEvent(io, writer, session_id, .command_denied, display, decision);
            }
            try stderr.writeAll("ryk shim exec: untrusted ORCA_POLICY_PATH; refusing child-controlled policy override.\n");
            return exit_codes.denial;
        },
        else => return err,
    };
    defer selected.deinit();
    const effective_mode = try shimMode(io, allocator, workspace_root, session_id, &selected.policy, env_map);

    // Bind session workspace_root so zigEvaluator does not re-realpath/walk-up
    // under Seatbelt (second unexpectedErrno residual when audit_options was null).
    const shim_audit_opts = shell_eval.ShellAuditOptions{
        .io = io,
        .workspace_root = workspace_root,
        .event_source = "shim",
        .session_id = session_id,
    };
    var command_decision = try shell_eval.evaluateCommand(
        allocator,
        effective_mode,
        command_argv,
        workspace_root,
        shell_evaluator,
        null,
        shim_audit_opts,
        selected.policy.commands.allow,
    );
    defer command_decision.deinit(allocator);

    var final_decision = command_decision.decision;
    if (command_decision.decision.result != .allow and command_decision.decision.result != .observe) {
        // Child can forge ORCA_APPROVED_COMMAND_SESSION; durable audit record is required for
        // session-scoped approval. ORCA_APPROVED_COMMAND_ONCE is parent-set immediately before spawn.
        // Fail-closed Evaluate failures (daemon unavailable / protocol mismatch / malformed) are never
        // softened by parent approval — only pack Deny / SoftBlock outcomes may be approved.
        const parent_approved = !command_decision.fail_closed and (try approvalRecordedForCommand(io, allocator, workspace_root, session_id, display) or
            intercept.commands.onceApprovalEnvMatches(env_map, display));
        if (parent_approved) {
            try intercept.commands.consumeOnceApproval(allocator, @constCast(env_map), display);
            final_decision = .{
                .result = .allow,
                .reason = "parent approval matched command hash",
                .risk_score = command_decision.decision.risk_score,
                .ci_may_proceed = true,
            };
        } else {
            // Deny path: still deny when audit open fails under control write-deny.
            var deny_audit = openShimAuditBestEffort(io, allocator, workspace_root, session_id, stderr, env_map) catch return exit_codes.general;
            if (deny_audit) |*writer| {
                defer writer.deinit();
                try appendCommandEvent(io, writer, session_id, .command_attempt, display, null);
                try appendCommandEvent(io, writer, session_id, .command_denied, display, command_decision.decision);
            }
            try stderr.print("ryk shim exec: command denied: {s}\n", .{command_decision.decision.reason});
            const command_display = try intercept.commands.displayArgvRedactedAlloc(allocator, command_argv);
            defer allocator.free(command_display);
            const next = try rust_visibility.formatDenyNextSteps(
                allocator,
                command_display,
                command_decision.owned_rule_id,
                command_decision.owned_remediation,
            );
            defer allocator.free(next);
            try stderr.writeAll(next);
            return exit_codes.denial;
        }
    }

    const real_binary = intercept.commands.resolveRealBinaryAlloc(io, allocator, command_argv[0], adjusted_path, shim_dir) catch |err| switch (err) {
        error.CommandNotFound => {
            try stderr.print("ryk shim exec: real command not found after removing shim path: {s}\n", .{command_argv[0]});
            return exit_codes.general;
        },
        else => return err,
    };
    defer allocator.free(real_binary);

    // Allow path: still resolve + spawn when audit cannot open under control write-deny.
    var allow_audit = openShimAuditBestEffort(io, allocator, workspace_root, session_id, stderr, env_map) catch return exit_codes.general;
    if (allow_audit) |*writer| {
        defer writer.deinit();
        try appendCommandEvent(io, writer, session_id, .command_attempt, display, null);
        try appendCommandEvent(io, writer, session_id, .command_allowed, display, final_decision);
    }

    var child_argv = try allocator.alloc([]const u8, command_argv.len);
    defer allocator.free(child_argv);
    child_argv[0] = real_binary;
    if (command_argv.len > 1) @memcpy(child_argv[1..], command_argv[1..]);

    const mutable_env = @constCast(env_map);
    try mutable_env.put("PATH", adjusted_path);

    var child = std.process.spawn(io, .{
        .argv = child_argv,
        .environ_map = mutable_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("ryk shim exec: command not found: {s}\n", .{command_argv[0]});
            return exit_codes.general;
        },
        else => return err,
    };
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => exit_codes.child_failure,
    };
}

/// True when audit open failed because the sandboxed process cannot write the
/// control root (`workspace/.orca`) — intentional Seatbelt residual, not a
/// programming error. Do not kill the shim solely for this.
fn isControlWriteDenyAuditError(err: anyerror) bool {
    return err == error.PermissionDenied or err == error.AccessDenied;
}

/// Parent sets this when OS attach is planned (control write-deny residual known).
/// Shims skip opening `.orca/.../events.jsonl` and stay silent — parent owns the
/// single `audit=degraded` banner (E0 / RT-05). Values: `degraded` | `skip`.
/// **Child-forgable env alone is not trusted** — session file must attest (F36).
pub const shim_audit_mode_env = "ORCA_SHIM_AUDIT_MODE";
pub const session_audit_mode_filename = "shim_audit_mode";

fn sessionAuditModePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions", session_id, session_audit_mode_filename });
}

/// Parent `ryk run` writes this before PATH shims run so agents cannot silence
/// in-shim audit by exporting `ORCA_SHIM_AUDIT_MODE=degraded` alone.
pub fn writeSessionShimAuditMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    mode: []const u8,
) !void {
    const path = try sessionAuditModePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    const sessions_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions", session_id });
    defer allocator.free(sessions_dir);
    try std.Io.Dir.cwd().createDirPath(io, sessions_dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, mode);
    try file.writeStreamingAll(io, "\n");
}

fn readSessionShimAuditMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?[]const u8 {
    const path = try sessionAuditModePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32)) catch return null;
    // Caller does not free — only used for immediate parse; free after check.
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    // Return a static sentinel via stack is hard; use parse inline.
    if (std.ascii.eqlIgnoreCase(trimmed, "degraded") or std.ascii.eqlIgnoreCase(trimmed, "skip")) {
        return "degraded";
    }
    return null;
}

fn shimAuditModeIsDegraded(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    env_map: *const std.process.Environ.Map,
) bool {
    // Session file is parent-attested; env alone is hostile (child can set it).
    const session = readSessionShimAuditMode(io, allocator, workspace_root, session_id) catch null;
    if (session != null) return true;
    // Tests / legacy without a session recording: allow env only when session_id
    // is empty (no session context) — production always has a session id.
    if (session_id.len == 0) {
        const raw = env_map.get(shim_audit_mode_env) orelse return false;
        return std.ascii.eqlIgnoreCase(raw, "degraded") or std.ascii.eqlIgnoreCase(raw, "skip");
    }
    return false;
}

/// Best-effort session audit open for in-sandbox shims.
/// - When parent **recorded** audit mode degraded|skip (session file): skip open,
///   no stderr (≤1 degraded line is the parent banner; never N× per shimmed cmd).
/// - Child-only `ORCA_SHIM_AUDIT_MODE` is ignored when a session id is present.
/// - On control write-deny residuals without parent flag: warn on stderr and
///   return null (allow continues; deny still denies). Residual spam path when
///   parent did not mark attach.
/// - On other open failures: message printed; returns `error.ShimAuditOpenFailed`
///   so callers map to general exit (not silent swallow of OOM/corruption).
/// Do **not** “fix” by making `.orca` agent-writable.
fn openShimAuditBestEffort(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    stderr: anytype,
    env_map: *const std.process.Environ.Map,
) error{ShimAuditOpenFailed}!?core_api.AuditWriter {
    if (shimAuditModeIsDegraded(io, allocator, workspace_root, session_id, env_map)) return null;
    return core_api.openAuditWriter(io, allocator, workspace_root, session_id) catch |open_err| {
        if (isControlWriteDenyAuditError(open_err)) {
            stderr.print(
                "ryk shim exec: audit append skipped (control write-deny residual: {s}); continuing without in-shim audit.\n",
                .{@errorName(open_err)},
            ) catch {};
            return null;
        }
        stderr.print("ryk shim exec: failed to open audit log: {s}\n", .{@errorName(open_err)}) catch {};
        return error.ShimAuditOpenFailed;
    };
}

fn parseOptions(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !ShimOptions {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        _ = try help.writeCommand(io, stdout, "shim");
        return error.HelpShown;
    }
    if (!std.mem.eql(u8, argv[0], "exec")) {
        try stderr.writeAll("ryk shim: expected subcommand 'exec'.\n");
        return error.Usage;
    }
    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "--")) {
        try stderr.writeAll("ryk shim exec: expected '--' before command.\n");
        return error.Usage;
    }
    return .{ .command_argv = argv[2..] };
}

fn loadPolicyForShim(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8, env_map: *const std.process.Environ.Map) !policy.schema.LoadedPolicy {
    if (env_map.get("ORCA_POLICY_PATH")) |path| {
        if (!try policyPathRecordedForSession(io, allocator, workspace_root, session_id, path)) return error.UntrustedPolicyPath;
        return loadRecordedPolicySource(io, allocator, path, workspace_root);
    }
    return policy.load.discover(io, allocator, null, workspace_root);
}

fn loadRecordedPolicySource(io: std.Io, allocator: std.mem.Allocator, source: []const u8, workspace_root: []const u8) !policy.schema.LoadedPolicy {
    const builtin_prefix = "builtin:";
    if (std.mem.startsWith(u8, source, builtin_prefix)) {
        const preset_name = source[builtin_prefix.len..];
        const preset = policy.presets.Preset.parse(preset_name) orelse return error.InvalidPolicy;
        var loaded = try policy.load.loadPreset(allocator, preset);
        errdefer loaded.deinit();
        return .{
            .policy = loaded,
            .source = .builtin,
            .path = try allocator.dupe(u8, source),
        };
    }
    return policy.load.discover(io, allocator, source, workspace_root);
}

/// Session-recorded mode file written by `ryk run` before shims are active.
/// Child processes can rewrite env; they must not rewrite enforcement mode via `ORCA_MODE`.
pub const session_mode_filename = "shim_mode";

fn sessionModePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions", session_id, session_mode_filename });
}

/// Persist the parent session's effective mode so shim callbacks cannot soften via env.
pub fn writeSessionShimMode(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8, mode: policy.schema.Mode) !void {
    const path = try sessionModePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    const sessions_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions", session_id });
    defer allocator.free(sessions_dir);
    try std.Io.Dir.cwd().createDirPath(io, sessions_dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, mode.toString());
    try file.writeStreamingAll(io, "\n");
}

fn readSessionShimMode(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) !?policy.schema.Mode {
    const path = try sessionModePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch return null;
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return policy.schema.Mode.parse(trimmed);
}

fn modeStrictness(mode: policy.schema.Mode) u8 {
    return switch (mode) {
        .observe, .trusted => 0,
        .ask, .yolo => 1,
        .strict, .redteam => 2,
        .ci => 3,
    };
}

fn moreRestrictiveMode(a: policy.schema.Mode, b: policy.schema.Mode) policy.schema.Mode {
    return if (modeStrictness(a) >= modeStrictness(b)) a else b;
}

/// Resolve shim evaluation mode. Child env is hostile: never soften below the
/// parent-recorded session mode (or policy mode when no recording exists).
fn shimMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    selected: *const policy.schema.Policy,
    env_map: *const std.process.Environ.Map,
) !policy.schema.Mode {
    // Parent `ryk run` writes shim_mode before PATH shims are active. Prefer it
    // over ORCA_MODE so agents cannot ORCA_MODE=observe their way past strict.
    if (try readSessionShimMode(io, allocator, workspace_root, session_id)) |recorded| {
        return recorded;
    }

    // Legacy / tests without a recorded mode: env may only raise strictness.
    const policy_mode = selected.mode;
    if (env_map.get("ORCA_MODE")) |mode_text| {
        if (policy.schema.Mode.parse(mode_text)) |env_mode| {
            return moreRestrictiveMode(policy_mode, env_mode);
        }
    }
    return policy_mode;
}

fn approvalRecordedForCommand(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8, command_display: []const u8) !bool {
    const events_rel = try std.fs.path.join(allocator, &.{ ".orca", "sessions", session_id, "events.jsonl" });
    defer allocator.free(events_rel);
    var workspace_dir = std.Io.Dir.openDirAbsolute(io, workspace_root, .{}) catch return false;
    defer workspace_dir.close(io);
    const events_text = workspace_dir.readFileAlloc(io, events_rel, allocator, .limited(core.limits.max_audit_log_len)) catch return false;
    defer allocator.free(events_text);

    var lines = std.mem.splitScalar(u8, events_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const event_type = object.get("type") orelse continue;
        if (event_type != .string or !std.mem.eql(u8, event_type.string, "user_approval")) continue;
        const target = object.get("target") orelse continue;
        if (target != .object) continue;
        const target_value = target.object.get("value") orelse continue;
        if (target_value != .string or !std.mem.eql(u8, target_value.string, command_display)) continue;
        const decision = object.get("decision") orelse continue;
        if (decision != .object) continue;
        const result = decision.object.get("result") orelse continue;
        if (result == .string and std.mem.eql(u8, result.string, "allow")) return true;
    }
    return false;
}

fn policyPathRecordedForSession(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8, policy_source: []const u8) !bool {
    const events_rel = try std.fs.path.join(allocator, &.{ ".orca", "sessions", session_id, "events.jsonl" });
    defer allocator.free(events_rel);
    var workspace_dir = std.Io.Dir.openDirAbsolute(io, workspace_root, .{}) catch return false;
    defer workspace_dir.close(io);
    const events_text = workspace_dir.readFileAlloc(io, events_rel, allocator, .limited(core.limits.max_audit_log_len)) catch return false;
    defer allocator.free(events_text);

    var lines = std.mem.splitScalar(u8, events_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const event_type = object.get("type") orelse continue;
        if (event_type != .string or !std.mem.eql(u8, event_type.string, "policy_loaded")) continue;
        const target = object.get("target") orelse continue;
        if (target != .object) continue;
        const target_value = target.object.get("value") orelse continue;
        if (target_value == .string and std.mem.eql(u8, target_value.string, policy_source)) return true;
    }
    return false;
}

fn appendCommandEvent(io: std.Io, writer: *core_api.AuditWriter, session_id_text: []const u8, event_type: core.event.EventType, display: []const u8, decision: ?core.decision.Decision) !void {
    var session_id: core.session.SessionId = .{ .value = undefined, .len = 0 };
    if (session_id_text.len > session_id.value.len) return error.InvalidSessionId;
    @memcpy(session_id.value[0..session_id_text.len], session_id_text);
    session_id.len = session_id_text.len;
    const ts = core.time.Timestamp.now(io);
    const ev: core.event.Event = .{
        .session_id = session_id,
        .event_id = try core.event.generateEventId(ts),
        .timestamp = ts,
        .event_type = event_type,
        .actor = .{ .kind = .orca, .display = "ryk-shim" },
        .target = .{ .kind = .command, .value = display },
        .decision = decision,
    };
    try core_api.appendAuditEvent(writer, ev);
    updateSummaryIfPresent(writer) catch {};
}

fn updateSummaryIfPresent(writer: *core_api.AuditWriter) !void {
    const summary_path = try std.fs.path.join(writer.allocator, &.{ writer.session_dir_path, "summary.json" });
    defer writer.allocator.free(summary_path);
    std.Io.Dir.cwd().access(writer.io, summary_path, .{}) catch return;
    const final_hash = writer.finalHash() orelse return;
    try core_api.updateAuditSummaryFinalHash(writer.allocator, writer.session_dir_path, writer.event_count, final_hash);
}

test "shim parser rejects missing separator" {
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    var env_map = try std.process.Environ.createMap(std.process.Environ.empty, std.testing.allocator);
    defer env_map.deinit();
    const code = try command(std.testing.io, &env_map, &.{ "exec", "git", "status" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "expected '--'") != null);
}

test "shim callback delegates allowed commands and removes shim path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "observe",
        .real_bin = "true",
        .shim_bin = "true",
    });
    defer fx.deinit();

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{"true"}, &fx.env_map, &stderr_writer, shell_eval.mockDaemonAllowEvaluator);
    try std.testing.expectEqual(exit_codes.success, code);
}

test "shim callback blocks denied commands before delegation" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "strict",
        .real_bin = "rm",
        .real_script_body = "exit 42\n",
        .policy_path = "builtin:strict",
        .record_builtin_policy = true,
    });
    defer fx.deinit();

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{ "rm", "-rf", "/" }, &fx.env_map, &stderr_writer, shell_eval.mockDaemonDenyEvaluator);
    try std.testing.expectEqual(exit_codes.denial, code);

    const events = try readSessionEvents(std.testing.allocator, fx.root, fx.session_id);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_denied\"") != null);
}

test "shim callback preserves parent approval for ask-class command" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestWorkspacePolicy(tmp.dir);
    // Strict + ask so npm install requires a recorded parent approval.
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io,
            \\version: 1
            \\mode: strict
            \\commands:
            \\  ask:
            \\    - "npm install*"
            \\  default: ask
        );
    }
    const root = try testRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.createDirPath(std.testing.io, "shim");
    try writeTestScript(tmp.dir, "real/npm", "exit 0\n");
    const real_dir = try testRealPath(std.testing.allocator, tmp.dir, "real");
    defer std.testing.allocator.free(real_dir);
    const shim_dir = try testRealPath(std.testing.allocator, tmp.dir, "shim");
    defer std.testing.allocator.free(shim_dir);
    const session_id = try prepareShimSession(std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const path_value = try std.fmt.allocPrint(std.testing.allocator, "{s}:{s}", .{ shim_dir, real_dir });
    defer std.testing.allocator.free(path_value);
    try env_map.put("PATH", path_value);
    try env_map.put("ORCA_SESSION_ID", session_id);
    try env_map.put("ORCA_WORKSPACE_ROOT", root);
    try env_map.put("ORCA_SHIM_DIR", shim_dir);
    try env_map.put("ORCA_MODE", "ask");
    const display = try intercept.commands.displayArgvAlloc(std.testing.allocator, &.{ "npm", "install" });
    defer std.testing.allocator.free(display);
    try recordShimApproval(std.testing.allocator, root, session_id, display);
    try intercept.commands.appendApprovalHashEnv(std.testing.allocator, &env_map, intercept.commands.approved_once_env, display);
    try std.testing.expect(intercept.commands.approvalEnvMatches(&env_map, display));
    try std.testing.expect(try approvalRecordedForCommand(std.testing.io, std.testing.allocator, root, session_id, display));

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{ "npm", "install" }, &env_map, &stderr_writer, shell_eval.mockDaemonSoftBlockAllowEvaluator);
    if (code != exit_codes.success) {
        std.debug.print("npm approval shim stderr: {s}\n", .{stderr_writer.buffered()});
    }
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(env_map.get(intercept.commands.approved_once_env) == null);

    const events = try readSessionEvents(std.testing.allocator, root, session_id);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "parent approval matched command hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_denied\"") == null);
}

test "shim callback rejects forged approval hash from child environment" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{ .mode = "strict", .real_bin = "git" });
    defer fx.deinit();

    const display = try intercept.commands.displayArgvAlloc(std.testing.allocator, &.{ "git", "push" });
    defer std.testing.allocator.free(display);
    try intercept.commands.appendApprovalHashEnv(
        std.testing.allocator,
        &fx.env_map,
        intercept.commands.approved_session_env,
        display,
    );

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{ "git", "push" }, &fx.env_map, &stderr_writer, shell_eval.mockDaemonDenyEvaluator);
    try std.testing.expectEqual(exit_codes.denial, code);

    const events = try readSessionEvents(std.testing.allocator, fx.root, fx.session_id);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_denied\"") != null);
}

test "shim callback rejects forged policy path from child environment" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestWorkspacePolicy(tmp.dir);
    const root = try testRealPath(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.createDirPath(std.testing.io, "shim");
    try writeTestScript(tmp.dir, "real/git", "exit 0\n");
    {
        const file = try tmp.dir.createFile(std.testing.io, "permissive.yaml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io,
            \\version: 1
            \\mode: strict
            \\commands:
            \\  allow:
            \\    - "git push"
            \\
        );
    }
    const real_dir = try testRealPath(std.testing.allocator, tmp.dir, "real");
    defer std.testing.allocator.free(real_dir);
    const shim_dir = try testRealPath(std.testing.allocator, tmp.dir, "shim");
    defer std.testing.allocator.free(shim_dir);
    const policy_path = try testRealPath(std.testing.allocator, tmp.dir, "permissive.yaml");
    defer std.testing.allocator.free(policy_path);
    const session_id = try prepareShimSession(std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const path_value = try std.fmt.allocPrint(std.testing.allocator, "{s}:{s}", .{ shim_dir, real_dir });
    defer std.testing.allocator.free(path_value);
    try env_map.put("PATH", path_value);
    try env_map.put("ORCA_SESSION_ID", session_id);
    try env_map.put("ORCA_WORKSPACE_ROOT", root);
    try env_map.put("ORCA_SHIM_DIR", shim_dir);
    try env_map.put("ORCA_MODE", "strict");
    try env_map.put("ORCA_POLICY_PATH", policy_path);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{ "git", "push" }, &env_map, &stderr_writer, shell_eval.mockDaemonDenyEvaluator);
    try std.testing.expectEqual(exit_codes.denial, code);

    const events = try readSessionEvents(std.testing.allocator, root, session_id);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_denied\"") != null);
}

test "shim callback accepts recorded builtin policy source" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "observe",
        .real_bin = "true",
        .shim_bin = "true",
        .policy_path = "builtin:strict",
        .record_builtin_policy = true,
    });
    defer fx.deinit();
    try std.testing.expect(try policyPathRecordedForSession(std.testing.io, std.testing.allocator, fx.root, fx.session_id, "builtin:strict"));

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{"true"}, &fx.env_map, &stderr_writer, shell_eval.mockDaemonAllowEvaluator);
    if (code != exit_codes.success) {
        std.debug.print("builtin policy shim stderr: {s}\n", .{stderr_writer.buffered()});
    }
    try std.testing.expectEqual(exit_codes.success, code);
}

test "shim ignores child ORCA_MODE softening when session mode is strict" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "strict",
        .real_bin = "git",
        .policy_path = "builtin:strict",
        .record_builtin_policy = true,
    });
    defer fx.deinit();

    // Child tries to soften enforcement — session shim_mode must win.
    try fx.env_map.put("ORCA_MODE", "observe");

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(
        std.testing.io,
        std.testing.allocator,
        &.{ "git", "push", "--force" },
        &fx.env_map,
        &stderr_writer,
        shell_eval.mockDaemonDenyHighEvaluator,
    );
    try std.testing.expectEqual(exit_codes.denial, code);
}

test "shim allow continues when audit open is control write-deny" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "observe",
        .real_bin = "true",
        .shim_bin = "true",
    });
    defer fx.deinit();

    // Simulate Seatbelt control write-deny: session audit is no longer writable.
    try makeSessionAuditNotWritable(fx.root, fx.session_id);

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{"true"}, &fx.env_map, &stderr_writer, shell_eval.mockDaemonAllowEvaluator);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "control write-deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "failed to open audit log") == null);
}

test "shim allow is silent when parent set ORCA_SHIM_AUDIT_MODE=degraded" {
    // E0: parent marks known-dead in-shim audit → no per-command stderr spam.
    // Parent must record session shim_audit_mode (env alone is child-forgable).
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "observe",
        .real_bin = "true",
        .shim_bin = "true",
    });
    defer fx.deinit();
    try makeSessionAuditNotWritable(fx.root, fx.session_id);
    try writeSessionShimAuditMode(std.testing.io, std.testing.allocator, fx.root, fx.session_id, "degraded");
    try fx.env_map.put(shim_audit_mode_env, "degraded");

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{"true"}, &fx.env_map, &stderr_writer, shell_eval.mockDaemonAllowEvaluator);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "control write-deny") == null);
}

test "shim ignores child-only ORCA_SHIM_AUDIT_MODE without session file" {
    // F36: agent export of degraded must not silence audit open failures.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "observe",
        .real_bin = "true",
        .shim_bin = "true",
    });
    defer fx.deinit();
    try makeSessionAuditNotWritable(fx.root, fx.session_id);
    try fx.env_map.put(shim_audit_mode_env, "degraded"); // child-only, no session file

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(std.testing.io, std.testing.allocator, &.{"true"}, &fx.env_map, &stderr_writer, shell_eval.mockDaemonAllowEvaluator);
    try std.testing.expectEqual(exit_codes.success, code);
    // Without parent session attestation, residual write-deny still warns.
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "control write-deny") != null);
}

test "shim deny still denies when ORCA_SHIM_AUDIT_MODE=degraded" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "strict",
        .real_bin = "rm",
        .real_script_body = "exit 42\n",
        .policy_path = "builtin:strict",
        .record_builtin_policy = true,
    });
    defer fx.deinit();
    try makeSessionAuditNotWritable(fx.root, fx.session_id);
    try writeSessionShimAuditMode(std.testing.io, std.testing.allocator, fx.root, fx.session_id, "degraded");
    try fx.env_map.put(shim_audit_mode_env, "degraded");

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(
        std.testing.io,
        std.testing.allocator,
        &.{ "rm", "-rf", "/" },
        &fx.env_map,
        &stderr_writer,
        shell_eval.mockDaemonDenyEvaluator,
    );
    try std.testing.expectEqual(exit_codes.denial, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "command denied") != null);
    // Degraded mode: no control write-deny spam on deny either
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "control write-deny") == null);
}

test "shim deny still denies when audit open is control write-deny" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fx = try prepareShimExecFixture(.{
        .mode = "strict",
        .real_bin = "rm",
        .real_script_body = "exit 42\n",
        .policy_path = "builtin:strict",
        .record_builtin_policy = true,
    });
    defer fx.deinit();

    try makeSessionAuditNotWritable(fx.root, fx.session_id);

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try execWithEnv(
        std.testing.io,
        std.testing.allocator,
        &.{ "rm", "-rf", "/" },
        &fx.env_map,
        &stderr_writer,
        shell_eval.mockDaemonDenyEvaluator,
    );
    try std.testing.expectEqual(exit_codes.denial, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "command denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "control write-deny") != null);
    // Must not surface as a bare "failed to open audit log" general failure.
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "failed to open audit log") == null);
}

test "isControlWriteDenyAuditError classifies access residuals only" {
    try std.testing.expect(isControlWriteDenyAuditError(error.PermissionDenied));
    try std.testing.expect(isControlWriteDenyAuditError(error.AccessDenied));
    try std.testing.expect(!isControlWriteDenyAuditError(error.FileNotFound));
    try std.testing.expect(!isControlWriteDenyAuditError(error.OutOfMemory));
}

test "shim fails closed on daemon evaluate failures" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const Case = struct {
        mode: []const u8,
        evaluator: shell_eval.ShellCommandEvaluatorFn,
        reason_sub: []const u8,
        /// When true, record a parent approval for the command before exec.
        with_parent_approval: bool = false,
    };
    const cases = [_]Case{
        .{ .mode = "strict", .evaluator = shell_eval.mockDaemonUnavailableEvaluator, .reason_sub = "daemon unavailable" },
        .{ .mode = "strict", .evaluator = shell_eval.mockDaemonProtocolMismatchEvaluator, .reason_sub = "daemon unavailable" },
        .{ .mode = "strict", .evaluator = shell_eval.mockDaemonErrorEvaluator, .reason_sub = "daemon evaluation error" },
        .{ .mode = "observe", .evaluator = shell_eval.mockDaemonUnavailableEvaluator, .reason_sub = "daemon unavailable" },
        // Product law: recorded parent approval must not override fail-closed Evaluate denials.
        .{
            .mode = "strict",
            .evaluator = shell_eval.mockDaemonUnavailableEvaluator,
            .reason_sub = "daemon unavailable",
            .with_parent_approval = true,
        },
        .{
            .mode = "strict",
            .evaluator = shell_eval.mockDaemonErrorEvaluator,
            .reason_sub = "daemon evaluation error",
            .with_parent_approval = true,
        },
    };

    for (cases) |case| {
        // Real binary would succeed if shim incorrectly delegated.
        var fx = try prepareShimExecFixture(.{ .mode = case.mode, .real_bin = "git" });
        defer fx.deinit();

        const argv = [_][]const u8{ "git", "status" };
        if (case.with_parent_approval) {
            const display = try intercept.commands.displayArgvAlloc(std.testing.allocator, &argv);
            defer std.testing.allocator.free(display);
            try recordShimApproval(std.testing.allocator, fx.root, fx.session_id, display);
            try intercept.commands.appendApprovalHashEnv(
                std.testing.allocator,
                &fx.env_map,
                intercept.commands.approved_once_env,
                display,
            );
        }

        var stderr_buf: [2048]u8 = undefined;
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
        const code = try execWithEnv(
            std.testing.io,
            std.testing.allocator,
            &argv,
            &fx.env_map,
            &stderr_writer,
            case.evaluator,
        );
        try std.testing.expectEqual(exit_codes.denial, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "command denied") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), case.reason_sub) != null);

        const events = try readSessionEvents(std.testing.allocator, fx.root, fx.session_id);
        defer std.testing.allocator.free(events);
        try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_denied\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"command_allowed\"") == null);
    }
}

const ShimFixtureOpts = struct {
    mode: []const u8 = "strict",
    real_bin: []const u8 = "git",
    real_script_body: []const u8 = "exit 0\n",
    /// When set, also write `shim/<name>` (PATH is shim_dir:real_dir so shim wins if present).
    shim_bin: ?[]const u8 = null,
    shim_script_body: []const u8 = "exit 9\n",
    policy_path: ?[]const u8 = null,
    record_builtin_policy: bool = false,
};

const ShimTestEnv = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    real_dir: []u8,
    shim_dir: []u8,
    session_id: []u8,
    path_value: []u8,
    env_map: std.process.Environ.Map,

    fn deinit(self: *ShimTestEnv) void {
        self.env_map.deinit();
        std.testing.allocator.free(self.path_value);
        std.testing.allocator.free(self.session_id);
        std.testing.allocator.free(self.shim_dir);
        std.testing.allocator.free(self.real_dir);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

fn prepareShimExecFixture(opts: ShimFixtureOpts) !ShimTestEnv {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try writeTestWorkspacePolicy(tmp.dir);

    const root = try testRealPath(std.testing.allocator, tmp.dir, ".");
    errdefer std.testing.allocator.free(root);

    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.createDirPath(std.testing.io, "shim");

    const real_path = try std.fmt.allocPrint(std.testing.allocator, "real/{s}", .{opts.real_bin});
    defer std.testing.allocator.free(real_path);
    try writeTestScript(tmp.dir, real_path, opts.real_script_body);

    if (opts.shim_bin) |shim_name| {
        const shim_path = try std.fmt.allocPrint(std.testing.allocator, "shim/{s}", .{shim_name});
        defer std.testing.allocator.free(shim_path);
        try writeTestScript(tmp.dir, shim_path, opts.shim_script_body);
    }

    const real_dir = try testRealPath(std.testing.allocator, tmp.dir, "real");
    errdefer std.testing.allocator.free(real_dir);
    const shim_dir = try testRealPath(std.testing.allocator, tmp.dir, "shim");
    errdefer std.testing.allocator.free(shim_dir);
    const session_id = try prepareShimSession(std.testing.allocator, root);
    errdefer std.testing.allocator.free(session_id);

    if (opts.record_builtin_policy) {
        try recordShimPolicyLoaded(std.testing.allocator, root, session_id, "builtin:strict");
    }

    // Parent session mode recording (same as ryk run installShims).
    const mode = policy.schema.Mode.parse(opts.mode) orelse .strict;
    try writeSessionShimMode(std.testing.io, std.testing.allocator, root, session_id, mode);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer env_map.deinit();
    const path_value = try std.fmt.allocPrint(std.testing.allocator, "{s}:{s}", .{ shim_dir, real_dir });
    errdefer std.testing.allocator.free(path_value);
    try env_map.put("PATH", path_value);
    try env_map.put("ORCA_SESSION_ID", session_id);
    try env_map.put("ORCA_WORKSPACE_ROOT", root);
    try env_map.put("ORCA_SHIM_DIR", shim_dir);
    try env_map.put("ORCA_MODE", opts.mode);
    if (opts.policy_path) |policy_path| {
        try env_map.put("ORCA_POLICY_PATH", policy_path);
    }

    return .{
        .tmp = tmp,
        .root = root,
        .real_dir = real_dir,
        .shim_dir = shim_dir,
        .session_id = session_id,
        .path_value = path_value,
        .env_map = env_map,
    };
}

fn testRealPath(allocator: std.mem.Allocator, dir: std.Io.Dir, subpath: []const u8) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(std.testing.io, subpath, &buffer);
    return try allocator.dupe(u8, buffer[0..n]);
}

fn writeTestWorkspacePolicy(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, ".orca");
    const file = try dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\version: 1
        \\mode: observe
    );
}

fn writeTestScript(dir: std.Io.Dir, path: []const u8, body: []const u8) !void {
    const file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\n");
    try file.writeStreamingAll(std.testing.io, body);
    try dir.setFilePermissions(std.testing.io, path, @enumFromInt(0o755), .{});
}

fn prepareShimSession(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const ts = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    const session: core.session.Session = .{
        .id = try core.session.generateSessionId(ts),
        .started_at = ts,
        .command = "true",
        .args = &.{},
        .workspace_root = root,
        .mode = .strict,
        .platform = core.platform.detectOs(),
    };
    var writer = try core_api.createAuditWriter(std.testing.io, allocator, session);
    defer writer.deinit();
    return try allocator.dupe(u8, session.id.slice());
}

fn recordShimApproval(allocator: std.mem.Allocator, root: []const u8, session_id: []const u8, display: []const u8) !void {
    var writer = try core_api.openAuditWriter(std.testing.io, allocator, root, session_id);
    defer writer.deinit();
    const decision: core.decision.Decision = .{
        .result = .allow,
        .reason = "user approved command once",
        .risk_score = 70,
        .ci_may_proceed = true,
    };
    try appendCommandEvent(std.testing.io, &writer, session_id, .user_approval, display, decision);
}

fn recordShimPolicyLoaded(allocator: std.mem.Allocator, root: []const u8, session_id_text: []const u8, policy_source: []const u8) !void {
    var writer = try core_api.openAuditWriter(std.testing.io, allocator, root, session_id_text);
    defer writer.deinit();
    var session_id: core.session.SessionId = .{ .value = undefined, .len = 0 };
    if (session_id_text.len > session_id.value.len) return error.InvalidSessionId;
    @memcpy(session_id.value[0..session_id_text.len], session_id_text);
    session_id.len = session_id_text.len;
    const ts = core.time.Timestamp.now(std.testing.io);
    const ev: core.event.Event = .{
        .session_id = session_id,
        .event_id = try core.event.generateEventId(ts),
        .timestamp = ts,
        .event_type = .policy_loaded,
        .actor = .{ .kind = .orca, .display = "ryk" },
        .target = .{ .kind = .file_path, .value = policy_source },
    };
    try core_api.appendAuditEvent(&writer, ev);
}

fn readSessionEvents(allocator: std.mem.Allocator, root: []const u8, session_id: []const u8) ![]u8 {
    const events_path = try std.fs.path.join(allocator, &.{ root, ".orca", "sessions", session_id, "events.jsonl" });
    defer allocator.free(events_path);
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, events_path, allocator, .limited(64 * 1024));
}

/// Drop write bits on the session events file so openExisting (O_RDWR) fails with
/// AccessDenied/PermissionDenied — same residual class as Seatbelt control write-deny.
fn makeSessionAuditNotWritable(root: []const u8, session_id: []const u8) !void {
    const events_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".orca", "sessions", session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    try std.Io.Dir.cwd().setFilePermissions(
        std.testing.io,
        events_path,
        std.Io.File.Permissions.fromMode(0o444),
        .{},
    );
}
