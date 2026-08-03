const std = @import("std");

const core = @import("orca_core").core;

pub const implemented = true;

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    policy_denied = -32001,
    message_too_large = -32002,
};

pub const ParsedMessage = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ParsedMessage) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn value(self: *const ParsedMessage) std.json.Value {
        return self.parsed.value;
    }

    pub fn method(self: *const ParsedMessage) ?[]const u8 {
        return methodOf(self.parsed.value);
    }

    pub fn id(self: *const ParsedMessage) ?std.json.Value {
        return idOf(self.parsed.value);
    }
};

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !ParsedMessage {
    if (line.len == 0 or line.len > core.limits.max_mcp_message_len) return error.McpMessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
    if (std.mem.indexOfAny(u8, line, "\n\r") != null) return error.EmbeddedNewline;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidJsonRpc;
    errdefer parsed.deinit();
    try validateJsonRpc(parsed.value);
    return .{ .parsed = parsed };
}

pub fn validateJsonRpc(value: std.json.Value) !void {
    if (value != .object) return error.InvalidJsonRpc;
    const object = value.object;
    const version = object.get("jsonrpc") orelse return error.InvalidJsonRpc;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidJsonRpc;
    if (object.get("id")) |id_value| try validateId(id_value);
    if (object.get("method")) |method| {
        if (method != .string or method.string.len == 0) return error.InvalidJsonRpc;
        if (object.get("result") != null or object.get("error") != null) return error.InvalidJsonRpc;
        return;
    }
    const has_result = object.get("result") != null;
    const has_error = object.get("error") != null;
    if (has_result or has_error) {
        if (object.get("id") == null) return error.InvalidJsonRpc;
        if (has_result and has_error) return error.InvalidJsonRpc;
        return;
    }
    return error.InvalidJsonRpc;
}

pub fn idEquals(left: ?std.json.Value, right: ?std.json.Value) bool {
    if (left == null or right == null) return left == null and right == null;
    const a = left.?;
    const b = right.?;
    return switch (a) {
        .null => b == .null,
        .string => |string| b == .string and std.mem.eql(u8, string, b.string),
        .integer => |integer| b == .integer and integer == b.integer,
        else => false,
    };
}

fn validateId(id_value: std.json.Value) !void {
    switch (id_value) {
        .string => |string| {
            if (string.len > 256) return error.InvalidJsonRpc;
        },
        .integer, .null => {},
        else => return error.InvalidJsonRpc,
    }
}

pub fn methodOf(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const method = value.object.get("method") orelse return null;
    if (method != .string) return null;
    return method.string;
}

pub fn idOf(value: std.json.Value) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get("id");
}

pub fn paramsOf(value: std.json.Value) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get("params");
}

pub fn toolCallName(value: std.json.Value) ?[]const u8 {
    const params = paramsOf(value) orelse return null;
    if (params != .object) return null;
    const name = params.object.get("name") orelse return null;
    if (name != .string or name.string.len == 0) return null;
    return name.string;
}

pub fn toolCallArguments(value: std.json.Value) ?std.json.Value {
    const params = paramsOf(value) orelse return null;
    if (params != .object) return null;
    return params.object.get("arguments");
}

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value, max_len: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    if (out.writer.end > max_len) return error.McpMessageTooLarge;
    return try out.toOwnedSlice();
}

pub fn writeMessage(writer: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

pub fn writeErrorResponse(writer: anytype, id: ?std.json.Value, code: ErrorCode, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
    try writer.print("{d}", .{@intFromEnum(code)});
    try writer.writeAll(",\"message\":");
    try core.util.writeJsonString(writer, message);
    try writer.writeAll("},\"id\":");
    if (id) |id_value| {
        try writeIdValue(writer, id_value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

pub fn errorResponseAlloc(allocator: std.mem.Allocator, id: ?std.json.Value, code: ErrorCode, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeErrorResponse(&out.writer, id, code, message);
    return try out.toOwnedSlice();
}

fn writeIdValue(writer: anytype, id_value: std.json.Value) !void {
    switch (id_value) {
        .string => |string| try core.util.writeJsonString(writer, string),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .null => try writer.writeAll("null"),
        else => try writer.writeAll("null"),
    }
}

test "parse valid request and reject invalid json-rpc" {
    var parsed = try parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("initialize", parsed.method().?);

    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"id\":1,\"method\":\"initialize\"}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "not-json"));
}

test "parser rejects embedded raw newlines and oversized messages" {
    try std.testing.expectError(error.EmbeddedNewline, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\"\n}"));

    const oversized = try std.testing.allocator.alloc(u8, core.limits.max_mcp_message_len + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.McpMessageTooLarge, parseLine(std.testing.allocator, oversized));
}

test "error response is valid json-rpc and keeps id" {
    var parsed = try parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"tools/call\",\"params\":{\"name\":\"delete_repository\"}}");
    defer parsed.deinit();
    const response = try errorResponseAlloc(std.testing.allocator, parsed.id(), .policy_denied, "MCP tool call denied by policy");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.endsWith(u8, response, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "-32001") != null);
}

test "parser rejects malformed json-rpc ids" {
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"tools/list\"}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":[],\"method\":\"tools/list\"}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"tools/list\"}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"tools/list\"}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"result\":{}}"));
}

test "parser rejects mixed request and response shapes" {
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"result\":{}}"));
    try std.testing.expectError(error.InvalidJsonRpc, parseLine(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-1,\"message\":\"x\"}}"));
}
