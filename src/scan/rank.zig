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

/// Weak/placeholder fingerprints must not collapse distinct secrets together.
fn isStrongFingerprint(fp: []const u8) bool {
    if (fp.len < 8) return false;
    // classifyMaterial fallback when no digest is available.
    if (std.mem.eql(u8, fp, "00000000")) return false;
    var all_zero = true;
    for (fp) |c| {
        if (c != '0') {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return false;
    return true;
}

/// Collapse secret_material rows that share the same fingerprint (across hosts/sessions).
/// Keeps the highest-ranked (already sorted) hit and bumps `occurrence_count`.
/// Frees dropped findings. In-place on an ArrayList-style slice via comptime allocator.
/// Weak fingerprints (empty / all-zero placeholders) are never merged.
pub fn collapseSecretFingerprints(allocator: std.mem.Allocator, findings: *std.ArrayList(types.Finding)) void {
    if (findings.items.len < 2) return;
    var write: usize = 0;
    var i: usize = 0;
    while (i < findings.items.len) : (i += 1) {
        const cur = findings.items[i];
        if (cur.kind == .secret_material) {
            if (cur.secret_fingerprint) |fp| {
                if (isStrongFingerprint(fp)) {
                    var merged = false;
                    var j: usize = 0;
                    while (j < write) : (j += 1) {
                        const prev = findings.items[j];
                        if (prev.kind != .secret_material) continue;
                        const pfp = prev.secret_fingerprint orelse continue;
                        if (!isStrongFingerprint(pfp)) continue;
                        if (std.mem.eql(u8, pfp, fp)) {
                            findings.items[j].occurrence_count += cur.occurrence_count;
                            // Prefer keeping the newer timestamp already in `prev` (sorted).
                            var drop = findings.items[i];
                            drop.deinit(allocator);
                            merged = true;
                            break;
                        }
                    }
                    if (merged) continue;
                }
            }
        }
        if (write != i) findings.items[write] = findings.items[i];
        write += 1;
    }
    findings.shrinkRetainingCapacity(write);
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

test "collapseSecretFingerprints merges same fp" {
    var list: std.ArrayList(types.Finding) = .empty;
    defer {
        for (list.items) |*f| f.deinit(std.testing.allocator);
        list.deinit(std.testing.allocator);
    }
    const fp = "deadbeef";
    try list.append(std.testing.allocator, .{
        .kind = .secret_material,
        .severity = .high,
        .host = .codex,
        .session_id = try std.testing.allocator.dupe(u8, "s1"),
        .path = try std.testing.allocator.dupe(u8, "p1"),
        .timestamp_secs = 200,
        .title = try std.testing.allocator.dupe(u8, "t1"),
        .detail = try std.testing.allocator.dupe(u8, "Value hidden"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:high_entropy"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, fp),
        .evidence_ref = try std.testing.allocator.dupe(u8, "e1"),
        .occurrence_count = 1,
    });
    try list.append(std.testing.allocator, .{
        .kind = .secret_material,
        .severity = .high,
        .host = .grok,
        .session_id = try std.testing.allocator.dupe(u8, "s2"),
        .path = try std.testing.allocator.dupe(u8, "p2"),
        .timestamp_secs = 100,
        .title = try std.testing.allocator.dupe(u8, "t2"),
        .detail = try std.testing.allocator.dupe(u8, "Value hidden"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:high_entropy"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, fp),
        .evidence_ref = try std.testing.allocator.dupe(u8, "e2"),
        .occurrence_count = 1,
    });
    try list.append(std.testing.allocator, .{
        .kind = .danger,
        .severity = .high,
        .host = .claude,
        .session_id = try std.testing.allocator.dupe(u8, "s3"),
        .path = try std.testing.allocator.dupe(u8, "p3"),
        .timestamp_secs = 150,
        .title = try std.testing.allocator.dupe(u8, "danger"),
        .detail = try std.testing.allocator.dupe(u8, "rm -rf /"),
        .evidence_ref = try std.testing.allocator.dupe(u8, "e3"),
    });
    sortFindings(list.items);
    collapseSecretFingerprints(std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    var saw_merged = false;
    for (list.items) |f| {
        if (f.kind == .secret_material) {
            try std.testing.expectEqual(@as(usize, 2), f.occurrence_count);
            saw_merged = true;
        }
    }
    try std.testing.expect(saw_merged);
}

test "collapseSecretFingerprints does not merge weak fingerprints" {
    var list: std.ArrayList(types.Finding) = .empty;
    defer {
        for (list.items) |*f| f.deinit(std.testing.allocator);
        list.deinit(std.testing.allocator);
    }
    const weak = "00000000";
    try list.append(std.testing.allocator, .{
        .kind = .secret_material,
        .severity = .high,
        .host = .codex,
        .session_id = try std.testing.allocator.dupe(u8, "s1"),
        .path = try std.testing.allocator.dupe(u8, "p1"),
        .timestamp_secs = 200,
        .title = try std.testing.allocator.dupe(u8, "t1"),
        .detail = try std.testing.allocator.dupe(u8, "Value hidden"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:embedded"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, weak),
        .evidence_ref = try std.testing.allocator.dupe(u8, "e1"),
        .occurrence_count = 1,
    });
    try list.append(std.testing.allocator, .{
        .kind = .secret_material,
        .severity = .high,
        .host = .grok,
        .session_id = try std.testing.allocator.dupe(u8, "s2"),
        .path = try std.testing.allocator.dupe(u8, "p2"),
        .timestamp_secs = 100,
        .title = try std.testing.allocator.dupe(u8, "t2"),
        .detail = try std.testing.allocator.dupe(u8, "Value hidden"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:embedded"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, weak),
        .evidence_ref = try std.testing.allocator.dupe(u8, "e2"),
        .occurrence_count = 1,
    });
    collapseSecretFingerprints(std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}
