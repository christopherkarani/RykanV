const std = @import("std");
const builtin = @import("builtin");
const env_util = @import("../env_util.zig");

/// Result of running a host command (e.g. `openclaw plugins uninstall ...` or `hermes ...`)
/// with a timeout guard.
///
/// This is the core primitive to prevent `ryk uninstall` / `disable` from hanging
/// forever when a host CLI misbehaves, prompts unexpectedly, or is slow.
pub const HostCommandResult = struct {
    /// Exit code reported by the child (0-255). On timeout this is typically 255.
    exit_code: u8,
    /// True if we killed the child because it exceeded the deadline.
    timed_out: bool,
    /// Reserved for API compatibility. Host-management commands discard output.
    stdout: ?[]const u8,
    /// Reserved for API compatibility. Host-management commands discard output.
    stderr: ?[]const u8,
};

pub const HostCommandCaptureResult = struct {
    exit_code: u8,
    timed_out: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: HostCommandCaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn deinitHostCommandResult(result: HostCommandResult, allocator: std.mem.Allocator) void {
    if (result.stdout) |s| allocator.free(s);
    if (result.stderr) |s| allocator.free(s);
}

/// Run an external command (intended for host agent CLIs like openclaw/hermes)
/// with a hard timeout. Output is discarded so an untrusted host CLI cannot block
/// ryk by filling a pipe. Current callers only need the exit status.
///
/// On Unix we use a monitoring thread + timer + kill for reliable timeout.
/// On Windows we use a best-effort wait loop + TerminateProcess (weaker guarantees).
///
/// This is deliberately *not* a general-purpose child runner — it is tuned for the
/// "call a potentially flaky host plugin manager and never hang the parent CLI" use case.
///
/// `timeout_ms` of 0 means "no timeout" (use only for tests or very special cases).
pub fn runHostCommandTimed(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !HostCommandResult {
    if (argv.len == 0) return error.InvalidArgv;
    _ = stdout_writer;
    _ = stderr_writer;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    const child_id = child.id.?;

    var timed_out = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    var watcher: ?std.Thread = null;
    if (timeout_ms > 0) {
        watcher = std.Thread.spawn(.{}, struct {
            fn run(id: std.process.Child.Id, watch_io: std.Io, flag: *std.atomic.Value(bool), fin: *std.atomic.Value(bool), ms: u64) void {
                var remaining: u64 = ms;
                const chunk: u64 = 50;
                while (remaining > 0) {
                    if (fin.load(.acquire)) return;
                    const sl = @min(chunk, remaining);
                    const duration = std.Io.Duration.fromMilliseconds(@intCast(sl));
                    std.Io.sleep(watch_io, duration, .awake) catch {};
                    remaining -= sl;
                }
                if (fin.load(.acquire)) return;
                if (builtin.os.tag == .windows) {
                    _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
                } else {
                    std.posix.kill(-id, std.posix.SIG.TERM) catch {};
                    var grace_ms: u64 = 500;
                    while (grace_ms > 0 and !fin.load(.acquire)) {
                        std.Io.sleep(watch_io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                        grace_ms -= 50;
                    }
                    if (!fin.load(.acquire)) std.posix.kill(-id, std.posix.SIG.KILL) catch {};
                }
                flag.store(true, .release);
            }
        }.run, .{ child_id, io, &timed_out, &finished, timeout_ms }) catch |err| {
            child.kill(io);
            return err;
        };
    }

    const term = child.wait(io) catch {
        finished.store(true, .release);
        if (watcher) |w| w.join();
        return HostCommandResult{
            .exit_code = 255,
            .timed_out = timed_out.load(.acquire),
            .stdout = null,
            .stderr = null,
        };
    };
    finished.store(true, .release);
    if (watcher) |w| w.join();

    const exit_code: u8 = switch (term) {
        .exited => |code| @as(u8, @intCast(@min(code, 255))),
        .signal, .stopped, .unknown => 255,
    };

    return HostCommandResult{
        .exit_code = exit_code,
        .timed_out = timed_out.load(.acquire),
        .stdout = null,
        .stderr = null,
    };
}

/// Run a short identity/status probe with bounded output and a hard timeout.
/// Unlike `runHostCommandTimed`, this captures output for callers that must
/// validate which CLI a PATH entry actually represents.
pub fn runHostCommandCaptureTimed(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u32,
) !HostCommandCaptureResult {
    if (argv.len == 0) return error.InvalidArgv;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
    const run_result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.Timeout => {
            const stdout = try allocator.dupe(u8, "");
            errdefer allocator.free(stdout);
            return .{
                .exit_code = 255,
                .timed_out = true,
                .stdout = stdout,
                .stderr = try allocator.dupe(u8, ""),
            };
        },
        else => return err,
    };

    return .{
        .exit_code = switch (run_result.term) {
            .exited => |code| @intCast(@min(code, 255)),
            else => 255,
        },
        .timed_out = false,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
    };
}

const DrainContext = struct {
    file: std.Io.File,
    io: std.Io,
    limit: usize,
    storage: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn run(self: *DrainContext) void {
        var reader_buffer: [4096]u8 = undefined;
        var read_buffer: [4096]u8 = undefined;
        var reader = self.file.reader(self.io, &reader_buffer);
        while (true) {
            const count = reader.interface.readSliceShort(&read_buffer) catch return;
            if (count == 0) return;
            const remaining = self.limit -| self.len;
            const copy_len = @min(remaining, count);
            if (copy_len > 0) {
                @memcpy(self.storage[self.len..][0..copy_len], read_buffer[0..copy_len]);
                self.len += copy_len;
            }
            // Continue draining after the capture limit so a noisy child cannot
            // block while the parent waits for it to exit.
        }
    }
};

/// Run a hook-style child with bounded stdin, concurrent stdout/stderr drains,
/// and a hard timeout. The child process group is terminated on timeout so a
/// spawned grandchild cannot keep the onboarding flow hung.
pub fn runHostCommandInputCaptureTimed(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    timeout_ms: u64,
) !HostCommandCaptureResult {
    if (argv.len == 0) return error.InvalidArgv;
    if (stdin_bytes.len > 256 * 1024) return error.InputTooLong;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    const child_id = child.id.?;

    var stdout_context = DrainContext{
        .file = child.stdout.?,
        .io = io,
        .limit = 64 * 1024,
    };
    var stderr_context = DrainContext{
        .file = child.stderr.?,
        .io = io,
        .limit = 16 * 1024,
    };
    const stdout_thread = std.Thread.spawn(.{}, DrainContext.run, .{&stdout_context}) catch |err| {
        child.kill(io);
        return err;
    };
    const stderr_thread = std.Thread.spawn(.{}, DrainContext.run, .{&stderr_context}) catch |err| {
        child.kill(io);
        stdout_thread.join();
        return err;
    };

    var timed_out = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    var watcher: ?std.Thread = null;
    if (timeout_ms > 0) {
        watcher = std.Thread.spawn(.{}, struct {
            fn run(id: std.process.Child.Id, watch_io: std.Io, did_timeout: *std.atomic.Value(bool), done: *std.atomic.Value(bool), ms: u64) void {
                var remaining = ms;
                while (remaining > 0) {
                    if (done.load(.acquire)) return;
                    const slice = @min(@as(u64, 50), remaining);
                    std.Io.sleep(watch_io, std.Io.Duration.fromMilliseconds(@intCast(slice)), .awake) catch {};
                    remaining -= slice;
                }
                if (done.load(.acquire)) return;
                if (builtin.os.tag == .windows) {
                    _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
                } else {
                    std.posix.kill(-id, std.posix.SIG.TERM) catch {};
                    var grace_ms: u64 = 500;
                    while (grace_ms > 0 and !done.load(.acquire)) {
                        std.Io.sleep(watch_io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                        grace_ms -= 50;
                    }
                    if (!done.load(.acquire)) std.posix.kill(-id, std.posix.SIG.KILL) catch {};
                }
                did_timeout.store(true, .release);
            }
        }.run, .{ child_id, io, &timed_out, &finished, timeout_ms }) catch |err| {
            child.kill(io);
            stdout_thread.join();
            stderr_thread.join();
            return err;
        };
    }

    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, stdin_bytes) catch |err| {
            child.kill(io);
            finished.store(true, .release);
            if (watcher) |thread| thread.join();
            stdout_thread.join();
            stderr_thread.join();
            return err;
        };
        stdin.close(io);
        child.stdin = null;
    }

    const term = child.wait(io) catch blk: {
        child.kill(io);
        break :blk null;
    };
    finished.store(true, .release);
    if (watcher) |thread| thread.join();
    stdout_thread.join();
    stderr_thread.join();

    const stdout = try allocator.dupe(u8, stdout_context.storage[0..stdout_context.len]);
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, stderr_context.storage[0..stderr_context.len]);
    return .{
        .exit_code = if (term) |value| switch (value) {
            .exited => |code| @intCast(@min(code, 255)),
            else => 255,
        } else 255,
        .timed_out = timed_out.load(.acquire),
        .stdout = stdout,
        .stderr = stderr,
    };
}

// ---------------------------------------------------------------------------
// Test doubles / helpers for testing the runner itself without real hangs
// ---------------------------------------------------------------------------

/// Thin wrapper for tests that want to emphasize the timeout path.
/// In practice you can just call runHostCommandTimed with a tiny timeout.
pub fn runHostCommandTimedForTest(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    simulate_timeout_after_ms: ?u64,
) !HostCommandResult {
    _ = simulate_timeout_after_ms;
    return runHostCommandTimed(allocator, argv, timeout_ms, null, null);
}

test "child_process: API surface compiles and deinit is safe on zeroed result" {
    const result: HostCommandResult = .{
        .exit_code = 0,
        .timed_out = false,
        .stdout = null,
        .stderr = null,
    };
    deinitHostCommandResult(result, std.testing.allocator);
}

test "child_process: fast successful command returns reasonable result without hanging (self exe smoke)" {
    const self_exe = std.process.executablePathAlloc(std.testing.io, std.testing.allocator) catch return error.SkipZigTest;
    defer std.testing.allocator.free(self_exe);

    const argv = [_][]const u8{ self_exe, "--help" };
    const res = try runHostCommandTimed(
        std.testing.allocator,
        &argv,
        5_000,
        null,
        null,
    );
    defer deinitHostCommandResult(res, std.testing.allocator);
    try std.testing.expect(!res.timed_out);
}

test "child_process: host command resolves through inherited PATH" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    const res = try runHostCommandTimed(std.testing.allocator, &argv, 5_000, null, null);
    defer deinitHostCommandResult(res, std.testing.allocator);

    try std.testing.expect(!res.timed_out);
    try std.testing.expectEqual(@as(u8, 0), res.exit_code);
}

test "child_process: ignored high-volume output cannot fill a pipe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][]const u8{ "sh", "-c", "yes x | head -c 1048576" };
    const res = try runHostCommandTimed(std.testing.allocator, &argv, 5_000, null, null);
    defer deinitHostCommandResult(res, std.testing.allocator);
    try std.testing.expect(!res.timed_out);
    try std.testing.expectEqual(@as(u8, 0), res.exit_code);
}

test "child_process: bounded capture returns stdout and stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try runHostCommandCaptureTimed(
        std.testing.allocator,
        &.{ "sh", "-c", "printf compatible; printf warning >&2" },
        5_000,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("compatible", result.stdout);
    try std.testing.expectEqualStrings("warning", result.stderr);
}

test "child_process: bounded capture terminates a hung probe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try runHostCommandCaptureTimed(
        std.testing.allocator,
        &.{ "sh", "-c", "sleep 10" },
        50,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expectEqual(@as(u8, 255), result.exit_code);
}

test "child_process: bounded hook runner writes stdin and drains noisy output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try runHostCommandInputCaptureTimed(
        std.testing.allocator,
        &.{ "sh", "-c", "read line; printf '%s' \"$line\"; yes warning | head -n 10000 >&2" },
        "fixture\n",
        5_000,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("fixture", result.stdout);
    try std.testing.expectEqual(@as(usize, 16 * 1024), result.stderr.len);
}

test "child_process: bounded hook runner terminates a hung child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try runHostCommandInputCaptureTimed(
        std.testing.allocator,
        &.{ "sh", "-c", "read line; sleep 10" },
        "fixture\n",
        50,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expectEqual(@as(u8, 255), result.exit_code);
}

test "child_process: timeout escalates when child ignores TERM" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const argv = [_][]const u8{ "sh", "-c", "trap '' TERM; sleep 10" };
    const res = try runHostCommandTimed(std.testing.allocator, &argv, 50, null, null);
    defer deinitHostCommandResult(res, std.testing.allocator);
    try std.testing.expect(res.timed_out);
}
