const std = @import("std");

const brand = @import("cli/brand.zig");
const core_api = @import("orca_core").api;
const core = @import("orca_core").core;

pub fn createBlockedActionSession(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const now = core.time.Timestamp.now(io);
    var session = core.session.Session{
        .id = try core.session.generateSessionId(now),
        .started_at = now,
        .ended_at = now,
        .command = "orca",
        .args = &.{ "demo", "blocked-action" },
        .workspace_root = workspace_root,
        .session_name = "blocked-action-demo",
        .mode = .strict,
        .platform = core.platform.detectOs(),
    };
    var writer = try core_api.createAuditWriter(io, allocator, session);
    defer writer.deinit();
    const event = try core_api.createAuditEvent(.{
        .session_id = session.id,
        .event_id = try core.event.generateEventId(now),
        .timestamp = now,
        .event_type = .command_denied,
        .actor = .{ .kind = .orca, .display = "orca" },
        .target = .{ .kind = .command, .value = "rm -rf ./demo-fixture" },
        .decision = core_api.makeDecision(.{
            .result = .deny,
            .reason = "demo policy denied a destructive filesystem command before execution",
            .rule_id = "commands.deny",
            .risk_score = 95,
        }),
        .redactions = .{ .count = 1, .labels = &.{"demo-secret-value"} },
    });
    try core_api.appendAuditEvent(&writer, event);
    try writer.writeLastPointer();
    const final_hash = writer.finalHash() orelse "";
    try core_api.writeAuditSummary(allocator, writer.sessionDirPath(), .{
        .session = session,
        .status = .{ .exited = 1 },
        .event_count = writer.event_count,
        .final_event_hash = final_hash,
        .policy = ".orca/policy.yaml",
        .product_label = brand.product_display,
    });
    _ = &session;
    return try allocator.dupe(u8, writer.session_id.slice());
}

test "demo blocked action creates verifiable replay session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const session_id = try createBlockedActionSession(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(session_id);
    var replay = try core_api.loadReplay(std.testing.io, std.testing.allocator, root, .{ .session = "last", .only_denied = true, .verify = true });
    defer replay.deinit();
    try std.testing.expectEqualStrings(session_id, replay.session_id);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    try std.testing.expect(replay.verified);
}
