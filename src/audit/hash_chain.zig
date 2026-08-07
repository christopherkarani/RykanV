const std = @import("std");

const core = @import("../core/public.zig");
const redact_bridge = @import("redact_bridge.zig");

pub const hex_hash_len = 64;
pub const HashHex = [hex_hash_len]u8;

pub fn eventHash(previous_hash: ?[]const u8, canonical_event_without_hash: []const u8) HashHex {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (previous_hash) |hash| hasher.update(hash);
    hasher.update(canonical_event_without_hash);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn writeCanonicalEventWithoutHash(writer: anytype, ev: core.event.Event, previous_hash: ?[]const u8) !void {
    try writeEventFields(writer, ev, previous_hash, null);
}

pub fn writeEventJsonLine(writer: anytype, ev: core.event.Event, previous_hash: ?[]const u8, event_hash_value: []const u8) !void {
    try writeEventFields(writer, ev, previous_hash, event_hash_value);
    try writer.writeByte('\n');
}

fn writeEventFields(writer: anytype, ev: core.event.Event, previous_hash: ?[]const u8, event_hash_value: ?[]const u8) !void {
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try ev.timestamp.formatIso(&timestamp_buf);

    try writer.writeByte('{');
    try writer.print("\"version\":{d}", .{ev.schema_version});
    try writer.writeAll(",\"session_id\":");
    try core.util.writeJsonString(writer, ev.session_id.slice());
    try writer.writeAll(",\"event_id\":");
    try core.util.writeJsonString(writer, ev.event_id.slice());
    try writer.writeAll(",\"timestamp\":");
    try core.util.writeJsonString(writer, timestamp);
    try writer.writeAll(",\"type\":");
    try core.util.writeJsonString(writer, ev.event_type.toString());
    try writer.writeAll(",\"actor\":");
    try writeActor(writer, ev.actor);
    try writer.writeAll(",\"target\":");
    try writeTarget(writer, ev.target);
    try writer.writeAll(",\"decision\":");
    try writeDecision(writer, ev.decision);
    try writer.writeAll(",\"redactions\":");
    try writeRedactions(writer, ev.redactions);
    if (!ev.metadata.isEmpty()) {
        try writer.writeAll(",\"metadata\":");
        try writeMetadata(writer, ev.metadata);
    }
    try writer.writeAll(",\"previous_hash\":");
    try writeNullableRawString(writer, previous_hash);
    if (event_hash_value) |hash| {
        try writer.writeAll(",\"event_hash\":");
        try core.util.writeJsonString(writer, hash);
    }
    try writer.writeByte('}');
}

fn writeActor(writer: anytype, actor: core.types.Actor) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try core.util.writeJsonString(writer, @tagName(actor.kind));
    try writer.writeAll(",\"id\":");
    try writeNullableString(writer, actor.id);
    try writer.writeAll(",\"display\":");
    try writeNullableString(writer, actor.display);
    try writer.writeByte('}');
}

fn writeTarget(writer: anytype, target: core.types.Target) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try core.util.writeJsonString(writer, @tagName(target.kind));
    try writer.writeAll(",\"value\":");
    var redacted_buf: [256]u8 = undefined;
    try core.util.writeJsonString(writer, redact_bridge.redactTargetValueBounded(@tagName(target.kind), target.value, &redacted_buf));
    try writer.writeByte('}');
}

fn writeDecision(writer: anytype, maybe_decision: ?core.decision.Decision) !void {
    const decision = maybe_decision orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeByte('{');
    try writer.writeAll("\"result\":");
    try core.util.writeJsonString(writer, decision.result.toString());
    try writer.writeAll(",\"rule_id\":");
    try writeNullableString(writer, decision.rule_id);
    try writer.writeAll(",\"reason\":");
    var reason_buf: [256]u8 = undefined;
    try core.util.writeJsonString(writer, redact_bridge.redactStringBounded(decision.reason, &reason_buf));
    try writer.writeAll(",\"risk_score\":");
    if (decision.risk_score) |score| {
        try writer.print("{d}", .{score});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"requires_user\":{},\"ci_may_proceed\":{}", .{ decision.requires_user, decision.ci_may_proceed });
    try writer.writeByte('}');
}

fn writeRedactions(writer: anytype, redactions: core.event.RedactionSummary) !void {
    try writer.print("{{\"count\":{d},\"labels\":[", .{redactions.count});
    for (redactions.labels, 0..) |label, index| {
        if (index > 0) try writer.writeByte(',');
        var redacted_buf: [256]u8 = undefined;
        try core.util.writeJsonString(writer, redact_bridge.redactStringBounded(label, &redacted_buf));
    }
    try writer.writeAll("]}");
}

fn writeMetadata(writer: anytype, metadata: core.event.EventMetadata) !void {
    try writer.writeByte('{');
    var wrote_field = false;
    inline for (.{
        .{ "decision_source", metadata.decision_source },
        .{ "event_source", metadata.event_source },
        .{ "host", metadata.host },
        .{ "daemon_status", metadata.daemon_status },
        .{ "pack_id", metadata.pack_id },
        .{ "severity", metadata.severity },
        .{ "remediation", metadata.remediation },
    }) |field| {
        if (field[1]) |value| {
            if (wrote_field) try writer.writeByte(',');
            try writer.writeAll("\"");
            try writer.writeAll(field[0]);
            try writer.writeAll("\":");
            var redacted_buf: [512]u8 = undefined;
            try core.util.writeJsonString(writer, redact_bridge.redactStringBounded(value, &redacted_buf));
            wrote_field = true;
        }
    }
    try writer.writeByte('}');
}

fn writeNullableString(writer: anytype, value: ?[]const u8) !void {
    if (value) |string| {
        var redacted_buf: [256]u8 = undefined;
        try core.util.writeJsonString(writer, redact_bridge.redactStringBounded(string, &redacted_buf));
    } else {
        try writer.writeAll("null");
    }
}

fn writeNullableRawString(writer: anytype, value: ?[]const u8) !void {
    if (value) |string| {
        try core.util.writeJsonString(writer, string);
    } else {
        try writer.writeAll("null");
    }
}

pub fn canonicalEventAlloc(allocator: std.mem.Allocator, ev: core.event.Event, previous_hash: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeCanonicalEventWithoutHash(&out.writer, ev, previous_hash);
    return try out.toOwnedSlice();
}

test "event serialization is deterministic and excludes event_hash from hash input" {
    const ts = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    const sid = try core.session.generateSessionId(ts);
    var eid: core.event.EventId = .{ .value = undefined, .len = 0 };
    const eid_text = try std.fmt.bufPrint(&eid.value, "evt_000001", .{});
    eid.len = eid_text.len;
    const ev: core.event.Event = .{
        .session_id = sid,
        .event_id = eid,
        .timestamp = ts,
        .event_type = .process_launch,
        .actor = .{ .kind = .ryk, .display = "ryk" },
        .target = .{ .kind = .command, .value = "echo hello" },
    };

    const first = try canonicalEventAlloc(std.testing.allocator, ev, null);
    defer std.testing.allocator.free(first);
    const second = try canonicalEventAlloc(std.testing.allocator, ev, null);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "event_hash") == null);
    const hash = eventHash(null, first);
    try std.testing.expectEqual(@as(usize, hex_hash_len), hash.len);
}

test "redaction labels are redacted at the audit serialization boundary" {
    const ts = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    const sid = try core.session.generateSessionId(ts);
    var eid: core.event.EventId = .{ .value = undefined, .len = 0 };
    const eid_text = try std.fmt.bufPrint(&eid.value, "evt_000001", .{});
    eid.len = eid_text.len;
    const labels = [_][]const u8{"fake_secret_value"};
    const ev: core.event.Event = .{
        .session_id = sid,
        .event_id = eid,
        .timestamp = ts,
        .event_type = .secret_redacted,
        .actor = .{ .kind = .ryk, .display = "ryk" },
        .target = .{ .kind = .command, .value = "echo ok" },
        .redactions = .{ .count = 1, .labels = &labels },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEventJsonLine(&out.writer, ev, null, "abc");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "fake_secret_value") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[REDACTED:") != null);
}


test "sandbox_posture serializes posture hash and fs_scope without full profile" {
    const ts = core.time.Timestamp.fromUnixSeconds(1_777_983_130);
    const sid = try core.session.generateSessionId(ts);
    var eid: core.event.EventId = .{ .value = undefined, .len = 0 };
    const eid_text = try std.fmt.bufPrint(&eid.value, "evt_sandbox_posture", .{});
    eid.len = eid_text.len;
    const reason = "posture=active; profile_hash=abcd1234; fs_scope=workspace RW, system RO, no home";
    const ev: core.event.Event = .{
        .session_id = sid,
        .event_id = eid,
        .timestamp = ts,
        .event_type = .sandbox_posture,
        .actor = .{ .kind = .ryk, .display = "ryk" },
        .target = .{ .kind = .session, .value = "os_filesystem_sandbox" },
        .decision = .{
            .result = .observe,
            .reason = reason,
            .ci_may_proceed = true,
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeEventJsonLine(&out.writer, ev, null, "deadbeef");
    const line = out.written();
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"sandbox_posture\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "posture=active") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "profile_hash=abcd1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "fs_scope=workspace RW") != null);
    // Full profile / SBPL / landlock rule blobs must not appear.
    try std.testing.expect(std.mem.indexOf(u8, line, "(version 1)") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "allow default") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "LANDLOCK") == null);
}

// os_fs_deny remains a reserved EventType (see core/event.zig toString test).
// Dedicated hash_chain serialization coverage deferred until emission exists.
