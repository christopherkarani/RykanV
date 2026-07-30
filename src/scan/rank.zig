//! Ranking and default list cap for scan findings.
const std = @import("std");
const types = @import("types.zig");

fn lessThan(_: void, a: types.Finding, b: types.Finding) bool {
    // Higher severity first.
    const sa = types.severityRank(a.severity);
    const sb = types.severityRank(b.severity);
    if (sa != sb) return sa > sb;
    // Prefer secrets when severity ties.
    const ka = a.kind.rankWeight();
    const kb = b.kind.rankWeight();
    if (ka != kb) return ka > kb;
    // Newer first.
    if (a.timestamp_secs != b.timestamp_secs) return a.timestamp_secs > b.timestamp_secs;
    return false;
}

pub fn sortFindings(findings: []types.Finding) void {
    std.mem.sort(types.Finding, findings, {}, lessThan);
}

/// Cap the list for display. Returns the slice to show (prefix of sorted array).
pub fn applyCap(findings: []types.Finding, show_all: bool, cap: usize) []types.Finding {
    if (show_all or findings.len <= cap) return findings;
    return findings[0..cap];
}

test "default cap truncates to 20" {
    var items: [25]types.Finding = undefined;
    for (&items, 0..) |*f, i| {
        f.* = .{
            .kind = .danger,
            .severity = if (i < 5) .high else .medium,
            .host = .claude,
            .session_id = "s",
            .path = "p",
            .timestamp_secs = @intCast(1000 - i),
            .title = "t",
            .detail = "d",
            .evidence_ref = "e",
        };
    }
    sortFindings(&items);
    const shown = applyCap(&items, false, types.default_list_cap);
    try std.testing.expectEqual(@as(usize, 20), shown.len);
    const all = applyCap(&items, true, types.default_list_cap);
    try std.testing.expectEqual(@as(usize, 25), all.len);
    // High severity should be first.
    try std.testing.expect(shown[0].severity == .high);
}

test "secrets rank above danger at same severity" {
    var items = [_]types.Finding{
        .{
            .kind = .danger,
            .severity = .high,
            .host = .claude,
            .session_id = "s",
            .path = "p",
            .timestamp_secs = 100,
            .title = "danger",
            .detail = "d",
            .evidence_ref = "e",
        },
        .{
            .kind = .secret_material,
            .severity = .high,
            .host = .claude,
            .session_id = "s",
            .path = "p",
            .timestamp_secs = 50,
            .title = "secret",
            .detail = "d",
            .evidence_ref = "e",
        },
    };
    sortFindings(&items);
    try std.testing.expect(items[0].kind == .secret_material);
}
