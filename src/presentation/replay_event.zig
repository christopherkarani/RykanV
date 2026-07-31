const std = @import("std");

const audit_replay = @import("ryk_core").audit.replay;
const redact = @import("redact.zig");

pub const ParseIntegrityFailed = audit_replay.ParseIntegrityFailed;

pub const DeniedActionView = struct {
    event_type: []const u8,
    target: []u8,
    reason: []u8,

    pub fn deinit(self: *DeniedActionView, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const RedactionSummary = struct {
    count: usize = 0,
    labels: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *RedactionSummary, allocator: std.mem.Allocator) void {
        for (self.labels.items) |label| allocator.free(label);
        self.labels.deinit(allocator);
        self.* = undefined;
    }
};

pub fn summarizeRedactions(allocator: std.mem.Allocator, session: audit_replay.ReplaySession, require_integrity: bool) !RedactionSummary {
    var summary = RedactionSummary{};
    errdefer summary.deinit(allocator);
    for (session.events) |ev| {
        try accumulateRedactions(allocator, ev.raw, require_integrity, &summary);
    }
    return summary;
}

pub fn deniedActionViews(allocator: std.mem.Allocator, session: audit_replay.ReplaySession) ![]DeniedActionView {
    var views: std.ArrayList(DeniedActionView) = .empty;
    errdefer {
        for (views.items) |*view| view.deinit(allocator);
        views.deinit(allocator);
    }
    for (session.events) |ev| {
        try views.append(allocator, try deniedActionView(allocator, ev));
    }
    return try views.toOwnedSlice(allocator);
}

pub fn deniedActionView(allocator: std.mem.Allocator, ev: audit_replay.ReplayEvent) !DeniedActionView {
    const parsed = try parseEventObject(allocator, ev.raw, false);
    defer parsed.deinit();
    const reason_raw = try decisionReasonString(allocator, parsed.value);
    defer allocator.free(reason_raw);
    const reason = try redact.redactOwned(allocator, reason_raw);
    const target = try redact.redactOwned(allocator, ev.target_value);
    return .{
        .event_type = ev.event_type,
        .target = target,
        .reason = reason,
    };
}

fn accumulateRedactions(
    allocator: std.mem.Allocator,
    raw: []const u8,
    require_integrity: bool,
    summary: *RedactionSummary,
) !void {
    const parsed = try parseEventObject(allocator, raw, require_integrity);
    defer parsed.deinit();
    const object = parsed.value.object;

    const redactions = object.get("redactions") orelse {
        if (require_integrity) return error.ParseIntegrityFailed;
        return;
    };
    if (redactions != .object) {
        if (require_integrity) return error.ParseIntegrityFailed;
        return;
    }

    if (redactions.object.get("count")) |count_value| {
        if (count_value != .integer) {
            if (require_integrity) return error.ParseIntegrityFailed;
        } else if (count_value.integer > 0) {
            summary.count += @intCast(count_value.integer);
        }
    }

    const labels_value = redactions.object.get("labels") orelse {
        if (require_integrity) return error.ParseIntegrityFailed;
        return;
    };
    if (labels_value != .array) {
        if (require_integrity) return error.ParseIntegrityFailed;
        return;
    }

    for (labels_value.array.items) |label| {
        if (label != .string) {
            if (require_integrity) return error.ParseIntegrityFailed;
            continue;
        }
        if (try containsLabel(summary.labels.items, label.string)) continue;
        const safe_label = try redact.redactOwned(allocator, label.string);
        try summary.labels.append(allocator, safe_label);
    }
}

fn parseEventObject(allocator: std.mem.Allocator, raw: []const u8, require_integrity: bool) !std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        if (require_integrity) return error.ParseIntegrityFailed;
        return error.InvalidEvent;
    };
    if (parsed.value != .object) {
        parsed.deinit();
        if (require_integrity) return error.ParseIntegrityFailed;
        return error.InvalidEvent;
    }
    return parsed;
}

fn decisionReasonString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const fallback = "policy denied the action";
    if (value != .object) return allocator.dupe(u8, fallback);
    const decision = value.object.get("decision") orelse return allocator.dupe(u8, fallback);
    if (decision != .object) return allocator.dupe(u8, fallback);
    const reason = decision.object.get("reason") orelse return allocator.dupe(u8, fallback);
    if (reason != .string or reason.string.len == 0) return allocator.dupe(u8, fallback);
    return allocator.dupe(u8, reason.string);
}

fn containsLabel(labels: []const []u8, value: []const u8) !bool {
    for (labels) |label| {
        if (std.mem.eql(u8, label, value)) return true;
    }
    return false;
}

const InvalidEvent = error{InvalidEvent};

test "summarizeRedactions fails closed on malformed redactions when integrity required" {
    const allocator = std.testing.allocator;
    const fixtures = @import("fixtures.zig");
    var session = try fixtures.syntheticSecretReplaySession(allocator, .{ .verified = true });
    defer session.deinit();
    allocator.free(session.events[0].raw);
    session.events[0].raw = try std.fmt.allocPrint(
        allocator,
        \\{{"version":1,"session_id":"zh2-test","event_id":"e1","timestamp":"2026-01-01T00:00:00Z","type":"command_denied","actor":{{"kind":"ryk","id":null,"display":"ryk"}},"target":{{"kind":"command","value":"safe"}},"decision":{{"result":"deny","rule_id":"commands.deny","reason":"blocked","risk_score":90,"requires_user":false,"ci_may_proceed":false}},"redactions":"not-an-object","previous_hash":null,"event_hash":"00"}}
    ,
        .{},
    );

    try std.testing.expectError(error.ParseIntegrityFailed, summarizeRedactions(allocator, session, true));
}