const std = @import("std");
const builtin = @import("builtin");
const ryk = @import("ryk");

const daemon = ryk.cli.daemon;
const mock = @import("helpers/daemon_uds_mock.zig");

const max_response_line_bytes: usize = 1024 * 1024;

test "sendRequest rejects oversized NDJSON response line" {
    if (builtin.os.tag == .windows) return;

    const socket_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/ryk-ipc-oversized-{d}.sock", .{std.c.getpid()});
    defer std.testing.allocator.free(socket_path);

    var server = try mock.MockServer.startOversized(socket_path, max_response_line_bytes + 64);
    defer server.deinit();

    const result = daemon.sendRequestWithTimeout(std.testing.allocator, socket_path, .{
        .id = 1,
        .method = "Ping",
        .params = null,
    }, daemon.default_request_timeout_ms);
    try std.testing.expectError(error.SocketReadFailed, result);
}

test "sendRequest times out when peer never sends newline" {
    if (builtin.os.tag == .windows) return;

    const timeout_ms: u64 = 200;

    const socket_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/ryk-ipc-hang-{d}.sock", .{std.c.getpid()});
    defer std.testing.allocator.free(socket_path);

    var server = try mock.MockServer.startHang(socket_path);
    defer server.deinit();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const start_ms = daemon.monotonicNowMsForTest(io);
    const result = daemon.sendRequestWithTimeout(std.testing.allocator, socket_path, .{
        .id = 1,
        .method = "Ping",
        .params = null,
    }, timeout_ms);
    const elapsed_ms: u64 = @intCast(@max(daemon.monotonicNowMsForTest(io) - start_ms, 0));

    try std.testing.expectError(error.SocketReadFailed, result);
    try std.testing.expect(elapsed_ms >= timeout_ms - 50);
    try std.testing.expect(elapsed_ms <= timeout_ms + 400);
}

test "validateBinaryInspection refuses untrusted RYK_DAEMON inspection" {
    const path = try std.testing.allocator.dupe(u8, "/tmp/world-writable-ryk-daemon");
    defer std.testing.allocator.free(path);

    const inspection = daemon.DaemonBinaryInspection{
        .path = path,
        .source = .env_override,
        .exists = true,
        .executable = true,
        .untrusted = true,
    };

    try std.testing.expectError(error.DaemonBinaryUntrusted, daemon.validateBinaryInspection(inspection));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "checkCompatibility refuses world-writable RYK_DAEMON override" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "ryk-daemon", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try tmp.dir.setFilePermissions(std.testing.io, "ryk-daemon", std.Io.File.Permissions.fromMode(0o777), .{});

    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);

    const prior = std.c.getenv("RYK_DAEMON");
    defer {
        if (prior) |old| {
            _ = setenv("RYK_DAEMON", old, 1);
        } else {
            _ = unsetenv("RYK_DAEMON");
        }
    }
    try std.testing.expectEqual(@as(c_int, 0), setenv("RYK_DAEMON", path_z.ptr, 1));

    const result = daemon.checkCompatibility(std.testing.allocator);
    try std.testing.expectError(error.DaemonBinaryUntrusted, result);
}
