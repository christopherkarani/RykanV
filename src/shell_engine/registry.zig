//! Oracle pack registry: embed all pack patterns and match via PCRE2.
const std = @import("std");
const regex_pcre = @import("regex_pcre.zig");
const Severity = @import("types.zig").Severity;

const packs_json = @embedFile("oracle_packs.json");

pub const Hit = struct {
    pack_id: []const u8,
    pattern_name: []const u8,
    severity: Severity,
    reason: []const u8,
};

const CompiledPattern = struct {
    name: []const u8,
    reason: []const u8,
    severity: Severity,
    regex: regex_pcre.Regex,
};

const CompiledPack = struct {
    id: []const u8,
    keywords: []const []const u8,
    safe: []CompiledPattern,
    destructive: []CompiledPattern,
    /// Whether this pack is active under the product default pack set
    /// (Rust `Config::default()`: category `core` + `system.disk`).
    default_enabled: bool,
};

var g_packs: []CompiledPack = &.{};
/// 0=uninit (or failed+reclaimed, retryable), 1=ok, 3=in-progress
var g_state: std.atomic.Value(u8) = .init(0);
var g_arena: std.heap.ArenaAllocator = undefined;

fn freePatternList(patterns: []CompiledPattern) void {
    for (patterns) |*p| {
        p.regex.deinit();
    }
}

fn freePackList(packs: []CompiledPack) void {
    for (packs) |*pack| {
        freePatternList(pack.safe);
        freePatternList(pack.destructive);
    }
}

/// Free C-heap regexes and the process arena after a failed or abandoned init.
fn reclaimRegistry() void {
    freePackList(g_packs);
    g_packs = &.{};
    g_arena.deinit();
    g_arena = undefined;
}

fn initOnce() !void {
    // Process-lifetime arena (not testing allocator — avoids leak noise).
    g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer reclaimRegistry();

    const a = g_arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, packs_json, .{});
    const root = parsed.value;
    if (root != .array) return error.BadPacksJson;

    var packs_list: std.ArrayList(CompiledPack) = .empty;
    errdefer {
        // C-heap regexes are not owned by the arena — free before arena teardown.
        freePackList(packs_list.items);
        packs_list.deinit(a);
    }

    for (root.array.items) |item| {
        const obj = item.object;
        const id = obj.get("id").?.string;
        if (std.mem.eql(u8, id, "test.deadline")) continue;

        const pack = try compilePack(a, obj, id);
        packs_list.append(a, pack) catch |err| {
            freePatternList(pack.safe);
            freePatternList(pack.destructive);
            return err;
        };
    }
    g_packs = try packs_list.toOwnedSlice(a);
    // Phase 1 hard fence: tier+lex order (not JSON alpha) for first-match attribution.
    // Do not rewrite oracle_packs.json — sort code-side after load.
    std.mem.sort(CompiledPack, g_packs, {}, packOrderLessThan);
}

fn compilePack(a: std.mem.Allocator, obj: std.json.ObjectMap, id: []const u8) !CompiledPack {
    var keywords: std.ArrayList([]const u8) = .empty;
    if (obj.get("keywords")) |kw| {
        if (kw == .array) {
            for (kw.array.items) |k| {
                try keywords.append(a, try a.dupe(u8, k.string));
            }
        }
    }

    const safe = try compileList(a, obj.get("safe"));
    errdefer freePatternList(safe);
    const destructive = try compileList(a, obj.get("destructive"));
    errdefer freePatternList(destructive);

    return .{
        .id = try a.dupe(u8, id),
        .keywords = try keywords.toOwnedSlice(a),
        .safe = safe,
        .destructive = destructive,
        .default_enabled = isDefaultEnabled(id),
    };
}

/// Rust default: always enable category `core` (all `core.*`) and `system.disk`.
fn isDefaultEnabled(id: []const u8) bool {
    if (std.mem.startsWith(u8, id, "core.")) return true;
    if (std.mem.eql(u8, id, "system.disk")) return true;
    return false;
}

/// Category → tier (lower = higher priority). Mirrors Rust
/// `PackRegistry::pack_tier` so first-match attribution matches
/// expand_enabled_ordered. Single source for packTier + unit test.
const pack_category_tiers = [_]struct { category: []const u8, tier: u8 }{
    .{ .category = "safe", .tier = 0 },
    .{ .category = "core", .tier = 1 },
    .{ .category = "storage", .tier = 1 },
    .{ .category = "remote", .tier = 1 },
    .{ .category = "system", .tier = 2 },
    .{ .category = "infrastructure", .tier = 3 },
    .{ .category = "apigateway", .tier = 4 },
    .{ .category = "cdn", .tier = 4 },
    .{ .category = "cloud", .tier = 4 },
    .{ .category = "dns", .tier = 4 },
    .{ .category = "loadbalancer", .tier = 4 },
    .{ .category = "platform", .tier = 4 },
    .{ .category = "kubernetes", .tier = 5 },
    .{ .category = "containers", .tier = 6 },
    .{ .category = "backup", .tier = 7 },
    .{ .category = "database", .tier = 7 },
    .{ .category = "messaging", .tier = 7 },
    .{ .category = "search", .tier = 7 },
    .{ .category = "package_managers", .tier = 8 },
    .{ .category = "strict_git", .tier = 9 },
    .{ .category = "cicd", .tier = 10 },
    .{ .category = "email", .tier = 10 },
    .{ .category = "featureflags", .tier = 10 },
    .{ .category = "secrets", .tier = 10 },
    .{ .category = "monitoring", .tier = 10 },
    .{ .category = "payment", .tier = 10 },
};
const pack_tier_unknown: u8 = 11;

/// Priority tier for a pack ID (lower = higher priority). Phase 1 hard fence
/// relies on this tier+lex registry order for stable rule_id attribution.
fn packTier(pack_id: []const u8) u8 {
    const category = if (std.mem.indexOfScalar(u8, pack_id, '.')) |dot|
        pack_id[0..dot]
    else
        pack_id;
    for (pack_category_tiers) |entry| {
        if (std.mem.eql(u8, category, entry.category)) return entry.tier;
    }
    return pack_tier_unknown;
}

fn packOrderLessThan(_: void, a: CompiledPack, b: CompiledPack) bool {
    const ta = packTier(a.id);
    const tb = packTier(b.id);
    if (ta != tb) return ta < tb;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

pub fn ensureInit() !void {
    // State machine: 0 uninit/retryable, 1 ok, 2 legacy sticky-fail (treated as retryable), 3 in-progress.
    while (true) {
        const state = g_state.load(.acquire);
        if (state == 1) return;
        if (state == 3) {
            while (g_state.load(.acquire) == 3) {
                std.atomic.spinLoopHint();
            }
            continue;
        }
        // 0 or 2: attempt to become the initializer.
        if (g_state.cmpxchgStrong(state, 3, .acq_rel, .acquire)) |_| {
            continue;
        }
        break;
    }

    initOnce() catch {
        // initOnce errdefer already reclaimed C heap + arena.
        g_state.store(0, .release);
        return error.RegistryInitFailed;
    };
    if (g_packs.len == 0) {
        reclaimRegistry();
        g_state.store(0, .release);
        return error.RegistryInitFailed;
    }
    g_state.store(1, .release);
}

pub fn packCount() usize {
    return g_packs.len;
}

fn mightMatch(pack: CompiledPack, cmd: []const u8) bool {
    if (pack.keywords.len == 0) return true;
    for (pack.keywords) |kw| {
        // Windows executables are case-insensitive (Git.EXE / RM.EXE).
        if (std.ascii.indexOfIgnoreCase(cmd, kw) != null) return true;
    }
    return false;
}

pub const MatchResult = union(enum) {
    allow_safe,
    allow_miss,
    deny: Hit,
};

pub const MatchOptions = struct {
    /// When true (default), only packs enabled under Rust `Config::default()`,
    /// plus any IDs listed in `extra_enabled`. Set false to evaluate the full
    /// 85-pack set (still honoring `disabled`).
    default_packs_only: bool = true,
    /// Opt-in pack IDs to evaluate in addition to the default set.
    extra_enabled: []const []const u8 = &.{},
    /// Pack IDs to force-disable (takes precedence over default/extra).
    disabled: []const []const u8 = &.{},
};

/// Fail-closed hit when PCRE match infrastructure fails (OOM, null code, other errors).
/// Static strings — safe for matchDeny → evaluate dupe path without allocation here.
const match_infra_hit: Hit = .{
    .pack_id = "zig.shell",
    .pattern_name = "pcre-match-error",
    .severity = .critical,
    .reason = "Pack regex match infrastructure failed (fail-closed).",
};

fn matchInfraDeny() MatchResult {
    return .{ .deny = match_infra_hit };
}

/// Match packs on a single (already normalized/sanitized) command.
///
/// Per-pack safe/destructive ordering: a safe match suppresses destructive
/// patterns from the **same pack only**. Cross-pack destructives still deny
/// (e.g. `rm -rf / $(git checkout -b x)` is not allowed by `core.git` safe).
/// Match infrastructure errors return `.deny` (fail closed), not `.allow_miss`.
pub fn matchCommandDetailed(cmd: []const u8) MatchResult {
    return matchCommandDetailedOpts(cmd, .{});
}

fn packIdListed(pack_id: []const u8, ids: []const []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, pack_id, id)) return true;
        // Category shorthand: `core` → `core.*`, `containers` → `containers.*`.
        // Any config token without a '.' is treated as a category prefix.
        if (std.mem.indexOfScalar(u8, id, '.') == null and id.len > 0) {
            if (pack_id.len > id.len and pack_id[id.len] == '.' and std.mem.startsWith(u8, pack_id, id)) {
                return true;
            }
        }
    }
    return false;
}

fn packIsActive(pack: CompiledPack, opts: MatchOptions) bool {
    if (packIdListed(pack.id, opts.disabled)) return false;
    if (!opts.default_packs_only) return true;
    if (pack.default_enabled) return true;
    return packIdListed(pack.id, opts.extra_enabled);
}

pub fn matchCommandDetailedOpts(cmd: []const u8, opts: MatchOptions) MatchResult {
    if (g_packs.len == 0) return .allow_miss;

    var any_safe = false;
    for (g_packs) |pack| {
        if (!packIsActive(pack, opts)) continue;
        if (!mightMatch(pack, cmd)) continue;

        var pack_safe = false;
        for (pack.safe) |pat| {
            const matched = pat.regex.isMatch(cmd) catch return matchInfraDeny();
            if (matched) {
                pack_safe = true;
                any_safe = true;
                break;
            }
        }
        // Same-pack only: skip this pack's destructives, keep scanning others.
        if (pack_safe) continue;

        for (pack.destructive) |pat| {
            const matched = pat.regex.isMatch(cmd) catch return matchInfraDeny();
            if (matched) {
                return .{ .deny = .{
                    .pack_id = pack.id,
                    .pattern_name = pat.name,
                    .severity = pat.severity,
                    .reason = if (pat.reason.len > 0)
                        pat.reason
                    else
                        "Destructive command blocked by ryk pack.",
                } };
            }
        }
    }
    if (any_safe) return .allow_safe;
    return .allow_miss;
}

pub fn defaultEnabledPackCount() usize {
    var n: usize = 0;
    for (g_packs) |p| {
        if (p.default_enabled) n += 1;
    }
    return n;
}

/// Embedded oracle pattern totals (must match extract from frozen orca-rs packs).
pub const expected_destructive_patterns: usize = 792;
pub const expected_safe_patterns: usize = 830;

fn compileOnePattern(a: std.mem.Allocator, pat: std.json.Value) !CompiledPattern {
    const o = pat.object;
    const name = if (o.get("name")) |n| (if (n == .string) n.string else "unnamed") else "unnamed";
    const regex_s = o.get("regex").?.string;
    const reason = if (o.get("reason")) |r| (if (r == .string) r.string else "") else "";
    const sev_s = if (o.get("severity")) |s| (if (s == .string) s.string else "high") else "high";
    const severity: Severity = if (std.mem.eql(u8, sev_s, "critical"))
        .critical
    else if (std.mem.eql(u8, sev_s, "medium"))
        .medium
    else if (std.mem.eql(u8, sev_s, "low"))
        .low
    else
        .high;

    // Fail closed: do not silently drop patterns (would shrink the guard).
    var cre = regex_pcre.Regex.compile(regex_s) catch return error.PatternCompileFailed;
    errdefer cre.deinit();
    return .{
        .name = try a.dupe(u8, name),
        .reason = try a.dupe(u8, reason),
        .severity = severity,
        .regex = cre,
    };
}

fn compileList(a: std.mem.Allocator, val: ?std.json.Value) ![]CompiledPattern {
    var list: std.ArrayList(CompiledPattern) = .empty;
    errdefer {
        for (list.items) |*p| p.regex.deinit();
        list.deinit(a);
    }

    const arr = if (val) |v| (if (v == .array) v.array.items else &[_]std.json.Value{}) else &[_]std.json.Value{};
    for (arr) |pat| {
        const compiled = try compileOnePattern(a, pat);
        list.append(a, compiled) catch |err| {
            var leaked = compiled;
            leaked.regex.deinit();
            return err;
        };
    }
    return try list.toOwnedSlice(a);
}

/// Count compiled patterns across all loaded packs (post-init).
pub fn compiledPatternCounts() struct { destructive: usize, safe: usize } {
    var d: usize = 0;
    var s: usize = 0;
    for (g_packs) |p| {
        d += p.destructive.len;
        s += p.safe.len;
    }
    return .{ .destructive = d, .safe = s };
}

test "registry loads packs and matches git reset" {
    try ensureInit();
    try std.testing.expect(packCount() >= 85);
    const r = matchCommandDetailed("git reset --hard");
    try std.testing.expect(r == .deny);
    try std.testing.expectEqualStrings("core.git", r.deny.pack_id);
}

// Phase 1 hard fence: g_packs must follow Rust expand_enabled_ordered (pack_tier then lex)
// so first-match attribution is stable — not JSON alphabetical (apigateway-first).
test "default-enabled packs are ordered tier then lex not apigateway-first" {
    try ensureInit();
    try std.testing.expect(g_packs.len >= 3);
    // Full registry order: tier-1 core.* first, never apigateway (tier 4) first.
    try std.testing.expectEqualStrings("core.filesystem", g_packs[0].id);
    try std.testing.expect(!std.mem.startsWith(u8, g_packs[0].id, "apigateway."));

    var enabled_ids: [16][]const u8 = undefined;
    var n: usize = 0;
    for (g_packs) |p| {
        if (!p.default_enabled) continue;
        if (n >= enabled_ids.len) break;
        enabled_ids[n] = p.id;
        n += 1;
    }
    try std.testing.expect(n >= 2);
    // First default-enabled is core.filesystem; every entry is core.* or system.disk;
    // system.disk present and after all core.* (tier order). No fixed core cardinality.
    try std.testing.expectEqualStrings("core.filesystem", enabled_ids[0]);
    var saw_system_disk = false;
    for (enabled_ids[0..n]) |id| {
        if (std.mem.eql(u8, id, "system.disk")) {
            saw_system_disk = true;
        } else {
            try std.testing.expect(std.mem.startsWith(u8, id, "core."));
            try std.testing.expect(!saw_system_disk);
        }
    }
    try std.testing.expect(saw_system_disk);

    // Full g_packs is non-decreasing by (tier, pack_id).
    var i: usize = 1;
    while (i < g_packs.len) : (i += 1) {
        const prev = g_packs[i - 1];
        const cur = g_packs[i];
        const tp = packTier(prev.id);
        const tc = packTier(cur.id);
        try std.testing.expect(tp <= tc);
        if (tp == tc) {
            try std.testing.expect(std.mem.order(u8, prev.id, cur.id) != .gt);
        }
    }
}

test "packTier mirrors Rust category table" {
    // Driven from pack_category_tiers — single source with packTier().
    for (pack_category_tiers) |entry| {
        var buf: [64]u8 = undefined;
        const sample = try std.fmt.bufPrint(&buf, "{s}.sample", .{entry.category});
        try std.testing.expectEqual(entry.tier, packTier(sample));
        // Category alone (no pack suffix) uses the same tier.
        try std.testing.expectEqual(entry.tier, packTier(entry.category));
    }
    try std.testing.expectEqual(pack_tier_unknown, packTier("unknown.category"));
    // Spot-check concrete pack ids used by Mode A / oracle.
    try std.testing.expectEqual(@as(u8, 1), packTier("core.filesystem"));
    try std.testing.expectEqual(@as(u8, 1), packTier("core.git"));
    try std.testing.expectEqual(@as(u8, 2), packTier("system.disk"));
}

test "registry compiled pattern counts match embedded oracle totals" {
    try ensureInit();
    const counts = compiledPatternCounts();
    try std.testing.expectEqual(@as(usize, expected_destructive_patterns), counts.destructive);
    try std.testing.expectEqual(@as(usize, expected_safe_patterns), counts.safe);
}

test "safe match is pack-scoped so cross-pack destructive still denies" {
    try ensureInit();
    // core.git safe (checkout -b) must not suppress core.filesystem root wipe.
    const r = matchCommandDetailed("rm -rf / $(git checkout -b x)");
    try std.testing.expect(r == .deny);
    try std.testing.expectEqualStrings("core.filesystem", r.deny.pack_id);
}

test "opt-in pack via extra_enabled denies docker system prune" {
    try ensureInit();
    const baseline = matchCommandDetailedOpts("docker system prune", .{});
    try std.testing.expect(baseline != .deny);

    const with_docker = matchCommandDetailedOpts("docker system prune", .{
        .extra_enabled = &.{"containers.docker"},
    });
    try std.testing.expect(with_docker == .deny);
    try std.testing.expectEqualStrings("containers.docker", with_docker.deny.pack_id);
}

test "opt-in pack category containers expands to containers.*" {
    try ensureInit();
    const with_cat = matchCommandDetailedOpts("docker system prune", .{
        .extra_enabled = &.{"containers"},
    });
    try std.testing.expect(with_cat == .deny);
    try std.testing.expectEqualStrings("containers.docker", with_cat.deny.pack_id);
}

test "disabled pack suppresses default-enabled destructive match" {
    try ensureInit();
    const disabled = matchCommandDetailedOpts("mkfs.ext4 /dev/sda1", .{
        .disabled = &.{"system.disk"},
    });
    try std.testing.expect(disabled != .deny);
}

test "match infrastructure error hit is deny not allow_miss" {
    // Contract: matchInfraDeny is what matchCommandDetailedOpts returns on isMatch error.
    const r = matchInfraDeny();
    try std.testing.expect(r == .deny);
    try std.testing.expectEqualStrings("pcre-match-error", r.deny.pattern_name);
    try std.testing.expect(r.deny.severity == .critical);
}
