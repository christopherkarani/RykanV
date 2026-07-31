const std = @import("std");

const core = @import("ryk_core").core;
const jsonrpc = @import("jsonrpc.zig");

pub const implemented = true;

pub fn readUri(value: std.json.Value) ?[]const u8 {
    const params = jsonrpc.paramsOf(value) orelse return null;
    if (params != .object) return null;
    const uri = params.object.get("uri") orelse return null;
    if (uri != .string or uri.string.len == 0) return null;
    return uri.string;
}

pub fn targetDisplay(allocator: std.mem.Allocator, server_name: []const u8, uri: []const u8) ![]u8 {
    const bounded = if (uri.len > 1024) uri[0..1024] else uri;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ server_name, bounded });
}

pub fn listTargetDisplay(allocator: std.mem.Allocator, server_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}: resources/list", .{server_name});
}

pub fn isSensitiveUri(uri: []const u8) bool {
    if (std.mem.startsWith(u8, uri, "file://")) return true;
    if (std.mem.startsWith(u8, uri, "~/")) return true;
    if (std.mem.startsWith(u8, uri, "/Users/")) return true;
    if (std.mem.startsWith(u8, uri, "/home/")) return true;
    return containsIgnoreCase(uri, ".ssh") or
        containsIgnoreCase(uri, ".aws") or
        containsIgnoreCase(uri, ".config/gh") or
        containsIgnoreCase(uri, "credential") or
        containsIgnoreCase(uri, "secret") or
        containsIgnoreCase(uri, "token") or
        containsIgnoreCase(uri, "password") or
        containsIgnoreCase(uri, ".env");
}

pub fn responseTooLarge(response: []const u8) bool {
    return response.len > core.limits.max_event_field_len;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "sensitive resource URI classification is conservative" {
    try std.testing.expect(isSensitiveUri("file:///Users/alice/.ssh/id_rsa"));
    try std.testing.expect(isSensitiveUri("~/Library/Application Support/gh/hosts.yml"));
    try std.testing.expect(isSensitiveUri("repo://docs/.env"));
    try std.testing.expect(!isSensitiveUri("repo://docs/README.md"));
}
