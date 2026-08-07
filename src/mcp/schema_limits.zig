const std = @import("std");

const core = @import("ryk_core").core;

pub const implemented = true;

pub const Check = struct {
    ok: bool,
    depth: usize,
    nodes: usize,
    reason: ?[]const u8 = null,
};

pub fn check(value: std.json.Value) Check {
    var max_depth: usize = 0;
    var nodes: usize = 0;
    const ok = walk(value, 0, &max_depth, &nodes) catch |err| {
        return .{
            .ok = false,
            .depth = max_depth,
            .nodes = nodes,
            .reason = switch (err) {
                error.McpSchemaTooDeep => "schema depth exceeds limit",
                error.McpSchemaTooLarge => "schema node count exceeds limit",
            },
        };
    };
    _ = ok;
    return .{ .ok = true, .depth = max_depth, .nodes = nodes };
}

fn walk(value: std.json.Value, depth: usize, max_depth: *usize, nodes: *usize) !void {
    if (depth > core.limits.max_mcp_schema_depth) return error.McpSchemaTooDeep;
    max_depth.* = @max(max_depth.*, depth);
    nodes.* += 1;
    if (nodes.* > core.limits.max_mcp_tool_count * 64) return error.McpSchemaTooLarge;
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try walk(entry.value_ptr.*, depth + 1, max_depth, nodes);
        },
        .array => |array| {
            for (array.items) |item| try walk(item, depth + 1, max_depth, nodes);
        },
        else => {},
    }
}

test "schema limit accepts shallow schema and rejects deep schema" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"type":"object","properties":{"query":{"type":"string"}}}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(check(parsed.value).ok);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < core.limits.max_mcp_schema_depth + 2) : (i += 1) try text.appendSlice(std.testing.allocator, "{\"x\":");
    try text.appendSlice(std.testing.allocator, "null");
    i = 0;
    while (i < core.limits.max_mcp_schema_depth + 2) : (i += 1) try text.append(std.testing.allocator, '}');
    var deep = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text.items, .{});
    defer deep.deinit();
    try std.testing.expect(!check(deep.value).ok);
}
