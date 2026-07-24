const std = @import("std");

const core_api = @import("orca_core").api;
const core = @import("orca_core").core;
const env_util = @import("env_util.zig");
const presentation = @import("presentation/mod.zig");

pub const ParseIntegrityFailed = presentation.replay_event.ParseIntegrityFailed;

pub const PluginReadiness = struct {
    id: []const u8,
    label: []const u8,
    host_detected: bool,
    integration_present: bool,
};

pub fn writeMarkdown(io: std.Io, allocator: std.mem.Allocator, writer: anytype, workspace_root: []const u8, session: core_api.ReplaySession) !void {
    var redactions = try presentation.replay_event.summarizeRedactions(allocator, session, session.verified);
    defer redactions.deinit(allocator);
    const plugins = try pluginReadiness(io, allocator, workspace_root);

    const safe_command = try presentation.redact.redactOwned(allocator, session.command_display);
    defer allocator.free(safe_command);
    const safe_policy = try presentation.redact.redactOwned(allocator, session.policy);
    defer allocator.free(safe_policy);

    try writer.print("# ryk Safety Report: {s}\n\n", .{session.session_id});
    try writer.print("- Session id: `{s}`\n", .{session.session_id});
    try writer.print("- Command: `{s}`\n", .{safe_command});
    try writer.print("- Status: {s}\n", .{session.status_display});
    try writer.print("- Policy path: {s}\n", .{safe_policy});
    try writer.print("- Hash-chain verification: {s}\n", .{if (session.verified) "verified" else "failed or unavailable"});
    try writer.print("- Denied/prevented actions: {d}\n", .{session.events.len});
    try writer.print("- Redactions: {d}", .{redactions.count});
    if (redactions.labels.items.len > 0) {
        try writer.writeAll(" (");
        for (redactions.labels.items, 0..) |label, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.writeAll(label);
        }
        try writer.writeAll(")");
    }
    try writer.writeAll("\n\n");

    try writer.writeAll("## What ryk Prevented\n\n");
    if (session.events.len == 0) {
        try writer.writeAll("Orca did not record a denied action in this session.\n\n");
    } else {
        try writer.print("ryk prevented {d} action{s} from continuing because the active local policy denied them.\n\n", .{ session.events.len, if (session.events.len == 1) "" else "s" });
        const views = try presentation.replay_event.deniedActionViews(allocator, session);
        defer {
            for (views) |*view| view.deinit(allocator);
            allocator.free(views);
        }
        for (views) |view| {
            try writer.print("- `{s}` was blocked. Reason: {s}\n", .{ view.target, view.reason });
        }
        try writer.writeByte('\n');
    }

    try writer.writeAll("## Plugin Readiness\n\n");
    for (plugins) |plugin| {
        try writer.print("- {s}: host {s}, integration {s}\n", .{
            plugin.label,
            if (plugin.host_detected) "detected" else "not detected",
            if (plugin.integration_present) "present" else "missing",
        });
    }
}

pub fn writeJson(io: std.Io, allocator: std.mem.Allocator, writer: anytype, workspace_root: []const u8, session: core_api.ReplaySession) !void {
    var redactions = try presentation.replay_event.summarizeRedactions(allocator, session, session.verified);
    defer redactions.deinit(allocator);
    const plugins = try pluginReadiness(io, allocator, workspace_root);

    const safe_command = try presentation.redact.redactOwned(allocator, session.command_display);
    defer allocator.free(safe_command);
    const safe_policy = try presentation.redact.redactOwned(allocator, session.policy);
    defer allocator.free(safe_policy);

    try writer.writeByte('{');
    try writer.writeAll("\"session_id\":");
    try core.util.writeJsonString(writer, session.session_id);
    try writer.writeAll(",\"command\":");
    try core.util.writeJsonString(writer, safe_command);
    try writer.writeAll(",\"status\":");
    try core.util.writeJsonString(writer, session.status_display);
    try writer.writeAll(",\"policy_path\":");
    try core.util.writeJsonString(writer, safe_policy);
    try writer.print(",\"hash_chain_verified\":{},\"denied_count\":{d}", .{ session.verified, session.events.len });
    try writer.print(",\"redactions\":{{\"count\":{d},\"labels\":[", .{redactions.count});
    for (redactions.labels.items, 0..) |label, index| {
        if (index > 0) try writer.writeByte(',');
        try core.util.writeJsonString(writer, label);
    }
    try writer.writeAll("]},\"denied_actions\":[");
    const views = try presentation.replay_event.deniedActionViews(allocator, session);
    defer {
        for (views) |*view| view.deinit(allocator);
        allocator.free(views);
    }
    for (views, 0..) |view, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"event_type\":");
        try core.util.writeJsonString(writer, view.event_type);
        try writer.writeAll(",\"target\":");
        try core.util.writeJsonString(writer, view.target);
        try writer.writeAll(",\"reason\":");
        try core.util.writeJsonString(writer, view.reason);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"plugins\":[");
    for (plugins, 0..) |plugin, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try core.util.writeJsonString(writer, plugin.id);
        try writer.writeAll(",\"host_detected\":");
        try writer.writeAll(if (plugin.host_detected) "true" else "false");
        try writer.writeAll(",\"integration_present\":");
        try writer.writeAll(if (plugin.integration_present) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

pub fn pluginReadiness(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ![2]PluginReadiness {
    return .{
        .{
            .id = "openclaw",
            .label = "OpenClaw",
            .host_detected = try executableInPath(io, allocator, "openclaw"),
            .integration_present = try pathExists(io, allocator, workspace_root, "integrations/openclaw-plugin"),
        },
        .{
            .id = "hermes",
            .label = "Hermes",
            .host_detected = try executableInPath(io, allocator, "hermes"),
            .integration_present = try pathExists(io, allocator, workspace_root, "integrations/hermes-plugin"),
        },
    };
}

fn pathExists(io: std.Io, allocator: std.mem.Allocator, root: []const u8, rel: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ root, rel });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn executableInPath(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !bool {
    var env_map = env_util.createProcessMap(allocator) catch return false;
    defer env_map.deinit();
    const path_owned = env_util.getOwned(&env_map, allocator, "PATH") catch return false;
    const path = path_owned orelse return false;
    defer allocator.free(path);
    const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var parts = std.mem.splitScalar(u8, path, separator);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ part, name });
        defer allocator.free(candidate);
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return true else |_| {}
    }
    return false;
}

test "report markdown and json redact synthetic secrets in reason and target" {
    const allocator = std.testing.allocator;
    var session = try presentation.fixtures.syntheticSecretReplaySession(allocator, .{});
    defer session.deinit();

    var md: std.Io.Writer.Allocating = .init(allocator);
    defer md.deinit();
    try writeMarkdown(std.testing.io, allocator, &md.writer, "/tmp", session);
    const md_out = try md.toOwnedSlice();
    defer allocator.free(md_out);
    try std.testing.expect(std.mem.indexOf(u8, md_out, presentation.fixtures.synthetic_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, md_out, "[REDACTED]") != null);

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try writeJson(std.testing.io, allocator, &json.writer, "/tmp", session);
    const json_out = try json.toOwnedSlice();
    defer allocator.free(json_out);
    try std.testing.expect(std.mem.indexOf(u8, json_out, presentation.fixtures.synthetic_secret) == null);
}

test "report fails closed on unparseable event when verification claimed" {
    const allocator = std.testing.allocator;
    var session = try presentation.fixtures.syntheticSecretReplaySession(allocator, .{ .session_id = "zh2-parse", .verified = true });
    defer session.deinit();
    allocator.free(session.events[0].raw);
    session.events[0].raw = try allocator.dupe(u8, "{not-valid-json");

    var md: std.Io.Writer.Allocating = .init(allocator);
    defer md.deinit();
    try std.testing.expectError(error.ParseIntegrityFailed, writeMarkdown(std.testing.io, allocator, &md.writer, "/tmp", session));

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.testing.expectError(error.ParseIntegrityFailed, writeJson(std.testing.io, allocator, &json.writer, "/tmp", session));
}

test "report renders denied action and redaction summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const session_id = try @import("demo.zig").createBlockedActionSession(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);
    var replay = try core_api.loadReplay(std.testing.io, std.testing.allocator, root, .{ .session = "last", .only_denied = true, .verify = true });
    defer replay.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeMarkdown(std.testing.io, std.testing.allocator, &aw.writer, root, replay);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk Safety Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hash-chain verification: verified") != null);
}