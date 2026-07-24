const std = @import("std");

/// Duplicate an environment variable from a map, or null if unset.
pub fn getOwned(map: *const std.process.Environ.Map, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const value = map.get(key) orelse return null;
    return try allocator.dupe(u8, value);
}

/// Prefer the first present key among `keys` (Phase 5a: RYK_* then ORCA_*).
/// Returns an owned copy of the first non-null value, or null if none are set.
pub fn getOwnedFirst(map: *const std.process.Environ.Map, allocator: std.mem.Allocator, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        if (try getOwned(map, allocator, key)) |value| return value;
    }
    return null;
}

/// Brand dual-read: prefer `RYK_<suffix>` then `ORCA_<suffix>`.
/// `suffix` is the part after the underscore prefix (e.g. "BIN", "RESOURCE_ROOT").
pub fn getOwnedBrand(map: *const std.process.Environ.Map, allocator: std.mem.Allocator, suffix: []const u8) !?[]u8 {
    var ryk_buf: [128]u8 = undefined;
    var orca_buf: [128]u8 = undefined;
    // Gate on the longer prefix (`ORCA_` = 5) so ORCA_* never fails with NoSpaceLeft
    // while RYK_* would have returned NameTooLong.
    if (suffix.len + 5 > ryk_buf.len) return error.NameTooLong;
    const ryk_key = try std.fmt.bufPrint(&ryk_buf, "RYK_{s}", .{suffix});
    const orca_key = try std.fmt.bufPrint(&orca_buf, "ORCA_{s}", .{suffix});
    return getOwnedFirst(map, allocator, &.{ ryk_key, orca_key });
}

/// Process-environ brand dual-read: prefer `RYK_<suffix>` then `ORCA_<suffix>`.
/// Returns the raw C string pointer (not owned). Null if neither is set.
pub fn getenvBrand(suffix: []const u8) ?[*:0]const u8 {
    var ryk_buf: [128]u8 = undefined;
    var orca_buf: [128]u8 = undefined;
    if (suffix.len + 5 >= orca_buf.len) return null;
    const ryk_key = std.fmt.bufPrintZ(&ryk_buf, "RYK_{s}", .{suffix}) catch return null;
    if (std.c.getenv(ryk_key.ptr)) |v| return v;
    const orca_key = std.fmt.bufPrintZ(&orca_buf, "ORCA_{s}", .{suffix}) catch return null;
    return std.c.getenv(orca_key.ptr);
}

/// True when RYK_<suffix> or ORCA_<suffix> is a truthy flag (`1`/`true`/`yes`/`on`).
pub fn getenvBrandFlagTruthy(suffix: []const u8) bool {
    const raw_c = getenvBrand(suffix) orelse return false;
    const raw = std.mem.span(raw_c);
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on");
}

test "getOwnedFirst prefers first key" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("RYK_BIN", "/new/ryk");
    try map.put("ORCA_BIN", "/old/orca");
    const value = try getOwnedFirst(&map, std.testing.allocator, &.{ "RYK_BIN", "ORCA_BIN" });
    defer if (value) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("/new/ryk", value.?);
}

test "getOwnedFirst falls back to second key" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ORCA_BIN", "/old/orca");
    const value = try getOwnedFirst(&map, std.testing.allocator, &.{ "RYK_BIN", "ORCA_BIN" });
    defer if (value) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("/old/orca", value.?);
}

test "getOwnedFirst returns null when none set" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const value = try getOwnedFirst(&map, std.testing.allocator, &.{ "RYK_BIN", "ORCA_BIN" });
    try std.testing.expect(value == null);
}

test "getOwnedBrand prefers RYK_ then ORCA_" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ORCA_RESOURCE_ROOT", "/share/orca");
    const only_legacy = try getOwnedBrand(&map, std.testing.allocator, "RESOURCE_ROOT");
    defer if (only_legacy) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("/share/orca", only_legacy.?);

    try map.put("RYK_RESOURCE_ROOT", "/share/ryk");
    const prefer_new = try getOwnedBrand(&map, std.testing.allocator, "RESOURCE_ROOT");
    defer if (prefer_new) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("/share/ryk", prefer_new.?);
}

test "getOwnedBrand NameTooLong gates on longer ORCA_ prefix" {
    // Buffer is 128; ORCA_ + suffix must fit. Length 124 fails for both prefixes.
    const too_long = "X" ** 124;
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectError(error.NameTooLong, getOwnedBrand(&map, std.testing.allocator, too_long));
}

/// Read the process environment block (POSIX libc `environ`).
pub fn processEnviron() std.process.Environ {
    return .{ .block = std.process.Environ.PosixBlock{
        .slice = @ptrCast(std.c.environ[0..countCEnviron() :null]),
    } };
}

fn countCEnviron() usize {
    var n: usize = 0;
    while (std.c.environ[n]) |entry| : (n += 1) {
        _ = entry;
    }
    return n;
}

/// Allocate a map of the current process environment.
pub fn createProcessMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try std.process.Environ.createMap(processEnviron(), allocator);
}
