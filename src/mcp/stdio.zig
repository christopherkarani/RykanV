const std = @import("std");

const core = @import("ryk_core").core;

pub const implemented = true;

pub fn readMessageLine(reader: *std.Io.Reader, allocator: std.mem.Allocator) !?[]u8 {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.McpMessageTooLarge,
        else => return err,
    };
    const bytes = line orelse return null;
    if (bytes.len > core.limits.max_mcp_message_len) return error.McpMessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.mem.indexOfAny(u8, bytes, "\n\r") != null) return error.EmbeddedNewline;
    return try allocator.dupe(u8, bytes);
}

pub fn writeRawMessage(writer: anytype, message: []const u8) !void {
    if (message.len == 0 or message.len > core.limits.max_mcp_message_len) return error.McpMessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
    if (std.mem.indexOfAny(u8, message, "\n\r") != null) return error.EmbeddedNewline;
    try writer.writeAll(message);
    try writer.writeByte('\n');
    // MCP clients on pipes need an immediate flush; full-buffer delay looks like a hung server.
    try writer.flush();
}

pub fn isProtocolCleanOutput(output: []const u8, allocator: std.mem.Allocator) !bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = @import("jsonrpc.zig").parseLine(allocator, line) catch return false;
        parsed.deinit();
    }
    return true;
}

test "stdio reader returns bounded newline-delimited messages" {
    var input: std.Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n");
    const line = try readMessageLine(&input, std.testing.allocator);
    defer std.testing.allocator.free(line.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", line.?);
    try std.testing.expectEqual(@as(?[]u8, null), try readMessageLine(&input, std.testing.allocator));
}

test "stdio writer rejects protocol-corrupting embedded newlines" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.EmbeddedNewline, writeRawMessage(&writer, "{\"jsonrpc\":\"2.0\"}\n{}"));
}

test "protocol clean output rejects human logs on stdout" {
    try std.testing.expect(try isProtocolCleanOutput("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n", std.testing.allocator));
    try std.testing.expect(!try isProtocolCleanOutput("human log\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n", std.testing.allocator));
}
