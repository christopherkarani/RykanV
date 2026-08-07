const std = @import("std");

const core_api = @import("ryk_core").api;
const core = @import("ryk_core").core;

pub fn redactOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return core_api.redactAlloc(allocator, value);
}

pub fn writeJsonString(allocator: std.mem.Allocator, writer: anytype, value: []const u8) !void {
    const redacted = try redactOwned(allocator, value);
    defer allocator.free(redacted);
    try core.util.writeJsonString(writer, redacted);
}