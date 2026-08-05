//! Pure MCP policy setup table formatting for `ryk doctor`.
//! Diagnose-only: never rewrites policy.

const std = @import("std");

pub const McpPolicySummary = struct {
    present: bool = false,
    valid: bool = false,
    default_decision: []const u8 = "unknown",
    allow_count: usize = 0,
    deny_count: usize = 0,
    ask_count: usize = 0,
};

pub const InventoryRow = struct {
    tool_or_pattern: []const u8,
    policy_today: []const u8,
    suggest: []const u8,
};

/// Format the MCP setup section for doctor output.
/// Caller owns nothing; writes into `writer`.
pub fn formatMcpSetupTable(
    writer: anytype,
    summary: McpPolicySummary,
    inventory: []const InventoryRow,
    manifest_count: usize,
    manifest_invalid: usize,
) !void {
    try writer.writeAll("MCP policy (.orca/policy.yaml):\n");
    if (!summary.present) {
        try writer.writeAll("  default: (no policy file)\n");
        try writer.writeAll("  allow:  0 patterns   deny: 0 patterns\n");
    } else if (!summary.valid) {
        try writer.writeAll("  default: (policy invalid — fix before trusting MCP rules)\n");
        try writer.print("  allow:  {d} patterns   deny: {d} patterns (unverified)\n", .{
            summary.allow_count,
            summary.deny_count,
        });
    } else {
        try writer.print("  default: {s}\n", .{summary.default_decision});
        try writer.print("  allow:  {d} patterns   deny: {d} patterns", .{
            summary.allow_count,
            summary.deny_count,
        });
        if (summary.ask_count > 0) {
            try writer.print("   ask: {d} patterns", .{summary.ask_count});
        }
        try writer.writeAll("\n");
    }

    if (manifest_count == 0) {
        try writer.writeAll("  manifests under .orca/mcp: none\n");
    } else {
        try writer.print("  manifests under .orca/mcp: {d} found, {d} invalid\n", .{
            manifest_count,
            manifest_invalid,
        });
    }

    if (inventory.len == 0) {
        try writer.writeAll("Host MCP inventory (best-effort): none discovered\n");
    } else {
        try writer.writeAll("Host MCP inventory (best-effort):\n");
        try writer.writeAll("  tool/server          | policy today | suggest\n");
        try writer.writeAll("  ---------------------|--------------|--------\n");
        for (inventory) |row| {
            try writer.print("  {s:<21}| {s:<13}| {s}\n", .{
                truncatePad(row.tool_or_pattern, 21),
                truncatePad(row.policy_today, 13),
                row.suggest,
            });
        }
    }

    try writer.writeAll("Next: edit .orca/policy.yaml mcp:  (doctor does not rewrite policy on diagnose)\n");
    try writer.writeAll("  Tip: for Pi subagents, parent session must load the managed ryk extension;\n");
    try writer.writeAll("  session grants and parent-forward ask fail closed if parent is unavailable.\n");
}

fn truncatePad(value: []const u8, width: usize) []const u8 {
    // For formatting we only need a view; pad is applied via `{s:<N}` when short.
    // When long, print a truncated prefix — caller may pass already-short names.
    if (value.len <= width) return value;
    return value[0..width];
}

/// Suggest rows for common safe read/list patterns and Pi orchestrator bare names.
pub fn suggestedInventoryRows(
    summary: McpPolicySummary,
    allow_patterns: []const []const u8,
) [5]InventoryRow {
    const list_status = statusForPattern(summary, allow_patterns, "*.list_*");
    const get_status = statusForPattern(summary, allow_patterns, "*.get_*");
    const subagent_status = statusForPattern(summary, allow_patterns, "subagent");
    const skill_status = statusForPattern(summary, allow_patterns, "skill");
    const task_status = statusForPattern(summary, allow_patterns, "task");

    return .{
        .{
            .tool_or_pattern = "*.list_*",
            .policy_today = list_status.label,
            .suggest = list_status.suggest,
        },
        .{
            .tool_or_pattern = "*.get_*",
            .policy_today = get_status.label,
            .suggest = get_status.suggest,
        },
        .{
            .tool_or_pattern = "subagent",
            .policy_today = subagent_status.label,
            .suggest = if (subagent_status.allowed)
                "—"
            else
                "allow if you use Pi subagents",
        },
        .{
            .tool_or_pattern = "skill",
            .policy_today = skill_status.label,
            .suggest = if (skill_status.allowed) "—" else "allow if you use Pi skills",
        },
        .{
            .tool_or_pattern = "task",
            .policy_today = task_status.label,
            .suggest = if (task_status.allowed) "—" else "allow if you use Pi task tools",
        },
    };
}

const PatternStatus = struct {
    label: []const u8,
    suggest: []const u8,
    allowed: bool,
};

fn statusForPattern(
    summary: McpPolicySummary,
    allow_patterns: []const []const u8,
    needle: []const u8,
) PatternStatus {
    if (!summary.present) {
        return .{ .label = "no policy", .suggest = "add policy first", .allowed = false };
    }
    if (!summary.valid) {
        return .{ .label = "invalid", .suggest = "fix policy", .allowed = false };
    }
    for (allow_patterns) |pattern| {
        if (std.mem.eql(u8, pattern, needle)) {
            return .{ .label = "allow", .suggest = "—", .allowed = true };
        }
    }
    // default ask means unknown tools ask
    if (std.mem.eql(u8, summary.default_decision, "deny")) {
        return .{ .label = "deny (default)", .suggest = "allow if needed", .allowed = false };
    }
    return .{ .label = "ask (default)", .suggest = "allow if you use it", .allowed = false };
}

test "formatMcpSetupTable renders default ask and inventory" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const summary = McpPolicySummary{
        .present = true,
        .valid = true,
        .default_decision = "ask",
        .allow_count = 3,
        .deny_count = 2,
        .ask_count = 0,
    };
    const allow = [_][]const u8{ "*.list_*", "*.get_*" };
    const rows = suggestedInventoryRows(summary, &allow);

    try formatMcpSetupTable(
        &aw.writer,
        summary,
        &rows,
        1,
        0,
    );
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "MCP policy (.orca/policy.yaml):") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "default: ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "allow:  3 patterns") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "deny: 2 patterns") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Host MCP inventory") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "allow if you use Pi subagents") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "does not rewrite policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "parent session must load") != null);
}

test "formatMcpSetupTable handles missing policy" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try formatMcpSetupTable(
        &aw.writer,
        .{},
        &.{},
        0,
        0,
    );
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "no policy file") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "none discovered") != null);
}
