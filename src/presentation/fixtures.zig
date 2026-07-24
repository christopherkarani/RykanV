const std = @import("std");

const core_api = @import("orca_core").api;

pub const synthetic_secret = "sk-fakeSyntheticOpenAIKey1234567890";

pub const SessionOptions = struct {
    session_id: []const u8 = "zh2-test",
    verified: bool = false,
};

pub fn syntheticSecretReplaySession(allocator: std.mem.Allocator, options: SessionOptions) !core_api.ReplaySession {
    const raw = try std.fmt.allocPrint(
        allocator,
        \\{{"version":1,"session_id":"{s}","event_id":"e1","timestamp":"2026-01-01T00:00:00Z","type":"command_denied","actor":{{"kind":"orca","id":null,"display":"orca"}},"target":{{"kind":"command","value":"OPENAI_API_KEY={s}"}},"decision":{{"result":"deny","rule_id":"commands.deny","reason":"blocked token {s} in command","risk_score":90,"requires_user":false,"ci_may_proceed":false}},"redactions":{{"count":0,"labels":[]}},"previous_hash":null,"event_hash":"00"}}
    ,
        .{ options.session_id, synthetic_secret, synthetic_secret },
    );
    errdefer allocator.free(raw);

    var session = core_api.ReplaySession{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, options.session_id),
        .session_dir_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{options.session_id}),
        .command_display = try allocator.dupe(u8, "ryk run"),
        .policy = try allocator.dupe(u8, ".orca/policy.yaml"),
        .status_display = try allocator.dupe(u8, "exited 1"),
        .events = try allocator.alloc(core_api.ReplayEvent, 1),
        .verified = options.verified,
    };
    errdefer session.deinit();

    session.events[0] = .{
        .raw = raw,
        .timestamp = try allocator.dupe(u8, "2026-01-01T00:00:00Z"),
        .event_type = try allocator.dupe(u8, "command_denied"),
        .target_value = try std.fmt.allocPrint(allocator, "OPENAI_API_KEY={s}", .{synthetic_secret}),
        .decision_result = try allocator.dupe(u8, "deny"),
    };
    return session;
}

pub fn syntheticSecretReplayEvent(allocator: std.mem.Allocator) !core_api.ReplayEvent {
    var session = try syntheticSecretReplaySession(allocator, .{ .session_id = "zh2-dash" });
    defer session.deinit();
    return .{
        .raw = try allocator.dupe(u8, session.events[0].raw),
        .timestamp = try allocator.dupe(u8, session.events[0].timestamp),
        .event_type = try allocator.dupe(u8, session.events[0].event_type),
        .target_value = try allocator.dupe(u8, session.events[0].target_value),
        .decision_result = try allocator.dupe(u8, session.events[0].decision_result.?),
    };
}