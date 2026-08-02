//! Agent-inference network allow — static core pack (§5.1) and host overlays (§5.2).
//!
//! Pure, FS-free tables + deterministic merge into `network.allow`. Launch seeding
//! (`applyNetworkOverlay`) is owned by s-ain-run-wire; this module only owns pack data
//! and merge. Normative SoT: planning/2026-08-02-agent-inference-network-allow-spec.md
//! (AINA-2026-08-02).
//!
//! Ownership contract for `mergeAllowList`:
//! - Returned outer slice is allocator-owned (free with `schema.freeStringList`).
//! - Every string entry is allocator-owned (duped from static pack/overlay and/or existing).
//! - Never removes entries present in `existing`; dedupes by exact string equality.
//! - Merge order: existing, then core pack, then optional host overlay (first wins).
//!
//! Do not invent cloud wildcards (no bare `*.amazonaws.com`) or paste sinks.

const std = @import("std");

const core = @import("../core/mod.zig");
const network_eval = @import("network_eval.zig");
const schema = @import("schema.zig");

// ---------------------------------------------------------------------------
// Static tables — FS-free product pack (spec §5.1 / §5.2)
// ---------------------------------------------------------------------------

/// Spec §5.1: always-on core inference hosts for mediated agent sessions.
const CORE_PACK = [_][]const u8{
    "api.anthropic.com",
    "api.openai.com",
    "api.x.ai",
};

/// Spec §5.2: grok launch overlay.
const OVERLAY_GROK = [_][]const u8{
    "cli-chat-proxy.grok.com",
    "auth.x.ai",
};

/// Spec §5.2: opencode launch overlay (exact hosts only at P1).
const OVERLAY_OPENCODE = [_][]const u8{
    "opencode.ai",
    "models.opencode.ai",
};

/// Spec §5.2: pi launch overlay (exact host only at P1).
const OVERLAY_PI = [_][]const u8{
    "openrouter.ai",
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Product-static core inference hosts (spec §5.1). Exact hostnames preferred.
/// Lifetime: static / process-long (borrowed; do not free).
pub fn corePack() []const []const u8 {
    return &CORE_PACK;
}

/// Host-key overlay hosts (spec §5.2). Unknown / core-only keys return empty.
/// Lifetime: static / process-long (borrowed; do not free).
pub fn overlayForHost(host_key: []const u8) []const []const u8 {
    if (std.mem.eql(u8, host_key, "grok")) return &OVERLAY_GROK;
    if (std.mem.eql(u8, host_key, "opencode")) return &OVERLAY_OPENCODE;
    if (std.mem.eql(u8, host_key, "pi")) return &OVERLAY_PI;
    // claude / codex / openclaw / hermes / unknown → core-only at P1.
    return &.{};
}

/// Merge `existing ∪ corePack ∪ overlayForHost(host_key?)` into a new allow list.
/// - Dedupes exact string matches (first occurrence wins).
/// - Never drops an entry that was present in `existing`.
/// - `host_key == null` → core pack only (no overlay).
/// Caller owns the result via `schema.freeStringList(allocator, result)`.
pub fn mergeAllowList(
    allocator: std.mem.Allocator,
    host_key: ?[]const u8,
    existing: []const []const u8,
) ![]const []const u8 {
    const overlay: []const []const u8 = if (host_key) |key| overlayForHost(key) else &.{};
    const pack = corePack();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |entry| allocator.free(entry);
        list.deinit(allocator);
    }

    // Deterministic order: existing → core → overlay; exact-string dedupe.
    try appendUniqueOwned(allocator, &list, existing);
    try appendUniqueOwned(allocator, &list, pack);
    try appendUniqueOwned(allocator, &list, overlay);

    return try list.toOwnedSlice(allocator);
}

fn listContainsExact(list: []const []const u8, needle: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn appendUniqueOwned(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    source: []const []const u8,
) !void {
    for (source) |entry| {
        if (listContainsExact(list.items, entry)) continue;
        const owned = try allocator.dupe(u8, entry);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn listContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn countExact(list: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (list) |entry| {
        if (std.mem.eql(u8, entry, needle)) n += 1;
    }
    return n;
}

/// §5.2 overlay minima that must not appear under core-only / null / unknown merge.
fn expectNoHostOverlays(list: []const []const u8) !void {
    try std.testing.expect(!listContains(list, "cli-chat-proxy.grok.com"));
    try std.testing.expect(!listContains(list, "auth.x.ai"));
    try std.testing.expect(!listContains(list, "models.opencode.ai"));
    try std.testing.expect(!listContains(list, "opencode.ai"));
    try std.testing.expect(!listContains(list, "openrouter.ai"));
}

/// Build a strict allowlist policy whose `network.allow` is a fully owned copy of `allow`.
/// Caller must `policy.network.deinit(allocator)` (not full Policy.deinit — workspace root is static).
fn allowlistPolicyWithAllow(allocator: std.mem.Allocator, allow: []const []const u8) !schema.Policy {
    var policy: schema.Policy = .{ .allocator = allocator, .mode = .strict };
    policy.network.mode = .allowlist;
    policy.network.allow = try schema.duplicateStringList(allocator, allow);
    return policy;
}

fn expectNetworkResult(
    allocator: std.mem.Allocator,
    policy: *const schema.Policy,
    destination: []const u8,
    want: core.decision.DecisionResult,
) !void {
    var decision = try network_eval.evaluate(allocator, policy, .strict, destination, .{});
    defer decision.deinit(allocator);
    try std.testing.expectEqual(want, decision.decision.result);
}

// ---------------------------------------------------------------------------
// Table / overlay content (A-P1 data)
// ---------------------------------------------------------------------------

test "agent_inference A-P1-1 corePack contains anthropic openai xai hosts" {
    const pack = corePack();
    try std.testing.expect(listContains(pack, "api.anthropic.com"));
    try std.testing.expect(listContains(pack, "api.openai.com"));
    try std.testing.expect(listContains(pack, "api.x.ai"));
}

test "agent_inference A-P1-4 grok overlay hosts are scoped to grok key" {
    const grok = overlayForHost("grok");
    try std.testing.expect(listContains(grok, "cli-chat-proxy.grok.com"));
    try std.testing.expect(listContains(grok, "auth.x.ai"));

    // Unrelated keys must not receive grok overlay entries.
    try std.testing.expect(!listContains(overlayForHost("pi"), "cli-chat-proxy.grok.com"));
    try std.testing.expect(!listContains(overlayForHost("opencode"), "cli-chat-proxy.grok.com"));
    try std.testing.expect(!listContains(overlayForHost("claude"), "cli-chat-proxy.grok.com"));
}

test "agent_inference A-P1-5 opencode overlay hosts are scoped to opencode key" {
    const oc = overlayForHost("opencode");
    try std.testing.expect(listContains(oc, "opencode.ai"));
    try std.testing.expect(listContains(oc, "models.opencode.ai"));

    try std.testing.expect(!listContains(overlayForHost("pi"), "models.opencode.ai"));
    try std.testing.expect(!listContains(overlayForHost("grok"), "models.opencode.ai"));
    try std.testing.expect(!listContains(overlayForHost("codex"), "opencode.ai"));
}

test "agent_inference A-P1-5 pi overlay hosts are scoped to pi key" {
    const pi = overlayForHost("pi");
    try std.testing.expect(listContains(pi, "openrouter.ai"));

    try std.testing.expect(!listContains(overlayForHost("grok"), "openrouter.ai"));
    try std.testing.expect(!listContains(overlayForHost("opencode"), "openrouter.ai"));
    try std.testing.expect(!listContains(overlayForHost("claude"), "openrouter.ai"));
}

test "agent_inference A-P1-4/5 core-only host keys have empty overlays at P1" {
    // claude / codex / openclaw / hermes: core pack only (no cross-host pollution).
    const core_only = [_][]const u8{ "claude", "codex", "openclaw", "hermes" };
    for (core_only) |key| {
        try std.testing.expectEqual(@as(usize, 0), overlayForHost(key).len);
    }
    // Unknown key also empty (fail-closed to core-only when host_key is odd).
    try std.testing.expectEqual(@as(usize, 0), overlayForHost("not-a-host-alias").len);
    try std.testing.expectEqual(@as(usize, 0), overlayForHost("").len);
}

// ---------------------------------------------------------------------------
// Pure merge (A-P1-6 data + dedupe / stale / null key)
// ---------------------------------------------------------------------------

test "agent_inference A-P1-6 merge into empty allow yields core pack" {
    const allocator = std.testing.allocator;
    // host_key == null → core pack only (no §5.2 overlay).
    const merged = try mergeAllowList(allocator, null, &.{});
    defer schema.freeStringList(allocator, merged);

    try std.testing.expect(listContains(merged, "api.anthropic.com"));
    try std.testing.expect(listContains(merged, "api.openai.com"));
    try std.testing.expect(listContains(merged, "api.x.ai"));
    // Contract: null key must not inject any host overlay (hollow "union all overlays" fails here).
    try expectNoHostOverlays(merged);
}

test "agent_inference A-P1-6 merge into stale github-only allow keeps existing and adds pack" {
    const allocator = std.testing.allocator;
    // Stale workspace fixture: package/git hosts only (common post-init policy).
    const stale = [_][]const u8{ "api.github.com", "registry.npmjs.org" };
    const merged = try mergeAllowList(allocator, null, &stale);
    defer schema.freeStringList(allocator, merged);

    // Existing entries preserved.
    try std.testing.expect(listContains(merged, "api.github.com"));
    try std.testing.expect(listContains(merged, "registry.npmjs.org"));
    // Core pack added.
    try std.testing.expect(listContains(merged, "api.anthropic.com"));
    try std.testing.expect(listContains(merged, "api.openai.com"));
    try std.testing.expect(listContains(merged, "api.x.ai"));
    // Null key: core-only; overlays must not appear on pure-merge seed path.
    try expectNoHostOverlays(merged);
}

test "agent_inference A-P1-4 merge for grok adds overlay without dropping stale allows" {
    const allocator = std.testing.allocator;
    const stale = [_][]const u8{"api.github.com"};
    const merged = try mergeAllowList(allocator, "grok", &stale);
    defer schema.freeStringList(allocator, merged);

    try std.testing.expect(listContains(merged, "api.github.com"));
    try std.testing.expect(listContains(merged, "api.anthropic.com"));
    try std.testing.expect(listContains(merged, "cli-chat-proxy.grok.com"));
    try std.testing.expect(listContains(merged, "auth.x.ai"));
    // opencode/pi overlays must not leak into grok merge.
    try std.testing.expect(!listContains(merged, "models.opencode.ai"));
    try std.testing.expect(!listContains(merged, "openrouter.ai"));
}

test "agent_inference A-P1-5 merge for opencode and pi adds only that host overlay" {
    const allocator = std.testing.allocator;

    const for_oc = try mergeAllowList(allocator, "opencode", &.{});
    defer schema.freeStringList(allocator, for_oc);
    try std.testing.expect(listContains(for_oc, "opencode.ai"));
    try std.testing.expect(listContains(for_oc, "models.opencode.ai"));
    try std.testing.expect(listContains(for_oc, "api.openai.com")); // core
    try std.testing.expect(!listContains(for_oc, "cli-chat-proxy.grok.com"));
    try std.testing.expect(!listContains(for_oc, "openrouter.ai"));

    const for_pi = try mergeAllowList(allocator, "pi", &.{});
    defer schema.freeStringList(allocator, for_pi);
    try std.testing.expect(listContains(for_pi, "openrouter.ai"));
    try std.testing.expect(listContains(for_pi, "api.x.ai")); // core
    try std.testing.expect(!listContains(for_pi, "models.opencode.ai"));
    try std.testing.expect(!listContains(for_pi, "cli-chat-proxy.grok.com"));
}

test "agent_inference merge for core-only host keys does not add foreign overlays" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "claude", "codex", "openclaw", "hermes" }) |key| {
        const merged = try mergeAllowList(allocator, key, &.{"api.github.com"});
        defer schema.freeStringList(allocator, merged);
        try std.testing.expect(listContains(merged, "api.github.com"));
        try std.testing.expect(listContains(merged, "api.anthropic.com"));
        try expectNoHostOverlays(merged);
    }
}

test "agent_inference merge for unknown host_key is core-only (no overlay)" {
    const allocator = std.testing.allocator;
    // Unknown keys must match core-only shape: existing ∪ core, no §5.2 overlay.
    const merged = try mergeAllowList(allocator, "not-a-host-alias", &.{"api.github.com"});
    defer schema.freeStringList(allocator, merged);

    try std.testing.expect(listContains(merged, "api.github.com"));
    try std.testing.expect(listContains(merged, "api.anthropic.com"));
    try std.testing.expect(listContains(merged, "api.openai.com"));
    try std.testing.expect(listContains(merged, "api.x.ai"));
    try expectNoHostOverlays(merged);
}

test "agent_inference mergeAllowList dedupes exact hosts already present in existing" {
    const allocator = std.testing.allocator;
    // Stale list already contains one core host and one that will also appear in overlay.
    const existing = [_][]const u8{ "api.openai.com", "auth.x.ai", "api.github.com" };
    const merged = try mergeAllowList(allocator, "grok", &existing);
    defer schema.freeStringList(allocator, merged);

    try std.testing.expectEqual(@as(usize, 1), countExact(merged, "api.openai.com"));
    try std.testing.expectEqual(@as(usize, 1), countExact(merged, "auth.x.ai"));
    try std.testing.expectEqual(@as(usize, 1), countExact(merged, "api.github.com"));
    try std.testing.expect(listContains(merged, "cli-chat-proxy.grok.com"));
}

// ---------------------------------------------------------------------------
// network_eval allow / deny on composed allow lists (A-P1-1, A-P1-2, A-P1-3)
// ---------------------------------------------------------------------------

test "agent_inference A-P1-1 core pack hosts evaluate allow under allowlist" {
    const allocator = std.testing.allocator;
    // Null key composition: core allow only — overlays must stay denied.
    const merged = try mergeAllowList(allocator, null, &.{});
    defer schema.freeStringList(allocator, merged);
    try expectNoHostOverlays(merged);

    var policy = try allowlistPolicyWithAllow(allocator, merged);
    defer policy.network.deinit(allocator);

    try expectNetworkResult(allocator, &policy, "https://api.anthropic.com/v1/messages", .allow);
    try expectNetworkResult(allocator, &policy, "https://api.openai.com/v1/chat/completions", .allow);
    try expectNetworkResult(allocator, &policy, "https://api.x.ai/v1/chat/completions", .allow);
    // Bare host form (proxy-style destination) also allows for all three core hosts.
    try expectNetworkResult(allocator, &policy, "api.anthropic.com", .allow);
    try expectNetworkResult(allocator, &policy, "api.openai.com", .allow);
    try expectNetworkResult(allocator, &policy, "api.x.ai", .allow);
    // Null merge must not seed overlay hosts into network.allow.
    try expectNetworkResult(allocator, &policy, "https://cli-chat-proxy.grok.com/", .deny);
    try expectNetworkResult(allocator, &policy, "https://models.opencode.ai/models", .deny);
    try expectNetworkResult(allocator, &policy, "https://openrouter.ai/api/v1", .deny);
}

test "agent_inference A-P1-2 pastebin.com evaluates deny when not on allow" {
    const allocator = std.testing.allocator;
    const merged = try mergeAllowList(allocator, "opencode", &.{});
    defer schema.freeStringList(allocator, merged);

    var policy = try allowlistPolicyWithAllow(allocator, merged);
    defer policy.network.deinit(allocator);

    try expectNetworkResult(allocator, &policy, "https://pastebin.com/raw/abc", .deny);
    try expectNetworkResult(allocator, &policy, "pastebin.com", .deny);
}

test "agent_inference A-P1-2 pastebin deny fixture beats allowlist miss and explicit deny" {
    const allocator = std.testing.allocator;
    // Explicit deny fixture (A-P1-2 "or fixture deny") plus core allow via merge.
    var policy: schema.Policy = .{ .allocator = allocator, .mode = .strict };
    defer policy.network.deinit(allocator);
    policy.network.mode = .allowlist;
    policy.network.deny = try schema.duplicateStringList(allocator, &.{ "pastebin.com", "*.pastebin.com" });
    const allow = try mergeAllowList(allocator, null, &.{});
    // freeStringList ownership transfers into policy.network.allow (network.deinit frees it).
    policy.network.allow = allow;
    try expectNoHostOverlays(allow);

    try expectNetworkResult(allocator, &policy, "https://pastebin.com/x", .deny);
    // Core still allows.
    try expectNetworkResult(allocator, &policy, "api.openai.com", .allow);
    // Null merge: overlay host remains denied.
    try expectNetworkResult(allocator, &policy, "https://cli-chat-proxy.grok.com/", .deny);
}

test "agent_inference A-P1-3 unknown public host example.com evaluates deny when not on allow" {
    const allocator = std.testing.allocator;
    const merged = try mergeAllowList(allocator, "pi", &.{"api.github.com"});
    defer schema.freeStringList(allocator, merged);

    var policy = try allowlistPolicyWithAllow(allocator, merged);
    defer policy.network.deinit(allocator);

    try expectNetworkResult(allocator, &policy, "https://example.com/", .deny);
    try expectNetworkResult(allocator, &policy, "example.com", .deny);
    try expectNetworkResult(allocator, &policy, "https://evil.example.net/hook", .deny);
}

test "agent_inference A-P1-4 grok overlay hosts evaluate allow; foreign overlay host denies" {
    const allocator = std.testing.allocator;
    const merged = try mergeAllowList(allocator, "grok", &.{});
    defer schema.freeStringList(allocator, merged);

    var policy = try allowlistPolicyWithAllow(allocator, merged);
    defer policy.network.deinit(allocator);

    try expectNetworkResult(allocator, &policy, "https://cli-chat-proxy.grok.com/", .allow);
    try expectNetworkResult(allocator, &policy, "https://auth.x.ai/oauth", .allow);
    // opencode overlay host must not be allowed under grok-only merge.
    try expectNetworkResult(allocator, &policy, "https://models.opencode.ai/models", .deny);
}

test "agent_inference A-P1-5 opencode and pi overlay hosts evaluate allow under their merge" {
    const allocator = std.testing.allocator;

    {
        const merged = try mergeAllowList(allocator, "opencode", &.{});
        defer schema.freeStringList(allocator, merged);
        var policy = try allowlistPolicyWithAllow(allocator, merged);
        defer policy.network.deinit(allocator);
        try expectNetworkResult(allocator, &policy, "https://models.opencode.ai/api", .allow);
        try expectNetworkResult(allocator, &policy, "https://opencode.ai/", .allow);
        try expectNetworkResult(allocator, &policy, "https://openrouter.ai/api/v1", .deny);
    }
    {
        const merged = try mergeAllowList(allocator, "pi", &.{});
        defer schema.freeStringList(allocator, merged);
        var policy = try allowlistPolicyWithAllow(allocator, merged);
        defer policy.network.deinit(allocator);
        try expectNetworkResult(allocator, &policy, "https://openrouter.ai/api/v1/chat", .allow);
        try expectNetworkResult(allocator, &policy, "https://models.opencode.ai/api", .deny);
    }
}

test "agent_inference A-P1-6 stale github-only policy allows pack after pure merge" {
    const allocator = std.testing.allocator;
    // Simulate workspace policy that only allowed package hosts (stale YAML).
    const stale = [_][]const u8{ "api.github.com", "pypi.org" };
    const merged = try mergeAllowList(allocator, "claude", &stale);
    defer schema.freeStringList(allocator, merged);

    var policy = try allowlistPolicyWithAllow(allocator, merged);
    defer policy.network.deinit(allocator);

    try expectNetworkResult(allocator, &policy, "api.github.com", .allow);
    try expectNetworkResult(allocator, &policy, "pypi.org", .allow);
    try expectNetworkResult(allocator, &policy, "api.anthropic.com", .allow);
    try expectNetworkResult(allocator, &policy, "api.openai.com", .allow);
    try expectNetworkResult(allocator, &policy, "api.x.ai", .allow);
    // Closed default retained for non-pack public hosts.
    try expectNetworkResult(allocator, &policy, "example.com", .deny);
    try expectNetworkResult(allocator, &policy, "pastebin.com", .deny);
}

test "agent_inference SEC: core pack does not include cloud wildcards or paste sinks" {
    const pack = corePack();
    try std.testing.expect(!listContains(pack, "*.amazonaws.com"));
    try std.testing.expect(!listContains(pack, "pastebin.com"));
    try std.testing.expect(!listContains(pack, "example.com"));
    // Overlays also must not open cloud wildcards.
    for ([_][]const u8{ "grok", "opencode", "pi", "claude" }) |key| {
        try std.testing.expect(!listContains(overlayForHost(key), "*.amazonaws.com"));
    }
}
