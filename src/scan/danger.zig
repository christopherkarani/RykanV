//! Danger evaluation via shell_engine (historical forensics; not live mediation).
const std = @import("std");
const shell_engine = @import("../shell_engine/mod.zig");
const types = @import("types.zig");
const secrets = @import("secrets.zig");

pub const DangerHit = struct {
    severity: types.Severity,
    reason: []const u8,
    rule_id: ?[]const u8 = null,
    pattern_name: ?[]const u8 = null,

    pub fn deinit(self: *DangerHit, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        if (self.rule_id) |s| allocator.free(s);
        if (self.pattern_name) |s| allocator.free(s);
        self.* = undefined;
    }
};

/// Evaluate a candidate command with shell_engine. Returns a hit only for
/// medium+ severity findings (default cut). Does not consume allow-once.
pub fn evaluateDanger(
    allocator: std.mem.Allocator,
    command: []const u8,
) !?DangerHit {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;

    // evaluateCommand error set is allocator-only; never invent a high finding from OOM.
    var eval = try shell_engine.evaluateCommand(allocator, trimmed, .{
        .default_packs_only = true,
        .consume_allow_once = false,
        // Historical scan: do not apply permanent allowlist exceptions — surface risk as-written.
        .permanent_allowlist = null,
        .allow_once_path = null,
        .now_iso = null,
    });
    defer eval.deinit(allocator);

    if (eval.decision != .deny) return null;
    if (!types.severityMeetsDefaultCut(eval.severity)) return null;

    const reason = try secrets.safeDetail(allocator, eval.reason);
    errdefer allocator.free(reason);
    const rule_id = if (eval.rule_id) |r| try allocator.dupe(u8, r) else null;
    errdefer if (rule_id) |r| allocator.free(r);
    const pattern_name = if (eval.pattern_name) |p| try allocator.dupe(u8, p) else null;
    errdefer if (pattern_name) |p| allocator.free(p);

    return .{
        .severity = eval.severity,
        .reason = reason,
        .rule_id = rule_id,
        .pattern_name = pattern_name,
    };
}

test "danger keeps high medium drops low-allow" {
    // rm -rf / is a classic high/critical deny.
    const hit = try evaluateDanger(std.testing.allocator, "rm -rf /");
    try std.testing.expect(hit != null);
    var h = hit.?;
    defer h.deinit(std.testing.allocator);
    try std.testing.expect(types.severityMeetsDefaultCut(h.severity));

    // Benign allow should not produce a danger finding.
    const allow = try evaluateDanger(std.testing.allocator, "git status");
    try std.testing.expect(allow == null);
}

test "danger empty command is null" {
    try std.testing.expect(try evaluateDanger(std.testing.allocator, "   ") == null);
}
