//! Shared Unix domain socket helpers for the daemon client and IPC tests.

const std = @import("std");
const builtin = @import("builtin");

pub const UnixSockaddr = struct {
    addr: std.c.sockaddr.un,
    len: u32,
};

pub fn sockaddrUnFromPath(path: []const u8) !UnixSockaddr {
    var addr: std.c.sockaddr.un = .{
        .family = @intCast(afUnix()),
        .path = undefined,
    };
    // Never truncate a pathname: doing so can connect to or bind a different
    // socket than the caller requested. A zero-length pathname is likewise not
    // a filesystem socket path.
    if (path.len == 0) return error.InvalidSocketPath;
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    const path_len = path.len;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path_len], path[0..path_len]);
    addr.path[path_len] = 0;

    return .{
        .addr = addr,
        .len = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path_len + 1),
    };
}

test "sockaddrUnFromPath rejects empty and overlong paths" {
    var overlong: [@sizeOf(std.c.sockaddr.un)]u8 = undefined;
    @memset(&overlong, 'a');

    try std.testing.expectError(error.InvalidSocketPath, sockaddrUnFromPath(""));
    try std.testing.expectError(error.SocketPathTooLong, sockaddrUnFromPath(&overlong));
}

pub fn openUnixStreamSocket() !std.posix.fd_t {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedOs;
    const fd = std.c.socket(afUnix(), sockStream(), 0);
    if (fd < 0) return error.SocketConnectFailed;
    return fd;
}

pub fn connectUnixSocket(path: []const u8) !std.posix.fd_t {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedOs;
    const fd = try openUnixStreamSocket();
    errdefer _ = std.c.close(fd);

    const sockaddr = try sockaddrUnFromPath(path);
    const rc = std.c.connect(fd, @ptrCast(&sockaddr.addr), sockaddr.len);
    if (rc < 0) return error.SocketConnectFailed;
    return fd;
}

pub fn bindListenUnixSocket(path: []const u8) !std.posix.fd_t {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedOs;
    unlinkUnixSocketPath(path);

    const fd = try openUnixStreamSocket();
    errdefer _ = std.c.close(fd);

    const sockaddr = try sockaddrUnFromPath(path);
    if (std.c.bind(fd, @ptrCast(&sockaddr.addr), sockaddr.len) < 0) return error.SocketConnectFailed;
    if (std.c.listen(fd, 1) < 0) return error.SocketConnectFailed;
    return fd;
}

pub fn unlinkUnixSocketPath(path: []const u8) void {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    if (path.len >= std.fs.max_path_bytes) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&path_buf));
}

fn afUnix() c_uint {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.posix.AF.UNIX),
        .macos => 1,
        else => 0,
    };
}

fn sockStream() c_uint {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.posix.SOCK.STREAM),
        .macos => 1,
        else => 0,
    };
}
