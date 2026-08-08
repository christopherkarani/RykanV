//! Built-in tool-name → effect catalog.
//! Deterministic, local tables (same style as shell_tools.zig).

const std = @import("std");
const ids = @import("ids.zig");

pub const Confidence = enum {
    high,
    medium,
    low,

    pub fn toString(self: Confidence) []const u8 {
        return @tagName(self);
    }
};

/// One classified effect for a tool call.
pub const EffectHit = struct {
    /// Stable effect id (points into `ids.known_ids` / catalog static strings).
    id: []const u8,
    confidence: Confidence,
    /// Static matcher label for explain/audit, e.g. `catalog.comms.message.exact:send_email`.
    matcher: []const u8,
};

const ExactEntry = struct {
    name: []const u8,
    effect_id: []const u8,
    matcher: []const u8,
};

const TokenEntry = struct {
    /// Substring matched against normalized tool name (ASCII case-insensitive).
    token: []const u8,
    effect_id: []const u8,
    matcher: []const u8,
};

/// Exact tool names (matched case-insensitively after separator normalization).
const exact_names = [_]ExactEntry{
    // comms.message
    .{ .name = "send_email", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:send_email" },
    .{ .name = "sendemail", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:sendemail" },
    .{ .name = "sendmail", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:sendmail" },
    .{ .name = "email_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:email_send" },
    .{ .name = "gmail_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:gmail_send" },
    .{ .name = "mailgun_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:mailgun_send" },
    .{ .name = "ses_send_email", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:ses_send_email" },
    .{ .name = "sendgrid_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:sendgrid_send" },
    .{ .name = "postmark_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:postmark_send" },
    .{ .name = "send_imessage", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:send_imessage" },
    .{ .name = "send_sms", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:send_sms" },
    .{ .name = "send_message", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:send_message" },
    .{ .name = "slack_post_message", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:slack_post_message" },
    .{ .name = "slack_send_message", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:slack_send_message" },
    .{ .name = "discord_send_message", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:discord_send_message" },
    .{ .name = "telegram_send_message", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:telegram_send_message" },
    .{ .name = "whatsapp_send", .effect_id = "comms.message", .matcher = "catalog.comms.message.exact:whatsapp_send" },
    // comms.publish
    .{ .name = "post_twitter", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:post_twitter" },
    .{ .name = "post_tweet", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:post_tweet" },
    .{ .name = "create_tweet", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:create_tweet" },
    .{ .name = "tweet", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:tweet" },
    .{ .name = "x_create_post", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:x_create_post" },
    .{ .name = "post_to_x", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:post_to_x" },
    .{ .name = "linkedin_post", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:linkedin_post" },
    .{ .name = "post_linkedin", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:post_linkedin" },
    .{ .name = "mastodon_post", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:mastodon_post" },
    .{ .name = "bluesky_post", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.exact:bluesky_post" },
    // money.transfer
    .{ .name = "stripe_charge", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.exact:stripe_charge" },
    .{ .name = "stripe_create_payment", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.exact:stripe_create_payment" },
    .{ .name = "send_payment", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.exact:send_payment" },
    .{ .name = "paypal_send", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.exact:paypal_send" },
    // identity.auth
    .{ .name = "create_pat", .effect_id = "identity.auth", .matcher = "catalog.identity.auth.exact:create_pat" },
    .{ .name = "create_access_token", .effect_id = "identity.auth", .matcher = "catalog.identity.auth.exact:create_access_token" },
    .{ .name = "oauth_authorize", .effect_id = "identity.auth", .matcher = "catalog.identity.auth.exact:oauth_authorize" },
    // device.control
    .{ .name = "home_assistant_call", .effect_id = "device.control", .matcher = "catalog.device.control.exact:home_assistant_call" },
    // surface-aligned host tools
    .{ .name = "bash", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:bash" },
    .{ .name = "shell", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:shell" },
    .{ .name = "sh", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:sh" },
    .{ .name = "zsh", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:zsh" },
    .{ .name = "exec", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:exec" },
    .{ .name = "terminal", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:terminal" },
    .{ .name = "run_shell_command", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:run_shell_command" },
    .{ .name = "run_terminal_cmd", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:run_terminal_cmd" },
    .{ .name = "powershell", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:powershell" },
    .{ .name = "pwsh", .effect_id = "shell.exec", .matcher = "catalog.shell.exec.exact:pwsh" },
    .{ .name = "read", .effect_id = "fs.read", .matcher = "catalog.fs.read.exact:read" },
    .{ .name = "read_file", .effect_id = "fs.read", .matcher = "catalog.fs.read.exact:read_file" },
    .{ .name = "write", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:write" },
    .{ .name = "write_file", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:write_file" },
    .{ .name = "edit", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:edit" },
    .{ .name = "file_write", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:file_write" },
    .{ .name = "file_edit", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:file_edit" },
    .{ .name = "create_file", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:create_file" },
    .{ .name = "apply", .effect_id = "fs.write", .matcher = "catalog.fs.write.exact:apply" },
    .{ .name = "web_fetch", .effect_id = "net.connect", .matcher = "catalog.net.connect.exact:web_fetch" },
    .{ .name = "web_search", .effect_id = "net.connect", .matcher = "catalog.net.connect.exact:web_search" },
    .{ .name = "http_request", .effect_id = "net.connect", .matcher = "catalog.net.connect.exact:http_request" },
    .{ .name = "fetch", .effect_id = "net.connect", .matcher = "catalog.net.connect.exact:fetch" },
};

/// Domain tokens that imply an effect when present in the tool name.
/// Prefer domain nouns over bare verbs to limit false positives (e.g. send_progress).
/// Short tokens (len <= 3) match whole segments only (split on `_`) to avoid `sms` in `asms…`.
const name_tokens = [_]TokenEntry{
    // comms.message domains
    .{ .token = "imessage", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:imessage" },
    .{ .token = "email", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:email" },
    .{ .token = "gmail", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:gmail" },
    .{ .token = "mailgun", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:mailgun" },
    .{ .token = "sendgrid", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:sendgrid" },
    .{ .token = "postmark", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:postmark" },
    .{ .token = "smtp", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:smtp" },
    .{ .token = "sms", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:sms" },
    .{ .token = "whatsapp", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:whatsapp" },
    .{ .token = "telegram", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:telegram" },
    .{ .token = "slack", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:slack" },
    .{ .token = "discord", .effect_id = "comms.message", .matcher = "catalog.comms.message.token:discord" },
    // comms.publish domains
    .{ .token = "twitter", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.token:twitter" },
    .{ .token = "tweet", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.token:tweet" },
    .{ .token = "linkedin", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.token:linkedin" },
    .{ .token = "mastodon", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.token:mastodon" },
    .{ .token = "bluesky", .effect_id = "comms.publish", .matcher = "catalog.comms.publish.token:bluesky" },
    // money
    .{ .token = "stripe", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.token:stripe" },
    .{ .token = "paypal", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.token:paypal" },
    .{ .token = "braintree", .effect_id = "money.transfer", .matcher = "catalog.money.transfer.token:braintree" },
};

/// Normalize tool names for comparison: lowercase ASCII and map `-` / `.` to `_`.
pub fn normalizeToolName(allocator: std.mem.Allocator, tool_name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, tool_name.len);
    errdefer allocator.free(out);
    for (tool_name, 0..) |byte, i| {
        const lower = std.ascii.toLower(byte);
        out[i] = if (lower == '-' or lower == '.') '_' else lower;
    }
    return out;
}

fn namesEqualNormalized(a: []const u8, b_normalized: []const u8) bool {
    if (a.len != b_normalized.len) return false;
    for (a, b_normalized) |ac, bc| {
        const al = if (ac == '-' or ac == '.') '_' else std.ascii.toLower(ac);
        if (al != bc) return false;
    }
    return true;
}

/// Token match used by catalog and user effect packs. Short tokens (len ≤ 3)
/// require a whole `_`-separated segment to limit false positives.
pub fn containsToken(normalized: []const u8, token: []const u8) bool {
    if (token.len == 0 or normalized.len < token.len) return false;
    // Short tokens (e.g. `sms`) require a whole `_`-separated segment to limit
    // false positives inside longer words. Longer domain nouns may be substrings.
    if (token.len <= 3) return hasSegment(normalized, token);
    return std.mem.indexOf(u8, normalized, token) != null;
}

fn hasSegment(normalized: []const u8, token: []const u8) bool {
    var rest = normalized;
    while (rest.len > 0) {
        const sep = std.mem.indexOfScalar(u8, rest, '_');
        const segment = if (sep) |i| rest[0..i] else rest;
        if (std.mem.eql(u8, segment, token)) return true;
        if (sep) |i| {
            rest = rest[i + 1 ..];
        } else break;
    }
    return false;
}

fn appendUniqueHit(allocator: std.mem.Allocator, hits: *std.ArrayList(EffectHit), hit: EffectHit) !void {
    for (hits.items) |existing| {
        if (std.mem.eql(u8, existing.id, hit.id)) return;
    }
    try hits.append(allocator, hit);
}

/// Classify a host/MCP tool name into zero or more effect hits.
/// Returned slice is owned by `allocator`. Matcher/id strings are static.
pub fn classifyToolName(allocator: std.mem.Allocator, tool_name: []const u8) ![]EffectHit {
    var hits: std.ArrayList(EffectHit) = .empty;
    errdefer hits.deinit(allocator);

    const trimmed = std.mem.trim(u8, tool_name, " \t\r\n");
    if (trimmed.len == 0) return try hits.toOwnedSlice(allocator);

    const normalized = try normalizeToolName(allocator, trimmed);
    defer allocator.free(normalized);

    // Strip common MCP / host prefixes: mcp__, server__tool, etc. → last segment bias
    const focus = focusName(normalized);

    for (exact_names) |entry| {
        if (namesEqualNormalized(entry.name, focus) or namesEqualNormalized(entry.name, normalized)) {
            try appendUniqueHit(allocator, &hits, .{
                .id = entry.effect_id,
                .confidence = .high,
                .matcher = entry.matcher,
            });
        }
    }

    for (name_tokens) |entry| {
        if (containsToken(focus, entry.token) or containsToken(normalized, entry.token)) {
            try appendUniqueHit(allocator, &hits, .{
                .id = entry.effect_id,
                .confidence = .high,
                .matcher = entry.matcher,
            });
        }
    }

    // Light unknown.external heuristic: name suggests outbound action but catalog missed.
    // Conservative — only when no hits and name has send_/post_ with no safe local prefix.
    if (hits.items.len == 0 and looksUnknownExternal(focus)) {
        try appendUniqueHit(allocator, &hits, .{
            .id = "unknown.external",
            .confidence = .low,
            .matcher = "catalog.unknown.external.heuristic",
        });
    }

    // Sanity: all emitted ids must be known
    for (hits.items) |hit| {
        std.debug.assert(ids.isKnownEffectId(hit.id));
    }

    return try hits.toOwnedSlice(allocator);
}

/// Last segment after `__` or `/` — host MCP names like `mcp__acme__send_email`.
pub fn focusName(normalized: []const u8) []const u8 {
    // Prefer last path segment after __ or /
    if (std.mem.lastIndexOf(u8, normalized, "__")) |idx| {
        return normalized[idx + 2 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, normalized, '/')) |idx| {
        return normalized[idx + 1 ..];
    }
    return normalized;
}

fn looksUnknownExternal(normalized: []const u8) bool {
    const prefixes = [_][]const u8{ "send_", "post_", "publish_", "broadcast_", "notify_external_" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, normalized, prefix)) return true;
    }
    // Common outbound aliases that lack a catalog domain token.
    const exact_aliases = [_][]const u8{ "sendmail", "mail", "mailx" };
    for (exact_aliases) |alias| {
        if (std.mem.eql(u8, normalized, alias)) return true;
    }
    const suffixes = [_][]const u8{ "_mail", "_email", "_sms", "_tweet" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, normalized, suffix)) return true;
    }
    return false;
}

test "catalog exact names map primary comms tools" {
    const cases = [_]struct { name: []const u8, effect: []const u8 }{
        .{ .name = "send_email", .effect = "comms.message" },
        .{ .name = "SendEmail", .effect = "comms.message" },
        .{ .name = "send-email", .effect = "comms.message" },
        .{ .name = "send_imessage", .effect = "comms.message" },
        .{ .name = "post_twitter", .effect = "comms.publish" },
        .{ .name = "tweet", .effect = "comms.publish" },
        .{ .name = "stripe_charge", .effect = "money.transfer" },
    };
    for (cases) |case| {
        const hits = try classifyToolName(std.testing.allocator, case.name);
        defer std.testing.allocator.free(hits);
        try std.testing.expect(hits.len >= 1);
        try std.testing.expectEqualStrings(case.effect, hits[0].id);
        try std.testing.expect(hits[0].confidence == .high);
    }
}

test "catalog tokens catch renames without exact list entries" {
    const hits = try classifyToolName(std.testing.allocator, "mcp_mail_email_helper");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);

    const pub_hits = try classifyToolName(std.testing.allocator, "company_twitter_poster");
    defer std.testing.allocator.free(pub_hits);
    try std.testing.expect(pub_hits.len >= 1);
    try std.testing.expectEqualStrings("comms.publish", pub_hits[0].id);
}

test "catalog does not tag ordinary coding tools as comms" {
    const names = [_][]const u8{ "Read", "Write", "Bash", "list_files", "get_status", "send_progress" };
    for (names) |name| {
        const hits = try classifyToolName(std.testing.allocator, name);
        defer std.testing.allocator.free(hits);
        for (hits) |hit| {
            try std.testing.expect(!std.mem.eql(u8, hit.id, "comms.message"));
            try std.testing.expect(!std.mem.eql(u8, hit.id, "comms.publish"));
        }
    }
}

test "surface tools get surface effects" {
    const bash = try classifyToolName(std.testing.allocator, "Bash");
    defer std.testing.allocator.free(bash);
    try std.testing.expect(bash.len == 1);
    try std.testing.expectEqualStrings("shell.exec", bash[0].id);

    const read = try classifyToolName(std.testing.allocator, "Read");
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("fs.read", read[0].id);
}

test "unknown send_ prefix yields unknown.external at low confidence" {
    const hits = try classifyToolName(std.testing.allocator, "send_widget_update");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len == 1);
    try std.testing.expectEqualStrings("unknown.external", hits[0].id);
    try std.testing.expect(hits[0].confidence == .low);
}

test "ESP and sendmail aliases classify as comms.message" {
    const cases = [_][]const u8{ "sendmail", "mailgun_send", "ses_send_email", "company_mailgun_helper" };
    for (cases) |name| {
        const hits = try classifyToolName(std.testing.allocator, name);
        defer std.testing.allocator.free(hits);
        try std.testing.expect(hits.len >= 1);
        try std.testing.expectEqualStrings("comms.message", hits[0].id);
    }
}

test "short sms token matches segments only" {
    const sms = try classifyToolName(std.testing.allocator, "provider_sms_send");
    defer std.testing.allocator.free(sms);
    try std.testing.expect(sms.len >= 1);
    try std.testing.expectEqualStrings("comms.message", sms[0].id);

    // `asms` must not match token `sms` as a raw substring.
    const not_sms = try classifyToolName(std.testing.allocator, "list_asms_status");
    defer std.testing.allocator.free(not_sms);
    for (not_sms) |hit| {
        try std.testing.expect(!std.mem.eql(u8, hit.id, "comms.message"));
    }
}

test "mcp-style prefixed tool names still classify" {
    const hits = try classifyToolName(std.testing.allocator, "mcp__messaging__send_email");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);
}

test "empty tool name yields no hits" {
    const hits = try classifyToolName(std.testing.allocator, "   ");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
