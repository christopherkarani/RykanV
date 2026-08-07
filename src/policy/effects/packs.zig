//! User-authored effect packs: classification-only extensions to the built-in catalog.
//! Decisions still require policy `effects:`; packs never grant past effects.deny.

const std = @import("std");
const catalog = @import("catalog.zig");
const classify = @import("classify.zig");
const ids = @import("ids.zig");
const structural = @import("structural.zig");

pub const EffectHit = catalog.EffectHit;
pub const Confidence = catalog.Confidence;
pub const ToolArgsView = structural.ToolArgsView;

pub const max_pack_file_bytes: usize = 64 * 1024;
pub const max_names_per_pack: usize = 256;
pub const max_tokens_per_pack: usize = 128;
pub const max_structural_per_pack: usize = 64;
pub const max_keys_per_structural: usize = 16;

pub const PackError = error{
    InvalidEffectPack,
    EffectPackTooLarge,
    EffectPackTooManyEntries,
    UnknownEffectId,
    InvalidPackId,
    UnsupportedPackVersion,
};

pub const NameMapping = struct {
    name: []const u8,
    effect_id: []const u8,
    matcher: []const u8,
};

pub const TokenMapping = struct {
    token: []const u8,
    effect_id: []const u8,
    matcher: []const u8,
};

pub const StructuralMapping = struct {
    keys: []const []const u8,
    effect_id: []const u8,
    matcher: []const u8,
};

pub const Pack = struct {
    id: []const u8,
    path: []const u8,
    description: ?[]const u8 = null,
    names: []const NameMapping = &.{},
    tokens: []const TokenMapping = &.{},
    structural: []const StructuralMapping = &.{},
    /// Arena-like owned strings for this pack (id, path, matchers, keys, …).
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Pack) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PackSet = struct {
    packs: []Pack = &.{},
    allocator: std.mem.Allocator,

    pub fn empty(allocator: std.mem.Allocator) PackSet {
        return .{ .packs = &.{}, .allocator = allocator };
    }

    /// Take ownership of a single pack (for tests and inline construction).
    pub fn fromPack(allocator: std.mem.Allocator, pack: Pack) !PackSet {
        const slice = try allocator.alloc(Pack, 1);
        slice[0] = pack;
        return .{ .packs = slice, .allocator = allocator };
    }

    pub fn deinit(self: *PackSet) void {
        for (self.packs) |*pack| pack.deinit();
        if (self.packs.len > 0) self.allocator.free(self.packs);
        self.* = undefined;
    }

    pub fn isEmpty(self: PackSet) bool {
        return self.packs.len == 0;
    }
};

/// Resolve user config effect-packs directory (may not exist).
pub fn userConfigPacksDir(allocator: std.mem.Allocator) !?[]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg_c| {
        const xdg = std.mem.sliceTo(xdg_c, 0);
        if (xdg.len > 0) {
            return try std.fs.path.join(allocator, &.{ xdg, "ryk", "effect-packs" });
        }
    }
    if (std.c.getenv("HOME")) |home_c| {
        const home = std.mem.sliceTo(home_c, 0);
        if (home.len > 0) {
            return try std.fs.path.join(allocator, &.{ home, ".config", "ryk", "effect-packs" });
        }
    }
    return null;
}

pub const LoadOptions = struct {
    /// Override auto-resolved user config dir (`null` = resolve from env).
    user_config_dir: ?[]const u8 = null,
    /// When true, unreadable pack directories fail closed (enforcement). Discovery soft-skips.
    fail_on_access_denied: bool = false,
};

/// Load packs: user config (lower) then workspace `.ryk/effect-packs` (higher / last-wins).
/// Within a directory, files load in lexicographic filename order (deterministic tie-break).
/// Missing directories are OK. Present but invalid files fail closed.
/// Use for discovery (`tools classify`, `mcp inspect`) where packs are always consulted.
pub fn loadPacks(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    user_config_dir: ?[]const u8,
) !PackSet {
    return loadPacksWithOptions(io, allocator, workspace_root, .{
        .user_config_dir = user_config_dir,
        .fail_on_access_denied = false,
    });
}

fn loadPacksWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    options: LoadOptions,
) !PackSet {
    var list: std.ArrayList(Pack) = .empty;
    errdefer {
        for (list.items) |*pack| pack.deinit();
        list.deinit(allocator);
    }

    if (options.user_config_dir) |dir| {
        try appendPacksFromDir(io, allocator, dir, &list, options.fail_on_access_denied);
    } else if (try userConfigPacksDir(allocator)) |auto| {
        defer allocator.free(auto);
        try appendPacksFromDir(io, allocator, auto, &list, options.fail_on_access_denied);
    }

    const workspace_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".ryk", "effect-packs" });
    defer allocator.free(workspace_dir);
    try appendPacksFromDir(io, allocator, workspace_dir, &list, options.fail_on_access_denied);

    return .{
        .packs = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Enforcement path: skip pack I/O when `effects:` is inactive (packs only matter for
/// classification hits that feed `effects:` decisions). When active, load and fail closed
/// on invalid pack files and unreadable pack directories.
pub fn loadPacksForEnforcement(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    effects_active: bool,
) !PackSet {
    if (!effects_active) return PackSet.empty(allocator);
    return loadPacksWithOptions(io, allocator, workspace_root, .{
        .user_config_dir = null,
        .fail_on_access_denied = true,
    });
}

fn appendPacksFromDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    list: *std.ArrayList(Pack),
    fail_on_access_denied: bool,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        error.AccessDenied => {
            if (fail_on_access_denied) return PackError.InvalidEffectPack;
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    // Collect then sort so same-tier last-wins is deterministic across filesystems.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!(std.mem.endsWith(u8, entry.name, ".yaml") or std.mem.endsWith(u8, entry.name, ".yml"))) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    for (names.items) |entry_name| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, entry_name });
        defer allocator.free(file_path);

        const text = std.Io.Dir.cwd().readFileAlloc(
            io,
            file_path,
            allocator,
            .limited(max_pack_file_bytes + 1),
        ) catch |err| switch (err) {
            error.FileTooBig => return PackError.EffectPackTooLarge,
            error.AccessDenied => {
                if (fail_on_access_denied) return PackError.InvalidEffectPack;
                return err;
            },
            else => return err,
        };
        defer allocator.free(text);
        if (text.len > max_pack_file_bytes) return PackError.EffectPackTooLarge;

        try list.append(allocator, try parsePackFromSlice(allocator, text, file_path));
    }
}

fn isValidPackId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn stripComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |c, i| {
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (c == '#' and !in_single and !in_double) return std.mem.trimEnd(u8, line[0..i], " \t");
    }
    return line;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else break;
    }
    return n;
}

fn parseScalar(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 2) {
        if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

fn parseInlineStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return PackError.InvalidEffectPack;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return try allocator.alloc([]const u8, 0);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var rest = inner;
    while (rest.len > 0) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const piece = if (comma) |i| rest[0..i] else rest;
        const item = parseScalar(piece);
        if (item.len == 0) return PackError.InvalidEffectPack;
        try list.append(allocator, try allocator.dupe(u8, item));
        if (comma) |i| {
            rest = rest[i + 1 ..];
        } else break;
    }
    return try list.toOwnedSlice(allocator);
}

const Section = enum {
    root,
    names,
    tokens,
    structural,
    structural_item,
    structural_keys,
};

/// Parse a single pack YAML document (v1 schema).
pub fn parsePackFromSlice(allocator: std.mem.Allocator, text: []const u8, source_path: []const u8) !Pack {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var version: ?u16 = null;
    var id: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    var names: std.ArrayList(NameMapping) = .empty;
    var tokens: std.ArrayList(TokenMapping) = .empty;
    var structural_list: std.ArrayList(StructuralMapping) = .empty;

    var section: Section = .root;
    var current_effect: ?[]const u8 = null;
    var current_keys: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const cleaned = stripComment(std.mem.trimEnd(u8, raw_line, " \t\r"));
        if (std.mem.trim(u8, cleaned, " \t").len == 0) continue;
        const indent = countIndent(cleaned);
        if (indent % 2 != 0) return PackError.InvalidEffectPack;
        const line = std.mem.trim(u8, cleaned[indent..], " \t");

        // Finish structural item when indent pops out of item
        if (section == .structural_item or section == .structural_keys) {
            if (indent <= 2 and !(std.mem.startsWith(u8, line, "- ") and indent == 2)) {
                try finishStructuralItem(arena, &structural_list, id, &current_effect, &current_keys);
                section = if (indent == 0) .root else .structural;
            }
        }

        if (std.mem.startsWith(u8, line, "- ")) {
            const body = std.mem.trim(u8, line[2..], " \t");
            if (section == .structural or section == .structural_item) {
                try finishStructuralItem(arena, &structural_list, id, &current_effect, &current_keys);
                section = .structural_item;
                current_effect = null;
                // Inline form: `- effect: comms.message` or separate keys later
                if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
                    const k = std.mem.trim(u8, body[0..colon], " \t");
                    const v = parseScalar(body[colon + 1 ..]);
                    if (std.mem.eql(u8, k, "effect")) {
                        if (!ids.isKnownEffectId(v)) return PackError.UnknownEffectId;
                        current_effect = try arena.dupe(u8, v);
                    } else return PackError.InvalidEffectPack;
                } else if (body.len > 0) {
                    return PackError.InvalidEffectPack;
                }
                continue;
            }
            if (section == .structural_keys) {
                const key = parseScalar(body);
                if (key.len == 0) return PackError.InvalidEffectPack;
                if (current_keys.items.len >= max_keys_per_structural) return PackError.InvalidEffectPack;
                try current_keys.append(arena, try arena.dupe(u8, key));
                continue;
            }
            return PackError.InvalidEffectPack;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return PackError.InvalidEffectPack;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (indent == 0) {
            section = .root;
            if (std.mem.eql(u8, key, "version")) {
                version = std.fmt.parseInt(u16, parseScalar(value), 10) catch return PackError.InvalidEffectPack;
            } else if (std.mem.eql(u8, key, "id")) {
                const parsed = parseScalar(value);
                if (!isValidPackId(parsed)) return PackError.InvalidPackId;
                id = try arena.dupe(u8, parsed);
            } else if (std.mem.eql(u8, key, "description")) {
                description = try arena.dupe(u8, parseScalar(value));
            } else if (std.mem.eql(u8, key, "names")) {
                if (value.len != 0) return PackError.InvalidEffectPack;
                section = .names;
            } else if (std.mem.eql(u8, key, "tokens")) {
                if (value.len != 0) return PackError.InvalidEffectPack;
                section = .tokens;
            } else if (std.mem.eql(u8, key, "structural")) {
                if (value.len != 0) return PackError.InvalidEffectPack;
                section = .structural;
            } else {
                return PackError.InvalidEffectPack;
            }
            continue;
        }

        if (indent == 2 and section == .names) {
            if (names.items.len >= max_names_per_pack) return PackError.EffectPackTooManyEntries;
            const name = try catalog.normalizeToolName(arena, key);
            const effect = parseScalar(value);
            if (!ids.isKnownEffectId(effect)) return PackError.UnknownEffectId;
            const pack_id = id orelse return PackError.InvalidEffectPack;
            const matcher = try std.fmt.allocPrint(arena, "pack.{s}.name:{s}", .{ pack_id, name });
            try names.append(arena, .{
                .name = name,
                .effect_id = try arena.dupe(u8, effect),
                .matcher = matcher,
            });
            continue;
        }

        if (indent == 2 and section == .tokens) {
            if (tokens.items.len >= max_tokens_per_pack) return PackError.EffectPackTooManyEntries;
            const token_raw = parseScalar(key);
            if (token_raw.len == 0) return PackError.InvalidEffectPack;
            var token_buf = try arena.alloc(u8, token_raw.len);
            for (token_raw, 0..) |c, i| token_buf[i] = std.ascii.toLower(c);
            const effect = parseScalar(value);
            if (!ids.isKnownEffectId(effect)) return PackError.UnknownEffectId;
            const pack_id = id orelse return PackError.InvalidEffectPack;
            const matcher = try std.fmt.allocPrint(arena, "pack.{s}.token:{s}", .{ pack_id, token_buf });
            try tokens.append(arena, .{
                .token = token_buf,
                .effect_id = try arena.dupe(u8, effect),
                .matcher = matcher,
            });
            continue;
        }

        if ((section == .structural_item or section == .structural_keys) and indent >= 4) {
            if (std.mem.eql(u8, key, "effect")) {
                const effect = parseScalar(value);
                if (!ids.isKnownEffectId(effect)) return PackError.UnknownEffectId;
                current_effect = try arena.dupe(u8, effect);
                section = .structural_item;
            } else if (std.mem.eql(u8, key, "keys")) {
                if (value.len > 0) {
                    const parsed_keys = try parseInlineStringList(arena, value);
                    if (parsed_keys.len == 0 or parsed_keys.len > max_keys_per_structural) return PackError.InvalidEffectPack;
                    for (parsed_keys) |k| {
                        try current_keys.append(arena, k);
                    }
                    section = .structural_item;
                } else {
                    section = .structural_keys;
                }
            } else {
                return PackError.InvalidEffectPack;
            }
            continue;
        }

        return PackError.InvalidEffectPack;
    }

    try finishStructuralItem(arena, &structural_list, id, &current_effect, &current_keys);

    if (version != 1) return PackError.UnsupportedPackVersion;
    const pack_id = id orelse return PackError.InvalidPackId;

    return .{
        .id = pack_id,
        .path = try arena.dupe(u8, source_path),
        .description = description,
        .names = try names.toOwnedSlice(arena),
        .tokens = try tokens.toOwnedSlice(arena),
        .structural = try structural_list.toOwnedSlice(arena),
        .arena = arena_state,
    };
}

fn finishStructuralItem(
    arena: std.mem.Allocator,
    list: *std.ArrayList(StructuralMapping),
    pack_id: ?[]const u8,
    effect: *?[]const u8,
    keys: *std.ArrayList([]const u8),
) !void {
    if (effect.* == null and keys.items.len == 0) return;
    const eid = effect.* orelse return PackError.InvalidEffectPack;
    if (keys.items.len == 0) return PackError.InvalidEffectPack;
    if (keys.items.len > max_keys_per_structural) return PackError.InvalidEffectPack;
    if (list.items.len >= max_structural_per_pack) return PackError.EffectPackTooManyEntries;
    const pid = pack_id orelse return PackError.InvalidEffectPack;

    // Normalize keys
    var norm_keys = try arena.alloc([]const u8, keys.items.len);
    for (keys.items, 0..) |k, i| {
        var buf = try arena.alloc(u8, k.len);
        for (k, 0..) |c, j| {
            const lower = std.ascii.toLower(c);
            buf[j] = if (lower == '-' or lower == '.') '_' else lower;
        }
        norm_keys[i] = buf;
    }

    var matcher_buf: std.ArrayList(u8) = .empty;
    try matcher_buf.appendSlice(arena, "pack.");
    try matcher_buf.appendSlice(arena, pid);
    try matcher_buf.appendSlice(arena, ".structural.keys:");
    for (norm_keys, 0..) |k, i| {
        if (i > 0) try matcher_buf.append(arena, '+');
        try matcher_buf.appendSlice(arena, k);
    }

    try list.append(arena, .{
        .keys = norm_keys,
        .effect_id = eid,
        .matcher = try matcher_buf.toOwnedSlice(arena),
    });
    effect.* = null;
    keys.* = .empty;
}

const appendUniquePreferHigher = classify.appendUniquePreferHigher;

/// Pack-only hits for a tool call (name + optional args). Matchers borrow from PackSet.
pub fn classifyPackHits(
    allocator: std.mem.Allocator,
    pack_set: *const PackSet,
    tool_name: []const u8,
    args: ?ToolArgsView,
) ![]EffectHit {
    var hits: std.ArrayList(EffectHit) = .empty;
    errdefer hits.deinit(allocator);

    const trimmed = std.mem.trim(u8, tool_name, " \t\r\n");
    if (trimmed.len == 0) return try hits.toOwnedSlice(allocator);

    const normalized = try catalog.normalizeToolName(allocator, trimmed);
    defer allocator.free(normalized);
    // Match both full name and last segment (mcp__server__tool → tool), same as catalog.
    const focus = catalog.focusName(normalized);

    // Exact name → one effect: highest-priority pack wins (workspace over user config).
    // Walk reverse; first match is final (do not accumulate competing name maps).
    {
        var i = pack_set.packs.len;
        outer: while (i > 0) {
            i -= 1;
            for (pack_set.packs[i].names) |mapping| {
                if (std.mem.eql(u8, mapping.name, normalized) or std.mem.eql(u8, mapping.name, focus)) {
                    try appendUniquePreferHigher(allocator, &hits, .{
                        .id = mapping.effect_id,
                        .confidence = .high,
                        .matcher = mapping.matcher,
                    });
                    break :outer;
                }
            }
        }
    }

    for (pack_set.packs) |pack| {
        for (pack.tokens) |mapping| {
            if (mapping.token.len == 0) continue;
            // Same token rules as catalog (short tokens need whole `_` segments).
            if (catalog.containsToken(normalized, mapping.token) or catalog.containsToken(focus, mapping.token)) {
                try appendUniquePreferHigher(allocator, &hits, .{
                    .id = mapping.effect_id,
                    .confidence = .medium,
                    .matcher = mapping.matcher,
                });
            }
        }
    }

    if (args) |view| {
        var key_norm: std.ArrayList([]const u8) = .empty;
        defer {
            for (key_norm.items) |k| allocator.free(k);
            key_norm.deinit(allocator);
        }
        for (view.keys) |k| {
            try key_norm.append(allocator, try catalog.normalizeToolName(allocator, k));
        }
        for (pack_set.packs) |pack| {
            for (pack.structural) |mapping| {
                if (keySetPresent(key_norm.items, mapping.keys)) {
                    try appendUniquePreferHigher(allocator, &hits, .{
                        .id = mapping.effect_id,
                        .confidence = .medium,
                        .matcher = mapping.matcher,
                    });
                }
            }
        }
    }

    return try hits.toOwnedSlice(allocator);
}

fn keySetPresent(normalized_keys: []const []const u8, required: []const []const u8) bool {
    for (required) |req| {
        var found = false;
        for (normalized_keys) |k| {
            if (std.mem.eql(u8, k, req)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Built-in classify ∪ pack hits. Hit matchers from packs borrow from `pack_set`.
pub fn classifyToolCallWithPacks(
    allocator: std.mem.Allocator,
    pack_set: ?*const PackSet,
    tool_name: []const u8,
    args: ?ToolArgsView,
) ![]EffectHit {
    const base = try classify.classifyToolCall(allocator, tool_name, args);
    if (pack_set == null or pack_set.?.isEmpty()) return base;

    defer allocator.free(base);
    var hits: std.ArrayList(EffectHit) = .empty;
    errdefer hits.deinit(allocator);
    for (base) |h| try appendUniquePreferHigher(allocator, &hits, h);

    const pack_hits = try classifyPackHits(allocator, pack_set.?, tool_name, args);
    defer allocator.free(pack_hits);
    for (pack_hits) |h| try appendUniquePreferHigher(allocator, &hits, h);

    for (hits.items) |hit| {
        std.debug.assert(ids.isKnownEffectId(hit.id));
    }
    return try hits.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "parse valid pack maps name" {
    const yaml =
        \\version: 1
        \\id: acme-comms
        \\names:
        \\  send_acme_ping: comms.message
        \\  acme_tweet: comms.publish
    ;
    var pack = try parsePackFromSlice(std.testing.allocator, yaml, "test.yaml");
    defer pack.deinit();
    try std.testing.expectEqualStrings("acme-comms", pack.id);
    try std.testing.expectEqual(@as(usize, 2), pack.names.len);
    try std.testing.expectEqualStrings("send_acme_ping", pack.names[0].name);
    try std.testing.expectEqualStrings("comms.message", pack.names[0].effect_id);
    try std.testing.expect(std.mem.startsWith(u8, pack.names[0].matcher, "pack.acme-comms.name:"));
}

test "invalid effect id rejected" {
    const yaml =
        \\version: 1
        \\id: bad
        \\names:
        \\  foo: not.an.effect
    ;
    try std.testing.expectError(PackError.UnknownEffectId, parsePackFromSlice(std.testing.allocator, yaml, "bad.yaml"));
}

test "invalid pack id rejected" {
    const yaml =
        \\version: 1
        \\id: Bad Id!
        \\names:
        \\  foo: comms.message
    ;
    try std.testing.expectError(PackError.InvalidPackId, parsePackFromSlice(std.testing.allocator, yaml, "bad.yaml"));
}

test "unknown root key rejected" {
    const yaml =
        \\version: 1
        \\id: ok
        \\deny:
        \\  - comms.message
    ;
    try std.testing.expectError(PackError.InvalidEffectPack, parsePackFromSlice(std.testing.allocator, yaml, "bad.yaml"));
}

test "classify pack exact name" {
    const yaml =
        \\version: 1
        \\id: acme
        \\names:
        \\  send_acme_ping: comms.message
    ;
    var set = try PackSet.fromPack(std.testing.allocator, try parsePackFromSlice(std.testing.allocator, yaml, "acme.yaml"));
    defer set.deinit();

    const hits = try classifyToolCallWithPacks(std.testing.allocator, &set, "send_acme_ping", null);
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 1);
    var found = false;
    for (hits) |h| {
        if (std.mem.eql(u8, h.id, "comms.message") and std.mem.startsWith(u8, h.matcher, "pack.acme.")) found = true;
    }
    try std.testing.expect(found);
}

test "exact name last-wins single effect from higher-priority pack" {
    // Simulate load order: lower-priority pack first, workspace pack last.
    const lower =
        \\version: 1
        \\id: lower
        \\names:
        \\  custom_send: money.transfer
    ;
    const higher =
        \\version: 1
        \\id: higher
        \\names:
        \\  custom_send: comms.message
    ;
    const pack_lo = try parsePackFromSlice(std.testing.allocator, lower, "lower.yaml");
    const pack_hi = try parsePackFromSlice(std.testing.allocator, higher, "higher.yaml");
    const slice = try std.testing.allocator.alloc(Pack, 2);
    slice[0] = pack_lo;
    slice[1] = pack_hi;
    var set = PackSet{ .packs = slice, .allocator = std.testing.allocator };
    defer set.deinit();

    const hits = try classifyPackHits(std.testing.allocator, &set, "custom_send", null);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);
    try std.testing.expect(std.mem.startsWith(u8, hits[0].matcher, "pack.higher."));
}

test "builtin still works without packs" {
    const hits = try classifyToolCallWithPacks(std.testing.allocator, null, "send_email", null);
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);
}

test "structural pack keys" {
    const yaml =
        \\version: 1
        \\id: acme
        \\structural:
        \\  - effect: comms.message
        \\    keys: [acme_to, acme_body]
    ;
    var set = try PackSet.fromPack(std.testing.allocator, try parsePackFromSlice(std.testing.allocator, yaml, "acme.yaml"));
    defer set.deinit();

    const keys = [_][]const u8{ "acme_to", "acme_body" };
    const hits = try classifyToolCallWithPacks(std.testing.allocator, &set, "helper", .{ .keys = &keys });
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 1);
    var found = false;
    for (hits) |h| {
        if (std.mem.eql(u8, h.id, "comms.message") and std.mem.indexOf(u8, h.matcher, "structural") != null) found = true;
    }
    try std.testing.expect(found);
}

test "loadPacksForEnforcement skips when effects inactive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".ryk/effect-packs");
    {
        const f = try tmp.dir.createFile(std.testing.io, ".ryk/effect-packs/bad.yaml", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\version: 1
            \\id: bad
            \\names:
            \\  x: not.real
        );
    }
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    // Invalid pack must not fail when effects are off (enforcement does not consult packs).
    var set = try loadPacksForEnforcement(std.testing.io, std.testing.allocator, root, false);
    defer set.deinit();
    try std.testing.expect(set.isEmpty());
    // Same tree fails closed when effects are active.
    try std.testing.expectError(
        PackError.UnknownEffectId,
        loadPacksForEnforcement(std.testing.io, std.testing.allocator, root, true),
    );
}

test "loadPacks missing dir is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var set = try loadPacks(std.testing.io, std.testing.allocator, root, null);
    defer set.deinit();
    try std.testing.expect(set.isEmpty());
}

test "loadPacks valid workspace pack" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".ryk/effect-packs");
    {
        const f = try tmp.dir.createFile(std.testing.io, ".ryk/effect-packs/acme.yaml", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\version: 1
            \\id: acme
            \\names:
            \\  send_acme_ping: comms.message
        );
    }
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var set = try loadPacks(std.testing.io, std.testing.allocator, root, null);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.packs.len);
    const hits = try classifyToolCallWithPacks(std.testing.allocator, &set, "send_acme_ping", null);
    defer std.testing.allocator.free(hits);
    var found = false;
    for (hits) |h| {
        if (std.mem.eql(u8, h.id, "comms.message")) found = true;
    }
    try std.testing.expect(found);
}

test "loadPacks invalid pack fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".ryk/effect-packs");
    {
        const f = try tmp.dir.createFile(std.testing.io, ".ryk/effect-packs/bad.yaml", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\version: 1
            \\id: bad
            \\names:
            \\  x: not.real
        );
    }
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(PackError.UnknownEffectId, loadPacks(std.testing.io, std.testing.allocator, root, null));
}

test "pack exact name matches mcp focus segment" {
    const yaml =
        \\version: 1
        \\id: acme
        \\names:
        \\  send_acme_ping: comms.message
    ;
    var set = try PackSet.fromPack(std.testing.allocator, try parsePackFromSlice(std.testing.allocator, yaml, "acme.yaml"));
    defer set.deinit();

    const hits = try classifyPackHits(std.testing.allocator, &set, "mcp__acme__send_acme_ping", null);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);
    try std.testing.expect(std.mem.startsWith(u8, hits[0].matcher, "pack.acme.name:"));
}

test "structural list-form keys respect max_keys_per_structural" {
    var yaml_buf: std.ArrayList(u8) = .empty;
    defer yaml_buf.deinit(std.testing.allocator);
    try yaml_buf.appendSlice(std.testing.allocator,
        \\version: 1
        \\id: acme
        \\structural:
        \\  - effect: comms.message
        \\    keys:
    );
    var i: usize = 0;
    while (i < max_keys_per_structural + 1) : (i += 1) {
        const line = try std.fmt.allocPrint(std.testing.allocator, "\n      - k{d}", .{i});
        defer std.testing.allocator.free(line);
        try yaml_buf.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expectError(
        PackError.InvalidEffectPack,
        parsePackFromSlice(std.testing.allocator, yaml_buf.items, "too-many-keys.yaml"),
    );
}

test "short pack token requires whole segment" {
    const yaml =
        \\version: 1
        \\id: acme
        \\tokens:
        \\  sms: comms.message
    ;
    var set = try PackSet.fromPack(std.testing.allocator, try parsePackFromSlice(std.testing.allocator, yaml, "acme.yaml"));
    defer set.deinit();

    // "asms" contains substring "sms" but is not a whole segment — must not match.
    const no_hit = try classifyPackHits(std.testing.allocator, &set, "asms_helper", null);
    defer std.testing.allocator.free(no_hit);
    try std.testing.expectEqual(@as(usize, 0), no_hit.len);

    const hit = try classifyPackHits(std.testing.allocator, &set, "send_sms_now", null);
    defer std.testing.allocator.free(hit);
    try std.testing.expectEqual(@as(usize, 1), hit.len);
    try std.testing.expectEqualStrings("comms.message", hit[0].id);
}

test "same-dir packs load in lexicographic filename order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".ryk/effect-packs");
    {
        const a = try tmp.dir.createFile(std.testing.io, ".ryk/effect-packs/a-first.yaml", .{});
        defer a.close(std.testing.io);
        try a.writeStreamingAll(std.testing.io,
            \\version: 1
            \\id: first
            \\names:
            \\  custom_send: money.transfer
        );
        const z = try tmp.dir.createFile(std.testing.io, ".ryk/effect-packs/z-last.yaml", .{});
        defer z.close(std.testing.io);
        try z.writeStreamingAll(std.testing.io,
            \\version: 1
            \\id: last
            \\names:
            \\  custom_send: comms.message
        );
    }
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var set = try loadPacks(std.testing.io, std.testing.allocator, root, null);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 2), set.packs.len);
    try std.testing.expectEqualStrings("first", set.packs[0].id);
    try std.testing.expectEqualStrings("last", set.packs[1].id);

    const hits = try classifyPackHits(std.testing.allocator, &set, "custom_send", null);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("comms.message", hits[0].id);
    try std.testing.expect(std.mem.startsWith(u8, hits[0].matcher, "pack.last."));
}
