//! Time window helpers for session scan.
const std = @import("std");
const types = @import("types.zig");

pub const Window = struct {
    /// Inclusive lower bound in unix seconds. Null = all-time (no cutoff).
    cutoff_secs: ?i64,
    days: ?u32,
    all_time: bool,
};

/// Resolve scan window. Default is last `default_window_days` days.
pub fn resolveWindow(now_secs: i64, days: ?u32, all_time: bool) Window {
    if (all_time) {
        return .{ .cutoff_secs = null, .days = null, .all_time = true };
    }
    const d = days orelse types.default_window_days;
    const delta: i64 = @as(i64, @intCast(d)) * 86_400;
    return .{
        .cutoff_secs = now_secs - delta,
        .days = d,
        .all_time = false,
    };
}

pub fn inWindow(ts_secs: i64, window: Window) bool {
    const cutoff = window.cutoff_secs orelse return true;
    return ts_secs >= cutoff;
}

/// Parse common ISO-8601 timestamps to unix seconds. Best-effort; returns null on failure.
/// Accepts: `2026-07-20T01:25:10.270Z`, `2026-07-20T01:25:10Z`, `2026-07-20T01:25:10+00:00`.
pub fn parseIsoToUnix(iso: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, iso, " \t\r\n");
    if (trimmed.len < 19) return null;
    // YYYY-MM-DDTHH:MM:SS...
    if (trimmed[4] != '-' or trimmed[7] != '-' or (trimmed[10] != 'T' and trimmed[10] != ' ')) return null;
    if (trimmed[13] != ':' or trimmed[16] != ':') return null;

    const year = std.fmt.parseInt(u16, trimmed[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, trimmed[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, trimmed[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, trimmed[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, trimmed[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, trimmed[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;

    // Days from civil (Howard Hinnant algorithm) → unix epoch.
    const y: i32 = if (month <= 2) @as(i32, year) - 1 else @as(i32, year);
    const era: i32 = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const mp: u32 = if (month > 2) month - 3 else month + 9;
    const doy: u32 = (153 * mp + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days_since_epoch: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;
    return days_since_epoch * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

test "resolveWindow default is 30 days" {
    const now: i64 = 1_700_000_000;
    const w = resolveWindow(now, null, false);
    try std.testing.expect(!w.all_time);
    try std.testing.expectEqual(@as(?u32, 30), w.days);
    try std.testing.expectEqual(@as(?i64, now - 30 * 86_400), w.cutoff_secs);
}

test "resolveWindow --days N changes cutoff" {
    const now: i64 = 1_700_000_000;
    const w = resolveWindow(now, 7, false);
    try std.testing.expectEqual(@as(?u32, 7), w.days);
    try std.testing.expectEqual(@as(?i64, now - 7 * 86_400), w.cutoff_secs);
    try std.testing.expect(inWindow(now - 3 * 86_400, w));
    try std.testing.expect(!inWindow(now - 10 * 86_400, w));
}

test "resolveWindow all-time has no cutoff" {
    const w = resolveWindow(1_700_000_000, 7, true);
    try std.testing.expect(w.all_time);
    try std.testing.expect(w.cutoff_secs == null);
    try std.testing.expect(inWindow(0, w));
}

test "parseIsoToUnix accepts Z timestamps" {
    const ts = parseIsoToUnix("2026-07-20T01:25:10.270Z") orelse {
        try std.testing.expect(false);
        return;
    };
    // 2026-07-20 01:25:10 UTC — sanity: year 2026 is after 2020 epoch ballpark.
    try std.testing.expect(ts > 1_700_000_000);
    try std.testing.expect(ts < 2_000_000_000);
    const ts2 = parseIsoToUnix("2026-07-20T01:25:10Z").?;
    try std.testing.expectEqual(ts, ts2);
}

test "old session outside window is excluded" {
    const now: i64 = 1_800_000_000;
    const w = resolveWindow(now, 30, false);
    const old = now - 60 * 86_400;
    try std.testing.expect(!inWindow(old, w));
}
