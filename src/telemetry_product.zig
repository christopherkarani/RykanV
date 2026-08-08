const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("ryk_core").core;
const host_launch = @import("cli/host_launch.zig");

pub const activation_event_name = "ryk_activation";
pub const setup_completed_event_name = "ryk_setup_completed";
pub const setup_failed_event_name = "ryk_setup_failed";
pub const feedback_submitted_event_name = "ryk_feedback_submitted";
pub const update_completed_event_name = "ryk_update_completed";
pub const update_failed_event_name = "ryk_update_failed";
pub const schema_version: i64 = 1;

pub const Event = union(enum) {
    activation: struct { host: []const u8 },
    setup_completed: struct { mode: []const u8 },
    setup_failed: struct { mode: []const u8 },
    feedback_submitted: struct { category: []const u8 },
    update_completed: struct {
        channel: []const u8,
        from_version: []const u8,
        to_version: []const u8,
        verification: []const u8,
    },
    update_failed: struct { channel: []const u8, stage: []const u8 },
};

pub fn eventName(event: Event) []const u8 {
    return switch (event) {
        .activation => activation_event_name,
        .setup_completed => setup_completed_event_name,
        .setup_failed => setup_failed_event_name,
        .feedback_submitted => feedback_submitted_event_name,
        .update_completed => update_completed_event_name,
        .update_failed => update_failed_event_name,
    };
}

pub fn isActivation(event: Event) bool {
    return event == .activation;
}

pub fn sanitizeHost(value: ?[]const u8) []const u8 {
    const candidate = value orelse "none";
    const hosts = [_][]const u8{ "none", "all", "other", "pi", "cursor", "claude", "codex", "opencode", "openclaw", "hermes", "grok" };
    for (hosts) |host| if (std.mem.eql(u8, candidate, host)) return host;
    if (host_launch.isHostLaunchAlias(candidate)) return candidate;
    return "other";
}

pub fn sanitizeSetupMode(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "auto")) return "auto";
    return "interactive";
}

pub fn sanitizeFeedbackCategory(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "bug")) return "bug";
    if (std.mem.eql(u8, value, "false_positive")) return "false_positive";
    if (std.mem.eql(u8, value, "false_negative")) return "false_negative";
    if (std.mem.eql(u8, value, "missing_integration")) return "missing_integration";
    if (std.mem.eql(u8, value, "confusing")) return "confusing";
    return null;
}

pub fn sanitizeChannel(value: []const u8) []const u8 {
    const channels = [_][]const u8{ "curl_installer", "unknown", "homebrew", "npm", "scoop", "winget" };
    for (channels) |channel| if (std.mem.eql(u8, value, channel)) return channel;
    return "unknown";
}

pub fn sanitizeUpdateStage(value: []const u8) []const u8 {
    const stages = [_][]const u8{ "resolve", "parse", "compare", "channel", "confirmation", "installer", "verify" };
    for (stages) |stage| if (std.mem.eql(u8, value, stage)) return stage;
    return "installer";
}

pub fn sanitizeVerification(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "verified")) return "verified";
    return "unverified";
}

/// Keep update dimensions numeric and stable even when a caller supplies a
/// prerelease/build suffix. The suffix is intentionally not sent to PostHog.
pub fn canonicalVersion(value: []const u8, destination: *[32]u8) ?[]const u8 {
    const without_v = if (value.len > 0 and (value[0] == 'v' or value[0] == 'V')) value[1..] else value;
    const base_end = std.mem.indexOfAny(u8, without_v, "-+") orelse without_v.len;
    const base = without_v[0..base_end];
    var parts = std.mem.splitScalar(u8, base, '.');
    const major = parseVersionComponent(parts.next() orelse return null) orelse return null;
    const minor = parseVersionComponent(parts.next() orelse return null) orelse return null;
    const patch = parseVersionComponent(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return std.fmt.bufPrint(destination, "{d}.{d}.{d}", .{ major, minor, patch }) catch null;
}

pub fn valid(event: Event) bool {
    return switch (event) {
        .activation => |value| validHost(value.host),
        .setup_completed => |value| validSetupMode(value.mode),
        .setup_failed => |value| validSetupMode(value.mode),
        .feedback_submitted => |value| validFeedbackCategory(value.category),
        .update_completed => |value| validChannel(value.channel) and validVersionToken(value.from_version) and
            validVersionToken(value.to_version) and validVerification(value.verification),
        .update_failed => |value| validChannel(value.channel) and validUpdateStage(value.stage),
    };
}

pub fn parseArgs(args: []const []const u8) !Event {
    if (args.len < 1) return error.InvalidTelemetryProductEvent;
    const kind = args[0];
    if (std.mem.eql(u8, kind, "activation") and args.len == 2)
        return .{ .activation = .{ .host = args[1] } };
    if (std.mem.eql(u8, kind, "setup_completed") and args.len == 2)
        return .{ .setup_completed = .{ .mode = args[1] } };
    if (std.mem.eql(u8, kind, "setup_failed") and args.len == 2)
        return .{ .setup_failed = .{ .mode = args[1] } };
    if (std.mem.eql(u8, kind, "feedback_submitted") and args.len == 2)
        return .{ .feedback_submitted = .{ .category = args[1] } };
    if (std.mem.eql(u8, kind, "update_completed") and args.len == 5)
        return .{ .update_completed = .{
            .channel = args[1],
            .from_version = args[2],
            .to_version = args[3],
            .verification = args[4],
        } };
    if (std.mem.eql(u8, kind, "update_failed") and args.len == 3)
        return .{ .update_failed = .{ .channel = args[1], .stage = args[2] } };
    return error.InvalidTelemetryProductEvent;
}

pub fn argCount(kind: []const u8) ?usize {
    if (std.mem.eql(u8, kind, "activation") or std.mem.eql(u8, kind, "setup_completed") or
        std.mem.eql(u8, kind, "setup_failed") or std.mem.eql(u8, kind, "feedback_submitted")) return 2;
    if (std.mem.eql(u8, kind, "update_completed")) return 5;
    if (std.mem.eql(u8, kind, "update_failed")) return 3;
    return null;
}

pub fn appendBatchArgs(args: anytype, len: *usize, event: Event) void {
    args.*[len.*] = "--product";
    len.* += 1;
    args.*[len.*] = switch (event) {
        .activation => "activation",
        .setup_completed => "setup_completed",
        .setup_failed => "setup_failed",
        .feedback_submitted => "feedback_submitted",
        .update_completed => "update_completed",
        .update_failed => "update_failed",
    };
    len.* += 1;
    switch (event) {
        .activation => |value| args.*[len.*] = value.host,
        .setup_completed => |value| args.*[len.*] = value.mode,
        .setup_failed => |value| args.*[len.*] = value.mode,
        .feedback_submitted => |value| args.*[len.*] = value.category,
        .update_completed => |value| {
            args.*[len.*] = value.channel;
            len.* += 1;
            args.*[len.*] = value.from_version;
            len.* += 1;
            args.*[len.*] = value.to_version;
            len.* += 1;
            args.*[len.*] = value.verification;
        },
        .update_failed => |value| {
            args.*[len.*] = value.channel;
            len.* += 1;
            args.*[len.*] = value.stage;
        },
    }
    len.* += 1;
}

pub fn validQueuedEvent(value: std.json.Value) bool {
    if (value != .object) return false;
    const root = value.object;
    rejectUnknownKeys(root, &.{ "event", "properties" }) catch return false;
    const event_value = root.get("event") orelse return false;
    const properties_value = root.get("properties") orelse return false;
    if (event_value != .string or properties_value != .object) return false;
    if (!isProductEventName(event_value.string)) return false;
    return validProperties(event_value.string, properties_value.object);
}

fn validProperties(event: []const u8, properties: std.json.ObjectMap) bool {
    const allowed: []const []const u8 = if (std.mem.eql(u8, event, activation_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "host", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, setup_completed_event_name) or std.mem.eql(u8, event, setup_failed_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "mode", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, feedback_submitted_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "category", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, update_completed_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "channel", "from_version", "to_version", "verification", "product_version", "os", "arch", "occurred_at" }
    else
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "channel", "stage", "product_version", "os", "arch", "occurred_at" };
    rejectUnknownKeys(properties, allowed) catch return false;
    if (!validCommonProperties(properties)) return false;

    if (std.mem.eql(u8, event, activation_event_name)) {
        const host = properties.get("host") orelse return false;
        return host == .string and validHost(host.string);
    }
    if (std.mem.eql(u8, event, setup_completed_event_name) or std.mem.eql(u8, event, setup_failed_event_name)) {
        const mode = properties.get("mode") orelse return false;
        return mode == .string and validSetupMode(mode.string);
    }
    if (std.mem.eql(u8, event, feedback_submitted_event_name)) {
        const category = properties.get("category") orelse return false;
        return category == .string and validFeedbackCategory(category.string);
    }
    if (std.mem.eql(u8, event, update_completed_event_name)) {
        const channel = properties.get("channel") orelse return false;
        const from_version = properties.get("from_version") orelse return false;
        const to_version = properties.get("to_version") orelse return false;
        const verification = properties.get("verification") orelse return false;
        return channel == .string and validChannel(channel.string) and from_version == .string and
            validVersionToken(from_version.string) and to_version == .string and validVersionToken(to_version.string) and
            verification == .string and validVerification(verification.string);
    }
    const channel = properties.get("channel") orelse return false;
    const stage = properties.get("stage") orelse return false;
    return channel == .string and validChannel(channel.string) and stage == .string and validUpdateStage(stage.string);
}

fn validCommonProperties(properties: std.json.ObjectMap) bool {
    const distinct_id = properties.get("distinct_id") orelse return false;
    if (distinct_id != .string or !validInstallationId(distinct_id.string)) return false;
    const profile = properties.get("$process_person_profile") orelse return false;
    if (profile != .bool or profile.bool) return false;
    const ip = properties.get("$ip") orelse return false;
    if (ip != .integer or ip.integer != 0) return false;
    const version = properties.get("telemetry_schema_version") orelse return false;
    if (version != .integer or version.integer != schema_version) return false;
    const product_version = properties.get("product_version") orelse return false;
    if (product_version != .string or !validVersionToken(product_version.string)) return false;
    const os = properties.get("os") orelse return false;
    if (os != .string or !validOsName(os.string)) return false;
    const arch = properties.get("arch") orelse return false;
    if (arch != .string or !validArchName(arch.string)) return false;
    const occurred_at = properties.get("occurred_at") orelse return false;
    return occurred_at == .string and validTimestamp(occurred_at.string);
}

pub fn render(allocator: std.mem.Allocator, io: std.Io, installation_id: []const u8, event: Event) ![]u8 {
    if (!validInstallationId(installation_id) or !valid(event)) return error.InvalidTelemetryEvent;
    var timestamp_buf: [32]u8 = undefined;
    const occurred_at = try core.time.Timestamp.now(io).formatIso(&timestamp_buf);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"event\":");
    try core.util.writeJsonString(&out.writer, eventName(event));
    try out.writer.writeAll(",\"properties\":{\"distinct_id\":");
    try core.util.writeJsonString(&out.writer, installation_id);
    try out.writer.print(
        ",\"$process_person_profile\":false,\"$ip\":0,\"telemetry_schema_version\":{d}",
        .{schema_version},
    );
    switch (event) {
        .activation => |value| try writeJsonField(&out.writer, "host", value.host),
        .setup_completed => |value| try writeJsonField(&out.writer, "mode", value.mode),
        .setup_failed => |value| try writeJsonField(&out.writer, "mode", value.mode),
        .feedback_submitted => |value| try writeJsonField(&out.writer, "category", value.category),
        .update_completed => |value| {
            try writeJsonField(&out.writer, "channel", value.channel);
            try writeJsonField(&out.writer, "from_version", value.from_version);
            try writeJsonField(&out.writer, "to_version", value.to_version);
            try writeJsonField(&out.writer, "verification", value.verification);
        },
        .update_failed => |value| {
            try writeJsonField(&out.writer, "channel", value.channel);
            try writeJsonField(&out.writer, "stage", value.stage);
        },
    }
    try writeJsonField(&out.writer, "product_version", build_options.version);
    try writeJsonField(&out.writer, "os", osName());
    try writeJsonField(&out.writer, "arch", archName());
    try writeJsonField(&out.writer, "occurred_at", occurred_at);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try core.util.writeJsonString(writer, name);
    try writer.writeByte(':');
    try core.util.writeJsonString(writer, value);
}

fn isProductEventName(value: []const u8) bool {
    return std.mem.eql(u8, value, activation_event_name) or std.mem.eql(u8, value, setup_completed_event_name) or
        std.mem.eql(u8, value, setup_failed_event_name) or std.mem.eql(u8, value, feedback_submitted_event_name) or
        std.mem.eql(u8, value, update_completed_event_name) or std.mem.eql(u8, value, update_failed_event_name);
}

fn validHost(value: []const u8) bool {
    return std.mem.eql(u8, value, sanitizeHost(value));
}

fn validSetupMode(value: []const u8) bool {
    return std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "interactive");
}

fn validFeedbackCategory(value: []const u8) bool {
    return std.mem.eql(u8, value, "bug") or std.mem.eql(u8, value, "false_positive") or
        std.mem.eql(u8, value, "false_negative") or std.mem.eql(u8, value, "missing_integration") or
        std.mem.eql(u8, value, "confusing");
}

fn validChannel(value: []const u8) bool {
    return std.mem.eql(u8, value, "curl_installer") or std.mem.eql(u8, value, "unknown") or
        std.mem.eql(u8, value, "homebrew") or std.mem.eql(u8, value, "npm") or std.mem.eql(u8, value, "scoop") or
        std.mem.eql(u8, value, "winget");
}

fn validUpdateStage(value: []const u8) bool {
    return std.mem.eql(u8, value, "resolve") or std.mem.eql(u8, value, "parse") or
        std.mem.eql(u8, value, "compare") or std.mem.eql(u8, value, "channel") or
        std.mem.eql(u8, value, "confirmation") or std.mem.eql(u8, value, "installer") or
        std.mem.eql(u8, value, "verify");
}

fn validVerification(value: []const u8) bool {
    return std.mem.eql(u8, value, "verified") or std.mem.eql(u8, value, "unverified");
}

fn validInstallationId(value: []const u8) bool {
    if (value.len != 36 or !std.mem.startsWith(u8, value, "ryk_")) return false;
    for (value[4..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn validVersionToken(value: []const u8) bool {
    var canonical: [32]u8 = undefined;
    const normalized = canonicalVersion(value, &canonical) orelse return false;
    return std.mem.eql(u8, normalized, value);
}

fn parseVersionComponent(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

fn validTimestamp(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':' or value[19] != 'Z') return false;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13 or index == 16 or index == 19) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn validOsName(value: []const u8) bool {
    return std.mem.eql(u8, value, "macos") or std.mem.eql(u8, value, "linux") or
        std.mem.eql(u8, value, "windows") or std.mem.eql(u8, value, "other");
}

fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "other",
    };
}

fn validArchName(value: []const u8) bool {
    return std.mem.eql(u8, value, "aarch64") or std.mem.eql(u8, value, "x86_64") or
        std.mem.eql(u8, value, "x86") or std.mem.eql(u8, value, "arm") or std.mem.eql(u8, value, "other");
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "x86",
        .arm => "arm",
        else => "other",
    };
}

fn rejectUnknownKeys(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidTelemetryProductEvent;
    }
}

test "product events render fixed properties and reject payload data" {
    const event = try render(std.testing.allocator, std.testing.io, "ryk_0123456789abcdef0123456789abcdef", .{
        .feedback_submitted = .{ .category = "false_positive" },
    });
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "ryk_feedback_submitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "command_text") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event, .{});
    defer parsed.deinit();
    try std.testing.expect(validQueuedEvent(parsed.value));
}

test "product event parser only accepts fixed dimensions" {
    const feedback = try parseArgs(&.{ "feedback_submitted", "confusing" });
    try std.testing.expect(valid(feedback));
    const invalid_feedback = try parseArgs(&.{ "feedback_submitted", "free text" });
    try std.testing.expect(!valid(invalid_feedback));
    try std.testing.expectEqual(@as(?usize, 5), argCount("update_completed"));
    var canonical: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.2.3", canonicalVersion("1.2.3-sk_live_123", &canonical).?);
    try std.testing.expect(!valid(.{ .update_completed = .{
        .channel = "curl_installer",
        .from_version = "1.2.3-sk_live_123",
        .to_version = "1.2.4",
        .verification = "verified",
    } }));
}

test "all product event names render and validate" {
    const events = [_]Event{
        .{ .activation = .{ .host = "none" } },
        .{ .setup_completed = .{ .mode = "auto" } },
        .{ .setup_failed = .{ .mode = "interactive" } },
        .{ .feedback_submitted = .{ .category = "bug" } },
        .{ .update_completed = .{ .channel = "curl_installer", .from_version = "1.2.9", .to_version = "1.2.11", .verification = "verified" } },
        .{ .update_failed = .{ .channel = "curl_installer", .stage = "installer" } },
    };
    for (events) |event| {
        const body = try render(std.testing.allocator, std.testing.io, "ryk_0123456789abcdef0123456789abcdef", event);
        defer std.testing.allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, eventName(event)) != null);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
        defer parsed.deinit();
        try std.testing.expect(validQueuedEvent(parsed.value));
    }
}
