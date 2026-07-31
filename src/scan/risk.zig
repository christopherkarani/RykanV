//! Pure risk-summary helpers for scan scorecard (TUI + plain).
const std = @import("std");
const types = @import("types.zig");

/// One-glance risk level for new users ("Am I at risk?").
pub const RiskLevel = enum {
    no_data,
    incomplete,
    clear,
    secrets_seen,
    secrets_accessed,
    dangerous,

    pub fn toString(self: RiskLevel) []const u8 {
        return switch (self) {
            .no_data => "no_data",
            .incomplete => "incomplete",
            .clear => "clear",
            .secrets_seen => "secrets_seen",
            .secrets_accessed => "secrets_accessed",
            .dangerous => "dangerous",
        };
    }

    pub fn headline(self: RiskLevel) []const u8 {
        return switch (self) {
            .no_data => "Nothing to scan yet",
            .incomplete => "Scan incomplete",
            .clear => "Looking good",
            .secrets_seen => "Secrets appeared in sessions",
            .secrets_accessed => "Secret access detected",
            .dangerous => "Attention needed",
        };
    }

    pub fn blurb(self: RiskLevel) []const u8 {
        return switch (self) {
            .no_data => "No agent session files were found in known locations for this window.",
            .incomplete => "Some hosts could not be read or are unsupported. Findings may be incomplete.",
            .clear => "No high/medium risky commands or secret exposure in readable hosts for this window.",
            .secrets_seen => "Session text matched secret patterns (values are redacted). Review top findings.",
            .secrets_accessed => "An agent ran commands that touch secret-bearing paths. Review those first.",
            .dangerous => "High or medium risk shell/tool commands showed up in past agent sessions.",
        };
    }
};

fn hasCoverageGaps(sc: types.Scorecard) bool {
    for (sc.hosts) |h| {
        if (h.status == .unreadable or h.status == .unsupported) return true;
    }
    return false;
}

pub fn riskLevel(sc: types.Scorecard) RiskLevel {
    if (sc.danger_count > 0) return .dangerous;
    if (sc.secret_access_count > 0) return .secrets_accessed;
    if (sc.secret_material_count > 0) return .secrets_seen;
    if (sc.sessions_scanned == 0) return .no_data;
    // Do not claim "clear" when some hosts failed to read.
    if (hasCoverageGaps(sc)) return .incomplete;
    return .clear;
}

pub fn windowLabel(sc: types.Scorecard, buf: []u8) []const u8 {
    if (sc.all_time) return "all-time";
    if (sc.window_days) |d| {
        return std.fmt.bufPrint(buf, "last {d} days", .{d}) catch "window";
    }
    return "window";
}

pub fn kindLabel(kind: types.FindingKind) []const u8 {
    return switch (kind) {
        .danger => "risky command",
        .secret_access => "secret access",
        .secret_material => "secret material",
    };
}

pub fn severityShort(sev: types.Severity) []const u8 {
    return switch (sev) {
        .critical => "CRIT",
        .high => "HIGH",
        .medium => "MED",
        .low => "LOW",
    };
}

pub fn hostStatusGlyph(status: types.HostStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .empty => "empty",
        .not_found => "none",
        .unreadable => "err",
        .unsupported => "skip",
    };
}

test "riskLevel: danger beats secrets" {
    var sc: types.Scorecard = .{ .window_days = 30, .all_time = false };
    sc.sessions_scanned = 3;
    sc.secret_material_count = 9;
    sc.danger_count = 1;
    try std.testing.expectEqual(RiskLevel.dangerous, riskLevel(sc));
}

test "riskLevel: empty sessions is no_data" {
    const sc: types.Scorecard = .{ .window_days = 30, .all_time = false };
    try std.testing.expectEqual(RiskLevel.no_data, riskLevel(sc));
}

test "riskLevel: sessions but no findings is clear" {
    var sc: types.Scorecard = .{ .window_days = 30, .all_time = false };
    sc.sessions_scanned = 12;
    try std.testing.expectEqual(RiskLevel.clear, riskLevel(sc));
}

test "riskLevel: unreadable host is incomplete not clear" {
    var sc: types.Scorecard = .{ .window_days = 30, .all_time = false };
    sc.sessions_scanned = 4;
    sc.hosts[0].status = .unreadable;
    try std.testing.expectEqual(RiskLevel.incomplete, riskLevel(sc));
}

test "riskLevel: material only" {
    var sc: types.Scorecard = .{ .window_days = 7, .all_time = false };
    sc.sessions_scanned = 2;
    sc.secret_material_count = 4;
    try std.testing.expectEqual(RiskLevel.secrets_seen, riskLevel(sc));
}

test "windowLabel formats days and all-time" {
    var buf: [32]u8 = undefined;
    var sc: types.Scorecard = .{ .window_days = 30, .all_time = false };
    try std.testing.expectEqualStrings("last 30 days", windowLabel(sc, &buf));
    sc = .{ .window_days = null, .all_time = true };
    try std.testing.expectEqualStrings("all-time", windowLabel(sc, &buf));
}
