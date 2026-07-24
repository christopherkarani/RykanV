const std = @import("std");

const core = @import("orca_core").core;
const supervisor = core.supervisor;
const core_api = @import("orca_core").api;
const brand = @import("brand.zig");
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const tui = @import("../tui/mod.zig");
const suggestions = @import("suggestions.zig");

const ReplayCliOptions = struct {
    session: []const u8 = "last",
    json: bool = false,
    only_denied: bool = false,
    verify: bool = false,
    list: bool = false,
    /// Phase 7: opt-in alt-screen timeline view (`orca replay --tui`). Default
    /// stays linear (invariant #1: --json frozen). Rejected on non-TTY / --json.
    tui_view: bool = false,
    /// When true, a missing default `last` session lists sessions instead of erroring.
    fallback_to_list: bool = false,
};

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseOptions(io, argv, stdout, stderr) catch |err| switch (err) {
        error.HelpShown => return exit_codes.success,
        error.Usage => return exit_codes.usage,
        else => return err,
    };

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const workspace_root = supervisor.resolveWorkspaceRoot(io, allocator, null, ".") catch |err| {
        try stderr.print("orca replay: failed to resolve workspace: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer allocator.free(workspace_root);

    if (options.list) {
        return listSessions(io, allocator, workspace_root, stdout);
    }

    return replaySession(io, allocator, workspace_root, options, stdout, stderr);
}

fn replaySession(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    options: ReplayCliOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Phase 7: --tui preflight BEFORE session load. --tui is a human-only
    // alt-screen view: it must not combine with --json (frozen machine contract,
    // invariant #1) and must not enter the alt-screen on non-interactive output
    // (invariant #2). Reject up front so a missing session never masks the flag
    // conflict and we never load data we'll refuse to render.
    if (options.tui_view) {
        if (options.json) {
            try stderr.writeAll("orca replay: --tui cannot be combined with --json (machine output is frozen).\n");
            return exit_codes.usage;
        }
        if (!tui.theme.active(io, stdout).capability.hasColor()) {
            try stderr.writeAll("orca replay: --tui needs an interactive colour terminal. Drop --tui, or unset NO_COLOR / --no-rich.\n");
            return exit_codes.usage;
        }
    }

    var session = core_api.loadReplay(io, allocator, workspace_root, .{
        .session = options.session,
        .only_denied = options.only_denied,
        .verify = options.verify,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            if (options.fallback_to_list) {
                return listSessions(io, allocator, workspace_root, stdout);
            }
            try stderr.writeAll("orca replay: session not found.\n");
            return exit_codes.general;
        },
        error.HashVerificationFailed => {
            const session_dir_path = sessionDirPathForError(io, allocator, workspace_root, options.session) catch null;
            defer if (session_dir_path) |path| allocator.free(path);
            const verify_result = if (session_dir_path) |path| core_api.verifyReplay(io, allocator, path) catch null else null;
            if (verify_result) |result| {
                defer result.deinit(allocator);
                if (result.reason) |reason| try stderr.print("orca replay: hash verification failed: {s}\n", .{reason}) else try stderr.writeAll("orca replay: hash verification failed.\n");
            } else {
                try stderr.writeAll("orca replay: hash verification failed.\n");
            }
            return exit_codes.general;
        },
        else => {
            try stderr.print("orca replay: failed: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
    };
    defer session.deinit();

    if (options.json) {
        try core_api.writeReplayJson(stdout, session);
    } else if (options.tui_view) {
        const lines = try buildTimelineLinesForTui(allocator, session);
        defer freeTimelineLines(allocator, lines);
        try tui.live_view.run(io, stdout, "replay", lines, null, null);
    } else {
        try writeReplayHuman(io, allocator, stdout, session, options.verify);
    }
    return exit_codes.success;
}

/// Deny emphasis for human/TUI replay: mirrors audit `only_denied` semantics
/// (`*_denied` type suffix and/or decision result `deny`).
fn isDeniedEvent(event: core_api.ReplayEvent) bool {
    return event.isDenied();
}

const ReplayTimelineRow = struct {
    icon: []const u8,
    detail: []const u8,
    denied: bool,
};

fn writeReplayHuman(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    session: core_api.ReplaySession,
    show_verify: bool,
) !void {
    try tui.render.definitionList(io, stdout, &.{
        .{ .term = "Session", .description = session.session_id },
        .{ .term = "Command", .description = session.command_display },
        .{ .term = "Policy", .description = session.policy },
        .{ .term = "Status", .description = session.status_display },
    });
    try stdout.writeByte('\n');

    // Dominant summary when denials are present (demo gold: bare `orca replay`).
    var denied_count: usize = 0;
    for (session.events) |event| {
        if (isDeniedEvent(event)) denied_count += 1;
    }
    if (denied_count > 0) {
        var deny_body: std.ArrayList(u8) = .empty;
        defer deny_body.deinit(allocator);
        try deny_body.print(allocator, "{d} action(s) blocked:", .{denied_count});
        var listed: usize = 0;
        for (session.events) |event| {
            if (!isDeniedEvent(event)) continue;
            if (listed == 0) {
                try deny_body.print(allocator, " {s}", .{event.target_value});
            } else {
                try deny_body.print(allocator, " · {s}", .{event.target_value});
            }
            listed += 1;
        }
        try tui.render.callout(io, stdout, .danger, "Denied actions", deny_body.items);
        try stdout.writeByte('\n');
    }

    // Build grouped timeline rows (collapse runs of secret_redacted).
    const rows = try allocator.alloc(ReplayTimelineRow, session.events.len);
    defer allocator.free(rows);
    const owned_details = try allocator.alloc(?[]u8, session.events.len);
    defer allocator.free(owned_details);
    @memset(owned_details, null);
    defer for (owned_details) |detail| if (detail) |value| allocator.free(value);

    var timeline_len: usize = 0;
    var event_index: usize = 0;
    while (event_index < session.events.len) {
        const event = session.events[event_index];
        var group_len: usize = 1;
        if (std.mem.eql(u8, event.event_type, "secret_redacted")) {
            while (event_index + group_len < session.events.len and
                std.mem.eql(u8, session.events[event_index + group_len].event_type, "secret_redacted"))
            {
                group_len += 1;
            }
        }

        const detail = if (group_len > 1)
            try std.fmt.allocPrint(allocator, "{s} · {s} · {d} secret redactions · {s}", .{
                event.timestamp,
                event.event_type,
                group_len,
                event.target_value,
            })
        else
            try std.fmt.allocPrint(allocator, "{s} · {s} · {s}", .{
                event.timestamp,
                event.event_type,
                event.target_value,
            });
        owned_details[timeline_len] = detail;
        rows[timeline_len] = .{
            .icon = replayEventIcon(event.event_type),
            .detail = detail,
            .denied = isDeniedEvent(event),
        };
        timeline_len += 1;
        event_index += group_len;
    }

    // Custom timeline: denied rows use danger token + DENY badge so they dominate.
    try writeReplayTimeline(io, stdout, rows[0..timeline_len]);
    if (show_verify) {
        try stdout.writeByte('\n');
        try tui.render.callout(io, stdout, if (session.verified) .success else .warn, "Hash chain", if (session.verified) "verified" else "not verified");
    }
}

/// Render a timeline with deny rows visually dominant (danger paint + DENY badge).
/// Non-deny rows match `tui.render.timeline` plain-mode structure (`├ icon  detail`).
fn writeReplayTimeline(io: std.Io, stdout: anytype, rows: []const ReplayTimelineRow) !void {
    for (rows, 0..) |row, index| {
        try stdout.writeAll("  ");
        try tui.theme.paint(io, stdout, .muted, if (index + 1 == rows.len) "└" else "├");
        try stdout.writeAll(" ");
        if (row.denied) {
            try tui.theme.paintBold(io, stdout, .danger, row.icon);
            try stdout.writeAll(" ");
            try tui.render.badge(io, stdout, .deny);
            try stdout.writeAll("  ");
            if (row.detail.len > 0) try tui.theme.paint(io, stdout, .danger, row.detail);
        } else {
            try tui.theme.paintBold(io, stdout, .text_bright, row.icon);
            if (row.detail.len > 0) {
                try stdout.writeAll("  ");
                try tui.terminal_text.write(stdout, row.detail, .single_line);
            }
        }
        try stdout.writeAll("\n");
    }
}

fn replayEventIcon(event_type: []const u8) []const u8 {
    if (std.mem.endsWith(u8, event_type, "_allowed")) return "✓";
    if (std.mem.endsWith(u8, event_type, "_denied")) return "✗";
    if (std.mem.eql(u8, event_type, "secret_redacted")) return "⚠";
    if (std.mem.startsWith(u8, event_type, "session_")) return "ℹ";
    return "•";
}

/// Build the flat, pre-rendered lines for the `--tui` alt-screen timeline view.
/// Mirrors `writeReplayHuman`'s redaction-grouping (collapsing runs of
/// `secret_redacted`) so the scrollable view carries the same information as the
/// linear render. The caller owns the returned slice and each line; free with
/// `freeTimelineLines`. This path is isolated from `writeReplayHuman` so the
/// linear + --json byte contracts are untouched.
fn buildTimelineLinesForTui(allocator: std.mem.Allocator, session: core_api.ReplaySession) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    // Session header for context.
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "Session   {s}", .{session.session_id}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "Command   {s}", .{session.command_display}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "Policy    {s}", .{session.policy}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "Status    {s}", .{session.status_display}));
    try lines.append(allocator, try allocator.dupe(u8, ""));
    try lines.append(allocator, try allocator.dupe(u8, "Timeline"));

    var event_index: usize = 0;
    while (event_index < session.events.len) {
        const event = session.events[event_index];
        var group_len: usize = 1;
        if (std.mem.eql(u8, event.event_type, "secret_redacted")) {
            while (event_index + group_len < session.events.len and
                std.mem.eql(u8, session.events[event_index + group_len].event_type, "secret_redacted"))
            {
                group_len += 1;
            }
        }
        const icon = replayEventIcon(event.event_type);
        const denied = isDeniedEvent(event);
        const line = if (group_len > 1)
            try std.fmt.allocPrint(allocator, "{s}  {s} · {s} · {d} secret redactions · {s}", .{
                icon, event.timestamp, event.event_type, group_len, event.target_value,
            })
        else if (denied)
            // Prefix DENY so the alt-screen list keeps denials scannable without colour.
            try std.fmt.allocPrint(allocator, "{s} [DENY]  {s} · {s} · {s}", .{
                icon, event.timestamp, event.event_type, event.target_value,
            })
        else
            try std.fmt.allocPrint(allocator, "{s}  {s} · {s} · {s}", .{
                icon, event.timestamp, event.event_type, event.target_value,
            });
        try lines.append(allocator, line);
        event_index += group_len;
    }

    return try lines.toOwnedSlice(allocator);
}

fn freeTimelineLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

/// Friendly empty-state copy for bare `orca replay` / `--list` when nothing is recorded.
/// Points operators at Safe Launch (`start` + agent), never a raw FileNotFound dump.
const empty_sessions_hint =
    \\No sessions yet. Run `ryk start` then `ryk <agent>` (for example `ryk claude`) to create a protected session.
    \\
;

fn listSessions(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, stdout: anytype) !u8 {
    const sessions_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions" });
    defer allocator.free(sessions_dir);

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll(empty_sessions_hint);
            return exit_codes.success;
        },
        else => return err,
    };
    defer dir.close(io);

    try stdout.writeAll("SESSION ID\n");

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try stdout.print("{s}\n", .{entry.name});
        count += 1;
    }

    if (count == 0) {
        try stdout.writeAll("\n");
        try stdout.writeAll(empty_sessions_hint);
    } else {
        try stdout.print("\n{d} session(s) found.\n", .{count});
        try stdout.writeAll("Run `orca replay --session <id>` to view a session.\n");
    }

    return exit_codes.success;
}

fn parseOptions(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !ReplayCliOptions {
    var options: ReplayCliOptions = .{
        .fallback_to_list = argv.len == 0,
    };
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "replay");
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("orca replay: --session requires a session id or 'last'.\n");
                return error.Usage;
            }
            options.session = argv[index];
            options.fallback_to_list = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            options.fallback_to_list = false;
        } else if (std.mem.eql(u8, arg, "--verify")) {
            options.verify = true;
            options.fallback_to_list = false;
        } else if (std.mem.eql(u8, arg, "--only")) {
            index += 1;
            if (index >= argv.len or !std.mem.eql(u8, argv[index], "denied")) {
                try stderr.writeAll("orca replay: --only currently supports only 'denied'.\n");
                return error.Usage;
            }
            options.only_denied = true;
            options.fallback_to_list = false;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            // Phase 7: opt-in alt-screen timeline view. Linear output is the
            // default; --json stays frozen and cannot combine with --tui.
            options.tui_view = true;
            options.fallback_to_list = false;
        } else {
            try suggestions.writeUnknownOption(stderr, "ryk replay", arg, &.{ "--list", "--session", "--json", "--verify", "--only", "--tui", "--help", "-h" }, "replay");
            return error.Usage;
        }
    }
    return options;
}

fn sessionDirPathForError(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, requested: []const u8) ![]u8 {
    const session_id = if (std.mem.eql(u8, requested, "last")) blk: {
        const last_path = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "last" });
        defer allocator.free(last_path);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, last_path, allocator, .limited(core.limits.max_session_id_len + 2));
        defer allocator.free(text);
        break :blk try allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    } else try allocator.dupe(u8, requested);
    defer allocator.free(session_id);
    return try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "sessions", session_id });
}

test "replay rejects invalid --only value" {
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{ "--only", "allowed" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--only") != null);
}

test "replay --list prints sessions or friendly empty message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: observe\n");
    }
    try tmp.dir.createDirPath(std.testing.io, ".orca/sessions/session-a");
    try tmp.dir.createDirPath(std.testing.io, ".orca/sessions/session-b");

    const prev_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(prev_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, prev_cwd) catch {};

    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{"--list"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "session-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "session-b") != null);
}

test "replay with no args and no sessions shows friendly empty state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: observe\n");
    }

    const prev_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(prev_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, prev_cwd) catch {};

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const output = stdout_writer.buffered();
    // Friendly empty state — not a raw FileNotFound dump; points at Safe Launch.
    try std.testing.expect(std.mem.indexOf(u8, output, "No sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk start") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ryk <agent>") != null or std.mem.indexOf(u8, output, "agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "FileNotFound") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "replay with no args loads last session timeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayTimelineFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // Bare `orca replay` — no --session required; defaults to last.
    const code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
    const output = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, session_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3 secret redactions") != null);
}

test "replay human timeline emphasizes denied actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayDenyFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
    const output = stdout_writer.buffered();
    // Denied actions visually dominant: summary callout + DENY badge on the row.
    try std.testing.expect(std.mem.indexOf(u8, output, "Denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[DENY]") != null or std.mem.indexOf(u8, output, "DENY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rm -rf /") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command_denied") != null);
}

test "replay human timeline emphasizes network_connect_denied without command_denied" {
    // M-4: deny classifier must treat *_denied event types (not only command_denied).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayNetworkDenyFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
    const output = stdout_writer.buffered();
    // No command_denied in this fixture — DENY badge/callout must still appear.
    try std.testing.expect(std.mem.indexOf(u8, output, "command_denied") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "network_connect_denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[DENY]") != null or std.mem.indexOf(u8, output, "DENY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://exfil.example/steal") != null);
}

test "isDeniedFields mirrors audit only_denied semantics" {
    try std.testing.expect(core_api.isDeniedFields("command_denied", null));
    try std.testing.expect(core_api.isDeniedFields("network_connect_denied", null));
    try std.testing.expect(core_api.isDeniedFields("file_write_denied", null));
    try std.testing.expect(core_api.isDeniedFields("command_allowed", "deny"));
    try std.testing.expect(!core_api.isDeniedFields("command_allowed", "allow"));
    try std.testing.expect(!core_api.isDeniedFields("command_allowed", null));
    try std.testing.expect(!core_api.isDeniedFields("secret_redacted", null));
}

fn writeReplayTimelineFixture(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const now = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    var session_id: core.session.SessionId = .{ .value = undefined, .len = 0 };
    const session_id_text = try std.fmt.bufPrint(&session_id.value, "replay-timeline-fixture", .{});
    session_id.len = session_id_text.len;
    const session = core.session.Session{
        .id = session_id,
        .started_at = now,
        .ended_at = now,
        .command = "orca",
        .args = &.{ "run", "--", "echo", "ok" },
        .workspace_root = workspace_root,
        .session_name = "replay-timeline-test",
        .mode = .strict,
        .platform = core.platform.detectOs(),
    };
    var audit_writer = try core_api.createAuditWriter(io, allocator, session);
    defer audit_writer.deinit();

    for (0..3) |index| {
        var event_id: core.event.EventId = .{ .value = undefined, .len = 0 };
        const event_id_text = try std.fmt.bufPrint(&event_id.value, "redaction-{d}", .{index});
        event_id.len = event_id_text.len;
        const event = try core_api.createAuditEvent(.{
            .session_id = session.id,
            .event_id = event_id,
            .timestamp = now,
            .event_type = .secret_redacted,
            .actor = .{ .kind = .orca, .display = "orca" },
            .target = .{ .kind = .env_var, .value = "TOKEN\x1b[2J\nvalue" },
            .decision = null,
            .redactions = .{ .count = 1, .labels = &.{"TOKEN"} },
        });
        try core_api.appendAuditEvent(&audit_writer, event);
    }
    var allowed_id: core.event.EventId = .{ .value = undefined, .len = 0 };
    const allowed_id_text = try std.fmt.bufPrint(&allowed_id.value, "allowed", .{});
    allowed_id.len = allowed_id_text.len;
    const allowed = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = allowed_id,
        .timestamp = now,
        .event_type = .command_allowed,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .command, .value = "echo ok" },
        .decision = core_api.makeDecision(.{ .result = .allow, .reason = "allowed" }),
    });
    try core_api.appendAuditEvent(&audit_writer, allowed);
    try audit_writer.writeLastPointer();
    try core_api.writeAuditSummary(allocator, audit_writer.sessionDirPath(), .{
        .session = session,
        .status = .{ .exited = 0 },
        .event_count = audit_writer.event_count,
        .final_event_hash = audit_writer.finalHash() orelse "",
        .policy = ".orca/policy.yaml",
        .product_label = brand.product_display,
    });
    return allocator.dupe(u8, audit_writer.session_id.slice());
}

/// Session fixture with network_connect_denied only (no command_denied) for M-4 classifier.
fn writeReplayNetworkDenyFixture(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const now = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    var session_id: core.session.SessionId = .{ .value = undefined, .len = 0 };
    const session_id_text = try std.fmt.bufPrint(&session_id.value, "replay-network-deny-fixture", .{});
    session_id.len = session_id_text.len;
    const session = core.session.Session{
        .id = session_id,
        .started_at = now,
        .ended_at = now,
        .command = "orca",
        .args = &.{ "run", "--", "curl", "https://exfil.example/steal" },
        .workspace_root = workspace_root,
        .session_name = "replay-network-deny-test",
        .mode = .strict,
        .platform = core.platform.detectOs(),
    };
    var audit_writer = try core_api.createAuditWriter(io, allocator, session);
    defer audit_writer.deinit();

    var allowed_id: core.event.EventId = .{ .value = undefined, .len = 0 };
    const allowed_id_text = try std.fmt.bufPrint(&allowed_id.value, "allowed", .{});
    allowed_id.len = allowed_id_text.len;
    const allowed = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = allowed_id,
        .timestamp = now,
        .event_type = .command_allowed,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .command, .value = "curl https://exfil.example/steal" },
        .decision = core_api.makeDecision(.{ .result = .allow, .reason = "command allowed" }),
    });
    try core_api.appendAuditEvent(&audit_writer, allowed);

    var denied_id: core.event.EventId = .{ .value = undefined, .len = 0 };
    const denied_id_text = try std.fmt.bufPrint(&denied_id.value, "net-denied", .{});
    denied_id.len = denied_id_text.len;
    const denied = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = denied_id,
        .timestamp = now,
        .event_type = .network_connect_denied,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .network_endpoint, .value = "https://exfil.example/steal" },
        .decision = core_api.makeDecision(.{ .result = .deny, .reason = "network blocked by policy" }),
    });
    try core_api.appendAuditEvent(&audit_writer, denied);

    try audit_writer.writeLastPointer();
    try core_api.writeAuditSummary(allocator, audit_writer.sessionDirPath(), .{
        .session = session,
        .status = .{ .exited = 1 },
        .event_count = audit_writer.event_count,
        .final_event_hash = audit_writer.finalHash() orelse "",
        .policy = ".orca/policy.yaml",
        .product_label = brand.product_display,
    });
    return allocator.dupe(u8, audit_writer.session_id.slice());
}

/// Session fixture with one allowed and one denied command (for deny-emphasis tests).
fn writeReplayDenyFixture(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const now = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    var session_id: core.session.SessionId = .{ .value = undefined, .len = 0 };
    const session_id_text = try std.fmt.bufPrint(&session_id.value, "replay-deny-fixture", .{});
    session_id.len = session_id_text.len;
    const session = core.session.Session{
        .id = session_id,
        .started_at = now,
        .ended_at = now,
        .command = "orca",
        .args = &.{ "run", "--", "echo", "ok" },
        .workspace_root = workspace_root,
        .session_name = "replay-deny-test",
        .mode = .strict,
        .platform = core.platform.detectOs(),
    };
    var audit_writer = try core_api.createAuditWriter(io, allocator, session);
    defer audit_writer.deinit();

    var allowed_id: core.event.EventId = .{ .value = undefined, .len = 0 };
    const allowed_id_text = try std.fmt.bufPrint(&allowed_id.value, "allowed", .{});
    allowed_id.len = allowed_id_text.len;
    const allowed = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = allowed_id,
        .timestamp = now,
        .event_type = .command_allowed,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .command, .value = "echo ok" },
        .decision = core_api.makeDecision(.{ .result = .allow, .reason = "allowed" }),
    });
    try core_api.appendAuditEvent(&audit_writer, allowed);

    var denied_id: core.event.EventId = .{ .value = undefined, .len = 0 };
    const denied_id_text = try std.fmt.bufPrint(&denied_id.value, "denied", .{});
    denied_id.len = denied_id_text.len;
    const denied = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = denied_id,
        .timestamp = now,
        .event_type = .command_denied,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .command, .value = "rm -rf /" },
        .decision = core_api.makeDecision(.{ .result = .deny, .reason = "blocked by policy" }),
    });
    try core_api.appendAuditEvent(&audit_writer, denied);

    try audit_writer.writeLastPointer();
    try core_api.writeAuditSummary(allocator, audit_writer.sessionDirPath(), .{
        .session = session,
        .status = .{ .exited = 1 },
        .event_count = audit_writer.event_count,
        .final_event_hash = audit_writer.finalHash() orelse "",
        .policy = ".orca/policy.yaml",
        .product_label = brand.product_display,
    });
    return allocator.dupe(u8, audit_writer.session_id.slice());
}

test "replay human timeline collapses repeated redactions and json remains exact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayTimelineFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var human_stdout_buf: [4096]u8 = undefined;
    var human_stderr_buf: [512]u8 = undefined;
    var human_stdout: std.Io.Writer = .fixed(&human_stdout_buf);
    var human_stderr: std.Io.Writer = .fixed(&human_stderr_buf);
    const human_code = try command(std.testing.io, &.{ "--session", session_id }, &human_stdout, &human_stderr);

    try std.testing.expectEqual(exit_codes.success, human_code);
    try std.testing.expectEqualStrings("", human_stderr.buffered());
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "3 secret redactions") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, human_stdout.buffered(), "secret_redacted"));
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "├ ⚠") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "└ ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "TOKEN value") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, human_stdout.buffered(), "\nvalue") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, human_stdout.buffered(), 0x1b) == null);

    var actual_json_buf: [8192]u8 = undefined;
    var json_stderr_buf: [512]u8 = undefined;
    var actual_json: std.Io.Writer = .fixed(&actual_json_buf);
    var json_stderr: std.Io.Writer = .fixed(&json_stderr_buf);
    const json_code = try command(std.testing.io, &.{ "--session", session_id, "--json" }, &actual_json, &json_stderr);

    try std.testing.expectEqual(exit_codes.success, json_code);
    const expected_json =
        \\[{"version":1,"session_id":"replay-timeline-fixture","event_id":"redaction-0","timestamp":"2026-05-05T12:12:10Z","type":"secret_redacted","actor":{"kind":"orca","id":null,"display":"orca"},"target":{"kind":"env_var","value":"TOKEN\u001b[2J\nvalue"},"decision":null,"redactions":{"count":1,"labels":["TOKEN"]},"previous_hash":null,"event_hash":"29372432ed1651996bc928c2cc25c8ff157175ead9291b4068659b20c1f8d44d"},{"version":1,"session_id":"replay-timeline-fixture","event_id":"redaction-1","timestamp":"2026-05-05T12:12:10Z","type":"secret_redacted","actor":{"kind":"orca","id":null,"display":"orca"},"target":{"kind":"env_var","value":"TOKEN\u001b[2J\nvalue"},"decision":null,"redactions":{"count":1,"labels":["TOKEN"]},"previous_hash":"29372432ed1651996bc928c2cc25c8ff157175ead9291b4068659b20c1f8d44d","event_hash":"5eb6b50592a40e8bfa8ce1954c43200f268bc29b3e8bbd803ae3c689250b7174"},{"version":1,"session_id":"replay-timeline-fixture","event_id":"redaction-2","timestamp":"2026-05-05T12:12:10Z","type":"secret_redacted","actor":{"kind":"orca","id":null,"display":"orca"},"target":{"kind":"env_var","value":"TOKEN\u001b[2J\nvalue"},"decision":null,"redactions":{"count":1,"labels":["TOKEN"]},"previous_hash":"5eb6b50592a40e8bfa8ce1954c43200f268bc29b3e8bbd803ae3c689250b7174","event_hash":"21f702fdba304ea68cefd97047a832d036955a10228d71b12365182c1df47ff4"},{"version":1,"session_id":"replay-timeline-fixture","event_id":"allowed","timestamp":"2026-05-05T12:12:10Z","type":"command_allowed","actor":{"kind":"orca","id":null,"display":"orca"},"target":{"kind":"command","value":"echo ok"},"decision":{"result":"allow","rule_id":null,"reason":"allowed","risk_score":null,"requires_user":false,"ci_may_proceed":false},"redactions":{"count":0,"labels":[]},"previous_hash":"21f702fdba304ea68cefd97047a832d036955a10228d71b12365182c1df47ff4","event_hash":"4a05248fac600beccd0816b25c49895076e4af2a457bba92f85eecd9c8765667"}]
        \\
    ;
    try std.testing.expectEqualStrings(expected_json, actual_json.buffered());
    try std.testing.expectEqualStrings("", json_stderr.buffered());
}

// ---------------------------------------------------------------------------
// Phase 7 Task D: --tui alt-screen view (rejection contracts; the raw TTY loop
// is manual-verify per the prompt.zig:19 note). Linear + --json byte contracts
// must be unchanged when --tui is absent.
// ---------------------------------------------------------------------------

test "replay --tui is rejected on non-interactive output (no colour terminal)" {
    // Fixed-buffer stdout → theme.active() resolves to capability .none → the
    // alt-screen view must be rejected with a usage error, never entering the
    // alt-screen on a pipe/buffer (invariant: non-TTY → plain text).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayTimelineFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{ "--session", session_id, "--tui" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--tui") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "interactive") != null);
    // No alt-screen controls leaked onto the buffer.
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "\x1b[?1049") == null);
}

test "replay --tui cannot combine with --json" {
    // Phase 7: --tui+--json is rejected at preflight (before session load), so a
    // missing session never masks the flag conflict. No workspace/session needed.
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{ "--json", "--tui" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--tui") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--json") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "\x1b[?1049") == null);
}

test "replay linear timeline is unchanged when --tui is absent" {
    // Regression guard: the default (no --tui) human render must be byte-identical
    // to before the Phase 7 wiring (invariant #1: --json frozen; linear stable).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }
    const session_id = try writeReplayTimelineFixture(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{ "--session", session_id }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    // Same collapsed-redaction contract as the pre-Phase-7 timeline test.
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "3 secret redactions") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stdout_writer.buffered(), "secret_redacted"));
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "├ ⚠") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "└ ✓") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, stdout_writer.buffered(), 0x1b) == null);
}
