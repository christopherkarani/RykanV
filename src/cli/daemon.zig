//! Daemon binary discovery, UDS connectivity, and NDJSON IPC (Zig side).
//!
//! This module provides utilities for the Zig CLI to locate the Rust
//! `ryk-daemon` companion binary, check whether a daemon instance is
//! already running, start it when needed, and exchange request/response
//! messages over a Unix Domain Socket.
//!
//! Phase 0.5: UDS socket connectivity and NDJSON IPC.
//! Phase 1D: lifecycle helpers, binary discovery, stale artifact handling.

const std = @import("std");
const builtin = @import("builtin");
const env_util = @import("../env_util.zig");
const daemon_trust = @import("daemon_trust.zig");
const daemon_uds = @import("daemon_uds.zig");

pub const errors = @import("daemon_errors.zig");
pub const trust = daemon_trust;
pub const uds = daemon_uds;

/// Name of the Rust daemon binary.
const daemon_binary_name = if (builtin.os.tag == .windows) "ryk-daemon.exe" else "ryk-daemon";

/// Name of the Unix Domain Socket file used to detect a running daemon.
const daemon_socket_name = "daemon.sock";

/// PID file written by the Rust daemon on startup.
const daemon_pid_name = "daemon.pid";

/// Directory under $HOME where ryk runtime state lives.
const ryk_state_dir = ".ryk";

/// Environment variable override for the daemon binary path.
const daemon_env_var = "RYK_DAEMON";
const expected_protocol_version: i64 = 1;
const expected_protocol_label = "orca-uds-v1";
const required_capabilities = [_][]const u8{ "Ping", "Evaluate", "ExecuteCli", "ExecuteCliCwd", "Shutdown" };

/// Default time to wait for the daemon socket and Ping response after spawn.
pub const default_readiness_timeout_ms: u64 = 5_000;

/// Poll interval while waiting for daemon readiness.
const readiness_poll_ms: u64 = 50;

/// Per-request UDS timeout for Ping and other daemon IPC.
pub const default_request_timeout_ms: u64 = 500;

/// Maximum NDJSON response line accepted from the daemon.
const max_response_line_bytes: usize = 1024 * 1024;

/// Short Ping timeout used when deciding whether socket artifacts are stale.
const stale_artifact_ping_timeout_ms: u64 = 200;

/// Request envelope sent to the Rust daemon over UDS.
///
/// The wire format is newline-delimited JSON matching the Rust
/// `ClientEnvelope` struct: `{"id": 1, "method": "Ping"}`.
pub const DaemonRequest = struct {
    id: u64,
    method: []const u8,
    params: ?std.json.Value = null,
};

/// Response envelope returned by the Rust daemon.
///
/// The `result` field is kept as a `std.json.Value` so the Zig client can
/// inspect the `status` tag without mirroring the full Rust enum.
pub const DaemonResponse = struct {
    id: u64,
    result: std.json.Value,
};

/// Structured result returned by the Rust daemon for ExecuteCli requests.
pub const CliExecution = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

const ExecuteCliRequest = struct {
    id: u64,
    method: []const u8 = "ExecuteCli",
    params: struct {
        argv: []const []const u8,
    },
};

const ExecuteCliAtRequest = struct {
    id: u64,
    method: []const u8 = "ExecuteCli",
    params: struct {
        argv: []const []const u8,
        cwd: []const u8,
    },
};

const EvaluateRequest = struct {
    id: u64,
    method: []const u8 = "Evaluate",
    params: struct {
        command: []const u8,
        cwd: ?[]const u8 = null,
    },
};

/// High-level status tag from a daemon `result` object.
pub const ResponseStatus = enum {
    pong,
    allow,
    deny,
    error_status,
    cli_execution,
    unknown,
};

/// Errors that can occur when communicating with the daemon.
pub const DaemonError = error{
    HomeDirectoryNotFound,
    OutOfMemory,
    DaemonBinaryNotFound,
    DaemonBinaryNotExecutable,
    DaemonBinaryUntrusted,
    DaemonSpawnFailed,
    DaemonStartTimeout,
    DaemonNotReady,
    StaleSocket,
    SocketConnectFailed,
    SocketWriteFailed,
    SocketReadFailed,
    InvalidWorkingDirectory,
    RequestSerializationFailed,
    ResponseParseFailed,
    DaemonProtocolError,
    MissingHandshake,
    HandshakeMalformed,
    ProtocolMismatch,
    /// `RYK_SHELL_EVAL=rust` requested; Rust daemon Evaluate is no longer a product path.
    RustShellEvalRemoved,
};

pub const DaemonBinarySource = enum {
    env_override,
    adjacent,
    dev_release,
    dev_debug,
};

pub const DaemonBinaryInspection = struct {
    path: []const u8,
    source: DaemonBinarySource,
    exists: bool,
    executable: bool,
    /// True when `RYK_DAEMON` points at a world-writable path (other-write bit set).
    untrusted: bool = false,

    pub fn deinit(self: DaemonBinaryInspection, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

var ensure_daemon_lock: std.Io.Mutex = .init;

/// Resolve `$HOME/.ryk/daemon.sock` and `$HOME/.ryk/daemon.pid`.
pub const RuntimePaths = struct {
    socket: []const u8,
    pid: []const u8,
};

/// Build runtime artifact paths under the given home directory.
///
/// Caller owns both returned slices.
pub fn runtimePathsForHome(allocator: std.mem.Allocator, home: []const u8) !RuntimePaths {
    const state_dir = try std.fs.path.join(allocator, &.{ home, ryk_state_dir });
    defer allocator.free(state_dir);

    return .{
        .socket = try std.fs.path.join(allocator, &.{ state_dir, daemon_socket_name }),
        .pid = try std.fs.path.join(allocator, &.{ state_dir, daemon_pid_name }),
    };
}

/// Resolve daemon runtime paths from `$HOME`.
pub fn runtimePaths(allocator: std.mem.Allocator) DaemonError!RuntimePaths {
    const home = (getEnvVar(allocator, "HOME") catch return error.HomeDirectoryNotFound) orelse
        return error.HomeDirectoryNotFound;
    defer allocator.free(home);
    return runtimePathsForHome(allocator, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return e,
    };
}

/// Resolve the daemon socket path: `$HOME/.ryk/daemon.sock`.
///
/// Caller owns the returned memory.
pub fn socketPath(allocator: std.mem.Allocator) DaemonError![]const u8 {
    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);
    return allocator.dupe(u8, paths.socket) catch error.OutOfMemory;
}

/// Resolve the daemon PID file path: `$HOME/.ryk/daemon.pid`.
///
/// Caller owns the returned memory.
pub fn pidPath(allocator: std.mem.Allocator) DaemonError![]const u8 {
    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);
    return allocator.dupe(u8, paths.pid) catch error.OutOfMemory;
}

pub fn freeRuntimePaths(allocator: std.mem.Allocator, paths: RuntimePaths) void {
    allocator.free(paths.socket);
    allocator.free(paths.pid);
}

/// Return `true` when the daemon answers a Ping over UDS.
pub fn isDaemonRunning(allocator: std.mem.Allocator) bool {
    ping(allocator) catch return false;
    return true;
}

/// Extract the `status` tag from a daemon result object.
pub fn responseStatus(result: std.json.Value) ResponseStatus {
    const object = switch (result) {
        .object => |map| map,
        else => return .unknown,
    };
    const status_val = object.get("status") orelse return .unknown;
    const status_str = switch (status_val) {
        .string => |s| s,
        else => return .unknown,
    };
    if (std.mem.eql(u8, status_str, "Pong")) return .pong;
    if (std.mem.eql(u8, status_str, "Allow")) return .allow;
    if (std.mem.eql(u8, status_str, "Deny")) return .deny;
    if (std.mem.eql(u8, status_str, "Error")) return .error_status;
    if (std.mem.eql(u8, status_str, "CliExecution")) return .cli_execution;
    return .unknown;
}

/// Return the daemon error message when `result.status == "Error"`.
pub fn responseErrorMessage(result: std.json.Value) ?[]const u8 {
    if (responseStatus(result) != .error_status) return null;
    return responseStringField(result, "message");
}

/// Return a string field from a daemon result object when present.
pub fn responseStringField(result: std.json.Value, field_name: []const u8) ?[]const u8 {
    const object = switch (result) {
        .object => |map| map,
        else => return null,
    };
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn responseIntegerField(result: std.json.Value, field_name: []const u8) ?i64 {
    const object = switch (result) {
        .object => |map| map,
        else => return null,
    };
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

pub fn responseArrayField(result: std.json.Value, field_name: []const u8) ?[]const std.json.Value {
    const object = switch (result) {
        .object => |map| map,
        else => return null,
    };
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .array => |items| items.items,
        else => null,
    };
}

fn handshakeHasCapability(result: std.json.Value, expected: []const u8) bool {
    const items = responseArrayField(result, "capabilities") orelse return false;
    for (items) |item| {
        switch (item) {
            .string => |value| {
                if (std.mem.eql(u8, value, expected)) return true;
            },
            else => return false,
        }
    }
    return false;
}

pub fn validateHandshakeResult(result: std.json.Value) DaemonError!void {
    if (responseStatus(result) != .pong) return error.DaemonProtocolError;

    const protocol_version = responseIntegerField(result, "protocol_version") orelse {
        if (responseStringField(result, "protocol_version") != null) return error.HandshakeMalformed;
        return error.MissingHandshake;
    };
    const protocol_label = responseStringField(result, "protocol_label") orelse {
        if (responseArrayField(result, "protocol_label") != null) return error.HandshakeMalformed;
        return error.MissingHandshake;
    };
    const capabilities = responseArrayField(result, "capabilities") orelse {
        if (responseStringField(result, "capabilities") != null or responseIntegerField(result, "capabilities") != null) {
            return error.HandshakeMalformed;
        }
        return error.MissingHandshake;
    };

    if (protocol_version != expected_protocol_version or !std.mem.eql(u8, protocol_label, expected_protocol_label)) {
        return error.ProtocolMismatch;
    }

    for (capabilities) |item| {
        if (item != .string) return error.HandshakeMalformed;
    }
    for (required_capabilities) |capability| {
        if (!handshakeHasCapability(result, capability)) return error.ProtocolMismatch;
    }
}

/// Return the best hook `rule` identifier from a daemon Deny payload.
pub fn responseDenyRule(result: std.json.Value) ?[]const u8 {
    if (responseStatus(result) != .deny) return null;
    return responseStringField(result, "pattern_name") orelse responseStringField(result, "pack_id");
}

/// Return the daemon Allow/Deny reason string when present.
pub fn responseReason(result: std.json.Value) ?[]const u8 {
    return responseStringField(result, "reason");
}

/// Build the JSON request envelope for the Rust daemon ExecuteCli method.
///
/// Caller owns the returned slice.
pub fn buildExecuteCliRequestJson(allocator: std.mem.Allocator, id: u64, argv: []const []const u8) DaemonError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, ExecuteCliRequest{
        .id = id,
        .params = .{ .argv = argv },
    }, .{}) catch error.RequestSerializationFailed;
}

pub fn buildExecuteCliRequestJsonAt(allocator: std.mem.Allocator, id: u64, argv: []const []const u8, cwd: []const u8) DaemonError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, ExecuteCliAtRequest{
        .id = id,
        .params = .{ .argv = argv, .cwd = cwd },
    }, .{}) catch error.RequestSerializationFailed;
}

/// Build the JSON request envelope for the Rust daemon Evaluate method.
///
/// Caller owns the returned slice.
pub fn buildEvaluateRequestJson(
    allocator: std.mem.Allocator,
    id: u64,
    command: []const u8,
    cwd: ?[]const u8,
) DaemonError![]u8 {
    return std.json.Stringify.valueAlloc(allocator, EvaluateRequest{
        .id = id,
        .params = .{ .command = command, .cwd = cwd },
    }, .{}) catch error.RequestSerializationFailed;
}

/// Parse a daemon CliExecution result object.
pub fn parseCliExecution(result: std.json.Value) DaemonError!CliExecution {
    if (responseStatus(result) != .cli_execution) return error.DaemonProtocolError;
    const object = switch (result) {
        .object => |map| map,
        else => return error.DaemonProtocolError,
    };

    const stdout = jsonStringField(object, "stdout") orelse return error.DaemonProtocolError;
    const stderr = jsonStringField(object, "stderr") orelse "";
    const exit_code_int = jsonIntegerField(object, "exit_code") orelse return error.DaemonProtocolError;
    if (exit_code_int < 0 or exit_code_int > std.math.maxInt(u8)) return error.DaemonProtocolError;

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = @intCast(exit_code_int),
    };
}

fn jsonStringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonIntegerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

/// Parse a daemon response line from JSON.
///
/// The caller must invoke `deinit()` on the returned value.
pub fn parseResponse(allocator: std.mem.Allocator, line: []const u8) DaemonError!std.json.Parsed(DaemonResponse) {
    return std.json.parseFromSlice(DaemonResponse, allocator, line, .{
        .allocate = .alloc_if_needed,
    }) catch error.ResponseParseFailed;
}

/// Locate the `ryk-daemon` binary for local development and installed layouts.
///
/// Search order:
/// 1. `$RYK_DAEMON` when set and executable
/// 2. Adjacent to the current `ryk` executable
/// 3. Repo-relative dev paths under `orca-rs/target/{release,debug}/`
///
/// Returns an allocated path (caller owns memory) or `null` if not found.
pub fn findDaemonBinary(allocator: std.mem.Allocator) DaemonError!?[]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    if (getEnvVar(allocator, daemon_env_var) catch return error.OutOfMemory) |env_path| {
        if (pathIsExecutable(io, env_path)) return env_path;
        if (pathExists(io, env_path)) {
            allocator.free(env_path);
            return error.DaemonBinaryNotExecutable;
        }
        allocator.free(env_path);
    }

    if (adjacentDaemonBinaryInspection(allocator, io) catch return error.OutOfMemory) |inspection| {
        defer inspection.deinit(allocator);
        if (inspection.executable) return allocator.dupe(u8, inspection.path) catch error.OutOfMemory;
        if (inspection.exists) return error.DaemonBinaryNotExecutable;
    }

    const self_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(self_dir);

    const repo_root = std.fs.path.dirname(std.fs.path.dirname(self_dir) orelse return null) orelse return null;
    const dev_candidates = [_][]const u8{
        "orca-rs/target/release/" ++ daemon_binary_name,
        "orca-rs/target/debug/" ++ daemon_binary_name,
    };
    for (dev_candidates) |rel| {
        const path = std.fs.path.join(allocator, &.{ repo_root, rel }) catch return error.OutOfMemory;
        errdefer allocator.free(path);
        if (pathIsExecutable(io, path)) return path;
        if (pathExists(io, path)) {
            allocator.free(path);
            return error.DaemonBinaryNotExecutable;
        }
        allocator.free(path);
    }

    return null;
}

pub fn inspectDaemonBinary(allocator: std.mem.Allocator) DaemonError!?DaemonBinaryInspection {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    if (getEnvVar(allocator, daemon_env_var) catch return error.OutOfMemory) |env_path| {
        return .{
            .path = env_path,
            .source = .env_override,
            .exists = pathExists(io, env_path),
            .executable = pathIsExecutable(io, env_path),
            .untrusted = daemon_trust.isEnvOverrideUntrusted(io, allocator, env_path),
        };
    }

    if (adjacentDaemonBinaryInspection(allocator, io) catch return error.OutOfMemory) |inspection| {
        return inspection;
    }

    const self_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(self_dir);

    const repo_root = std.fs.path.dirname(std.fs.path.dirname(self_dir) orelse return null) orelse return null;
    const dev_candidates = [_]struct { rel: []const u8, source: DaemonBinarySource }{
        .{ .rel = "orca-rs/target/release/" ++ daemon_binary_name, .source = .dev_release },
        .{ .rel = "orca-rs/target/debug/" ++ daemon_binary_name, .source = .dev_debug },
    };
    for (dev_candidates) |candidate| {
        const path = std.fs.path.join(allocator, &.{ repo_root, candidate.rel }) catch return error.OutOfMemory;
        const exists = pathExists(io, path);
        const executable = pathIsExecutable(io, path);
        if (exists or executable) {
            return .{
                .path = path,
                .source = candidate.source,
                .exists = exists,
                .executable = executable,
            };
        }
        allocator.free(path);
    }

    const adjacent_path = std.fs.path.join(allocator, &.{ self_dir, daemon_binary_name }) catch return error.OutOfMemory;
    return .{
        .path = adjacent_path,
        .source = .adjacent,
        .exists = false,
        .executable = false,
    };
}

/// Send a Ping request and verify the daemon responds with Pong.
pub fn ping(allocator: std.mem.Allocator) DaemonError!void {
    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);
    try pingWithTimeout(allocator, paths.socket, default_request_timeout_ms);
}

pub fn checkCompatibility(allocator: std.mem.Allocator) DaemonError!void {
    try requireResolvableDaemonBinary(allocator);
    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);
    try handshakeWithTimeout(allocator, paths.socket, default_request_timeout_ms);
}

fn pingWithTimeout(allocator: std.mem.Allocator, socket_path: []const u8, timeout_ms: u64) DaemonError!void {
    var parsed = try sendRequestWithTimeout(allocator, socket_path, .{
        .id = 0,
        .method = "Ping",
        .params = null,
    }, timeout_ms);
    defer parsed.deinit();
    if (responseStatus(parsed.value.result) != .pong) return error.DaemonProtocolError;
}

fn handshakeWithTimeout(allocator: std.mem.Allocator, socket_path: []const u8, timeout_ms: u64) DaemonError!void {
    var parsed = try sendRequestWithTimeout(allocator, socket_path, .{
        .id = 0,
        .method = "Ping",
        .params = null,
    }, timeout_ms);
    defer parsed.deinit();
    try validateHandshakeResult(parsed.value.result);
}

/// Send a single NDJSON request to the daemon and return its parsed response.
///
/// The caller must invoke `deinit()` on the returned value.
pub fn sendRequest(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request: DaemonRequest,
) DaemonError!std.json.Parsed(DaemonResponse) {
    return sendRequestWithTimeout(allocator, socket_path, request, default_request_timeout_ms);
}

/// Ensure the daemon is running and evaluate a shell command.
///
/// Callers inspect the returned result before deinitializing the Parsed response.
pub fn evaluate(
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: ?[]const u8,
) DaemonError!std.json.Parsed(DaemonResponse) {
    try ensureCompatibleDaemonRunning(allocator);
    const path = try socketPath(allocator);
    defer allocator.free(path);

    const json_str = try buildEvaluateRequestJson(allocator, 1, command, cwd);
    defer allocator.free(json_str);

    var parsed = try sendRawRequestWithTimeout(allocator, path, json_str, default_request_timeout_ms);
    errdefer parsed.deinit();
    if (parsed.value.id != 1) return error.DaemonProtocolError;
    return parsed;
}

/// Ensure the daemon is running and send ExecuteCli.
///
/// Callers inspect the returned result before deinitializing the Parsed response.
pub fn executeCli(allocator: std.mem.Allocator, argv: []const []const u8) DaemonError!std.json.Parsed(DaemonResponse) {
    try ensureCompatibleDaemonRunning(allocator);
    const path = try socketPath(allocator);
    defer allocator.free(path);

    const json_str = try buildExecuteCliRequestJson(allocator, 1, argv);
    defer allocator.free(json_str);

    var parsed = try sendRawRequestWithTimeout(allocator, path, json_str, default_request_timeout_ms);
    errdefer parsed.deinit();
    if (parsed.value.id != 1) return error.DaemonProtocolError;
    return parsed;
}

pub fn executeCliAt(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) DaemonError!std.json.Parsed(DaemonResponse) {
    try ensureCompatibleDaemonRunning(allocator);
    const path = try socketPath(allocator);
    defer allocator.free(path);
    const json_str = try buildExecuteCliRequestJsonAt(allocator, 1, argv, cwd);
    defer allocator.free(json_str);
    var parsed = try sendRawRequestWithTimeout(allocator, path, json_str, default_request_timeout_ms);
    errdefer parsed.deinit();
    if (parsed.value.id != 1) return error.DaemonProtocolError;
    return parsed;
}

/// Run a CLI subcommand by spawning the local `ryk-daemon` binary (no UDS).
///
/// Used for mutating commands (`allow`, `allowlist add`, …) that ExecuteCli
/// refuses over the socket. stdout/stderr are forwarded to the provided writers.
pub fn runLocalCli(allocator: std.mem.Allocator, argv: []const []const u8, stdout: anytype, stderr: anytype) DaemonError!u8 {
    if (argv.len == 0) return error.DaemonProtocolError;
    try requireResolvableDaemonBinary(allocator);
    const daemon_binary = try findDaemonBinary(allocator) orelse return error.DaemonBinaryNotFound;
    defer allocator.free(daemon_binary);

    var full_argv = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(full_argv);
    full_argv[0] = daemon_binary;
    @memcpy(full_argv[1..], argv);

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var child = std.process.spawn(io, .{
        .argv = full_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.DaemonSpawnFailed;

    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    if (child.stdout) |out| {
        var buf: [4096]u8 = undefined;
        var reader = out.reader(io, &buf);
        while (stdout_list.items.len < 1024 * 1024) {
            const n = reader.interface.readSliceShort(buf[0..@min(buf.len, 1024 * 1024 - stdout_list.items.len)]) catch break;
            if (n == 0) break;
            stdout_list.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
        }
    }
    if (child.stderr) |err_out| {
        var buf: [4096]u8 = undefined;
        var reader = err_out.reader(io, &buf);
        while (stderr_list.items.len < 1024 * 1024) {
            const n = reader.interface.readSliceShort(buf[0..@min(buf.len, 1024 * 1024 - stderr_list.items.len)]) catch break;
            if (n == 0) break;
            stderr_list.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
        }
    }

    const term = child.wait(io) catch return error.DaemonSpawnFailed;
    stdout.writeAll(stdout_list.items) catch return error.SocketWriteFailed;
    if (stderr_list.items.len > 0) stderr.writeAll(stderr_list.items) catch return error.SocketWriteFailed;
    return switch (term) {
        .exited => |code| @as(u8, @intCast(@min(code, 255))),
        else => 255,
    };
}

pub fn sendRequestWithTimeout(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request: DaemonRequest,
    timeout_ms: u64,
) DaemonError!std.json.Parsed(DaemonResponse) {
    const json_str = std.json.Stringify.valueAlloc(allocator, request, .{}) catch {
        return error.RequestSerializationFailed;
    };
    defer allocator.free(json_str);
    return sendRawRequestWithTimeout(allocator, socket_path, json_str, timeout_ms);
}

fn sendRawRequestWithTimeout(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    json_str: []const u8,
    timeout_ms: u64,
) DaemonError!std.json.Parsed(DaemonResponse) {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const fd = daemon_uds.connectUnixSocket(socket_path) catch return error.SocketConnectFailed;
    defer _ = std.c.close(fd);

    try writeAllFdWithTimeout(io, fd, json_str, timeout_ms);
    try writeAllFdWithTimeout(io, fd, "\n", timeout_ms);

    const line = try readLineFdWithTimeout(io, allocator, fd, timeout_ms);
    const parsed = parseResponse(allocator, line) catch |err| {
        allocator.free(line);
        return err;
    };
    allocator.free(line);
    return parsed;
}

/// Return `true` when socket artifacts exist but no daemon responds to Ping.
pub fn isStaleDaemonArtifacts(allocator: std.mem.Allocator, paths: RuntimePaths) DaemonError!bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, paths.socket, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.DaemonNotReady,
    };

    pingWithTimeout(allocator, paths.socket, stale_artifact_ping_timeout_ms) catch {
        return true;
    };
    return false;
}

/// Best-effort removal of stale socket and PID files.
pub fn cleanupStaleArtifacts(io: std.Io, paths: RuntimePaths) void {
    std.Io.Dir.cwd().deleteFile(io, paths.socket) catch {};
    std.Io.Dir.cwd().deleteFile(io, paths.pid) catch {};
}

/// Spawn `ryk-daemon --daemon-mode` without waiting for readiness.
pub fn startDaemon(allocator: std.mem.Allocator, daemon_binary: []const u8) DaemonError!void {
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = env_util.processEnviron(),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = [_][]const u8{ daemon_binary, "--daemon-mode" };
    _ = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.DaemonSpawnFailed;

    // The daemon is long-lived; do not wait here. If it exits immediately the
    // readiness loop in `waitForDaemonReady` will surface `DaemonStartTimeout`.
}

/// Poll until Ping succeeds or `timeout_ms` elapses.
pub fn waitForDaemonReady(allocator: std.mem.Allocator, timeout_ms: u64) DaemonError!void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);

    const deadline_ms = monotonicNowMs(io) + @as(i64, @intCast(timeout_ms));
    while (monotonicNowMs(io) < deadline_ms) {
        const remaining_ms = @as(u64, @intCast(@max(deadline_ms - monotonicNowMs(io), 0)));
        const attempt_ms = @min(remaining_ms, readiness_poll_ms);

        if (pingWithTimeout(allocator, paths.socket, attempt_ms)) |_| {
            return;
        } else |err| switch (err) {
            error.SocketConnectFailed,
            error.SocketReadFailed,
            error.SocketWriteFailed,
            error.DaemonProtocolError,
            error.ResponseParseFailed,
            => {},
            else => return err,
        }

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(readiness_poll_ms)), .awake) catch {};
    }

    return error.DaemonStartTimeout;
}

/// Ensure a reachable daemon exists: ping, cleanup stale artifacts, spawn, wait.
pub fn ensureDaemonRunning(allocator: std.mem.Allocator) DaemonError!void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    ensure_daemon_lock.lock(io) catch return error.DaemonNotReady;
    defer ensure_daemon_lock.unlock(io);

    try requireResolvableDaemonBinary(allocator);

    if (ping(allocator)) |_| return else |_| {}

    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);

    // Another caller may have started the daemon while we waited for the lock.
    if (ping(allocator)) |_| return else |_| {}

    const daemon_binary = try findDaemonBinary(allocator) orelse return error.DaemonBinaryNotFound;
    defer allocator.free(daemon_binary);

    // Let the hardened Rust daemon startup path own stale-artifact recovery so
    // socket/PID cleanup uses the stricter liveness and ownership checks.
    try startDaemon(allocator, daemon_binary);
    try waitForDaemonReady(allocator, default_readiness_timeout_ms);
}

fn requireResolvableDaemonBinary(allocator: std.mem.Allocator) DaemonError!void {
    const inspection = try inspectDaemonBinary(allocator) orelse return error.DaemonBinaryNotFound;
    defer inspection.deinit(allocator);
    try validateBinaryInspection(inspection);
}

/// Validate a resolved daemon binary inspection before spawn or IPC.
pub fn validateBinaryInspection(inspection: DaemonBinaryInspection) DaemonError!void {
    if (!inspection.exists) return error.DaemonBinaryNotFound;
    if (!inspection.executable) return error.DaemonBinaryNotExecutable;
    if (inspection.source == .env_override and inspection.untrusted) return error.DaemonBinaryUntrusted;
}

fn ensureCompatibleDaemonRunning(allocator: std.mem.Allocator) DaemonError!void {
    try ensureDaemonRunning(allocator);
    const path = try socketPath(allocator);
    defer allocator.free(path);
    try handshakeWithTimeout(allocator, path, default_request_timeout_ms);
}

fn adjacentDaemonBinaryPath(allocator: std.mem.Allocator, io: std.Io) DaemonError!?[]const u8 {
    const self_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(self_dir);

    const path = std.fs.path.join(allocator, &.{ self_dir, daemon_binary_name }) catch return error.OutOfMemory;
    errdefer allocator.free(path);

    if (pathIsExecutable(io, path)) return path;
    allocator.free(path);
    return null;
}

fn adjacentDaemonBinaryInspection(allocator: std.mem.Allocator, io: std.Io) DaemonError!?DaemonBinaryInspection {
    const self_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(self_dir);

    const path = std.fs.path.join(allocator, &.{ self_dir, daemon_binary_name }) catch return error.OutOfMemory;
    const exists = pathExists(io, path);
    const executable = pathIsExecutable(io, path);
    if (!exists and !executable) {
        allocator.free(path);
        return null;
    }
    return .{
        .path = path,
        .source = .adjacent,
        .exists = exists,
        .executable = executable,
    };
}

fn pathIsExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn monotonicNowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn pollTimeoutMs(timeout_ms: u64) i32 {
    return @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

fn waitForPoll(fd: std.posix.fd_t, events: i16, timeout_ms: u64) DaemonError!void {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    const rc = std.posix.poll(fds[0..], pollTimeoutMs(timeout_ms)) catch {
        return error.SocketReadFailed;
    };
    if (rc <= 0) return error.SocketReadFailed;
    if (fds[0].revents & events == 0) {
        return if (events & poll_out != 0) error.SocketWriteFailed else error.SocketReadFailed;
    }
}

const poll_in: i16 = 0x0001;
const poll_out: i16 = 0x0004;

fn writeAllFdWithTimeout(io: std.Io, fd: std.posix.fd_t, bytes: []const u8, timeout_ms: u64) DaemonError!void {
    var written: usize = 0;
    const deadline_ms = monotonicNowMs(io) + @as(i64, @intCast(timeout_ms));

    while (written < bytes.len) {
        const remaining_ms = @as(u64, @intCast(@max(deadline_ms - monotonicNowMs(io), 0)));
        if (remaining_ms == 0) return error.SocketWriteFailed;

        try waitForPoll(fd, poll_out, remaining_ms);

        const n = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) return error.SocketWriteFailed;
        if (n == 0) return error.SocketWriteFailed;
        written += @intCast(n);
    }
}

fn readLineFdWithTimeout(io: std.Io, allocator: std.mem.Allocator, fd: std.posix.fd_t, timeout_ms: u64) DaemonError![]u8 {
    var read_buf: std.ArrayList(u8) = .empty;
    errdefer read_buf.deinit(allocator);

    const deadline_ms = monotonicNowMs(io) + @as(i64, @intCast(timeout_ms));
    var byte: [1]u8 = undefined;

    while (true) {
        const remaining_ms = @as(u64, @intCast(@max(deadline_ms - monotonicNowMs(io), 0)));
        if (remaining_ms == 0) return error.SocketReadFailed;

        try waitForPoll(fd, poll_in, remaining_ms);

        const n = std.c.read(fd, &byte, 1);
        if (n < 0) return error.SocketReadFailed;
        if (n == 0) return error.SocketReadFailed;
        if (read_buf.items.len >= max_response_line_bytes) return error.SocketReadFailed;
        read_buf.append(allocator, byte[0]) catch return error.SocketReadFailed;
        if (byte[0] == '\n') break;
    }

    return read_buf.toOwnedSlice(allocator) catch return error.SocketReadFailed;
}

/// Monotonic clock helper exposed for IPC timeout tests.
pub fn monotonicNowMsForTest(io: std.Io) i64 {
    return monotonicNowMs(io);
}

fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const c_environ = std.c.environ;
    var env_count: usize = 0;
    while (c_environ[env_count] != null) : (env_count += 1) {}
    const environ_slice: [:null]?[*:0]u8 = c_environ[0..env_count :null];
    const environ = std.process.Environ{ .block = .{ .slice = environ_slice } };
    return environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
}

/// Outcome of a daemon shutdown attempt.
pub const ShutdownResult = enum {
    /// Daemon was running; Shutdown request sent and artifacts removed.
    stopped,
    /// No daemon was running and no stale artifacts needed cleanup.
    not_running,
    /// Stale socket/PID artifacts were removed without a live daemon.
    stale_cleaned,
};

fn pathAccessible(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isProcessAlive(pid: std.posix.pid_t) bool {
    if (pid <= 0) return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn readPidFromFile(io: std.Io, allocator: std.mem.Allocator, pid_path: []const u8) DaemonError!?std.posix.pid_t {
    const content = std.Io.Dir.cwd().readFileAlloc(io, pid_path, allocator, .limited(32)) catch return null;
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
}

fn waitForDaemonArtifactsGone(io: std.Io, paths: RuntimePaths, timeout_ms: u64) DaemonError!void {
    const deadline_ms = monotonicNowMs(io) + @as(i64, @intCast(timeout_ms));
    while (monotonicNowMs(io) < deadline_ms) {
        if (!pathAccessible(io, paths.socket) and !pathAccessible(io, paths.pid)) return;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(readiness_poll_ms)), .awake) catch {};
    }
    return error.DaemonStartTimeout;
}

/// Stop the current user's ryk daemon when reachable, or clean stale artifacts.
///
/// Repeated calls are safe: a second shutdown after a successful stop reports
/// `not_running`; stale artifact cleanup is idempotent.
pub fn shutdownDaemon(allocator: std.mem.Allocator) DaemonError!ShutdownResult {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const paths = try runtimePaths(allocator);
    defer freeRuntimePaths(allocator, paths);

    if (ping(allocator)) |_| {
        var parsed = try sendRequest(allocator, paths.socket, .{
            .id = 1,
            .method = "Shutdown",
            .params = null,
        });
        defer parsed.deinit();
        if (responseStatus(parsed.value.result) != .pong) return error.DaemonProtocolError;
        try waitForDaemonArtifactsGone(io, paths, default_readiness_timeout_ms);
        return .stopped;
    } else |_| {}

    const socket_exists = pathAccessible(io, paths.socket);
    const pid_exists = pathAccessible(io, paths.pid);

    if (!socket_exists and !pid_exists) return .not_running;

    if (isStaleDaemonArtifacts(allocator, paths) catch return error.DaemonNotReady) {
        cleanupStaleArtifacts(io, paths);
        return .stale_cleaned;
    }

    if (!socket_exists and pid_exists) {
        const pid = try readPidFromFile(io, allocator, paths.pid);
        if (pid) |live_pid| {
            if (!isProcessAlive(live_pid)) {
                std.Io.Dir.cwd().deleteFile(io, paths.pid) catch {};
                return .stale_cleaned;
            }
            // Live PID with no responding socket: refuse to remove artifacts.
            return error.DaemonNotReady;
        }
        std.Io.Dir.cwd().deleteFile(io, paths.pid) catch {};
        return .stale_cleaned;
    }

    return .not_running;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "runtimePathsForHome builds socket and pid paths" {
    const allocator = std.testing.allocator;
    const paths = try runtimePathsForHome(allocator, "/tmp/ryk-home");
    defer freeRuntimePaths(allocator, paths);

    try std.testing.expectEqualStrings("/tmp/ryk-home/.ryk/daemon.sock", paths.socket);
    try std.testing.expectEqualStrings("/tmp/ryk-home/.ryk/daemon.pid", paths.pid);
}

test "socketPath returns a path under $HOME/.ryk" {
    const allocator = std.testing.allocator;
    const path = try socketPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, "/.ryk/daemon.sock"));
}

test "pidPath returns a path under $HOME/.ryk" {
    const allocator = std.testing.allocator;
    const path = try pidPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, "/.ryk/daemon.pid"));
}

test "DaemonRequest serializes to NDJSON envelope" {
    const request = DaemonRequest{
        .id = 1,
        .method = "Ping",
        .params = null,
    };

    const json_str = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(json_str);

    try std.testing.expectEqualStrings("{\"id\":1,\"method\":\"Ping\",\"params\":null}", json_str);
}

test "parseResponse accepts pong payload" {
    const line = "{\"id\":1,\"result\":{\"status\":\"Pong\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1), parsed.value.id);
    try std.testing.expect(responseStatus(parsed.value.result) == .pong);
}

test "validateHandshakeResult accepts compatible pong payload" {
    const line =
        "{\"id\":1,\"result\":{\"status\":\"Pong\",\"protocol_version\":1,\"protocol_label\":\"orca-uds-v1\",\"capabilities\":[\"Ping\",\"Evaluate\",\"ExecuteCli\",\"ExecuteCliCwd\",\"Shutdown\"]}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try validateHandshakeResult(parsed.value.result);
}

test "validateHandshakeResult rejects missing handshake fields" {
    const line = "{\"id\":1,\"result\":{\"status\":\"Pong\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.MissingHandshake, validateHandshakeResult(parsed.value.result));
}

test "validateHandshakeResult rejects malformed handshake fields" {
    const line =
        "{\"id\":1,\"result\":{\"status\":\"Pong\",\"protocol_version\":\"1\",\"protocol_label\":\"orca-uds-v1\",\"capabilities\":[\"Ping\"]}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.HandshakeMalformed, validateHandshakeResult(parsed.value.result));
}

test "validateHandshakeResult rejects protocol mismatch" {
    const line =
        "{\"id\":1,\"result\":{\"status\":\"Pong\",\"protocol_version\":99,\"protocol_label\":\"orca-uds-v99\",\"capabilities\":[\"Ping\",\"Evaluate\",\"ExecuteCli\",\"Shutdown\"]}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.ProtocolMismatch, validateHandshakeResult(parsed.value.result));
}

test "buildExecuteCliRequestJson serializes expected argv" {
    const json_str = try buildExecuteCliRequestJson(std.testing.allocator, 7, &.{"version"});
    defer std.testing.allocator.free(json_str);

    try std.testing.expectEqualStrings("{\"id\":7,\"method\":\"ExecuteCli\",\"params\":{\"argv\":[\"version\"]}}", json_str);
}

test "buildExecuteCliRequestJson carries trusted workspace cwd" {
    const json_str = try buildExecuteCliRequestJsonAt(std.testing.allocator, 8, &.{ "suggest-allowlist", "--non-interactive" }, "/tmp/canonical-workspace");
    defer std.testing.allocator.free(json_str);
    try std.testing.expectEqualStrings("{\"id\":8,\"method\":\"ExecuteCli\",\"params\":{\"argv\":[\"suggest-allowlist\",\"--non-interactive\"],\"cwd\":\"/tmp/canonical-workspace\"}}", json_str);
}

test "buildEvaluateRequestJson serializes command and cwd" {
    const json_str = try buildEvaluateRequestJson(std.testing.allocator, 3, "git status", "/tmp/work");
    defer std.testing.allocator.free(json_str);

    try std.testing.expectEqualStrings(
        "{\"id\":3,\"method\":\"Evaluate\",\"params\":{\"command\":\"git status\",\"cwd\":\"/tmp/work\"}}",
        json_str,
    );
}

test "buildEvaluateRequestJson serializes null cwd" {
    const json_str = try buildEvaluateRequestJson(std.testing.allocator, 4, "echo hi", null);
    defer std.testing.allocator.free(json_str);

    try std.testing.expectEqualStrings(
        "{\"id\":4,\"method\":\"Evaluate\",\"params\":{\"command\":\"echo hi\",\"cwd\":null}}",
        json_str,
    );
}

test "parseResponse accepts allow payload with reason" {
    const line = "{\"id\":5,\"result\":{\"status\":\"Allow\",\"reason\":\"Command allowed by evaluator\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expect(responseStatus(parsed.value.result) == .allow);
    try std.testing.expectEqualStrings("Command allowed by evaluator", responseReason(parsed.value.result).?);
}

test "responseDenyRule prefers pattern_name over pack_id" {
    const line = "{\"id\":6,\"result\":{\"status\":\"Deny\",\"reason\":\"blocked\",\"pack_id\":\"git\",\"pattern_name\":\"force_push\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("force_push", responseDenyRule(parsed.value.result).?);
}

test "parseCliExecution reads stdout stderr and exit code" {
    const line = "{\"id\":7,\"result\":{\"status\":\"CliExecution\",\"stdout\":\"ryk 1.2.3\\n\",\"stderr\":\"warn\\n\",\"exit_code\":5}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();

    const execution = try parseCliExecution(parsed.value.result);
    try std.testing.expectEqualStrings("ryk 1.2.3\n", execution.stdout);
    try std.testing.expectEqualStrings("warn\n", execution.stderr);
    try std.testing.expectEqual(@as(u8, 5), execution.exit_code);
}

test "parseCliExecution accepts missing stderr as empty" {
    const line = "{\"id\":8,\"result\":{\"status\":\"CliExecution\",\"stdout\":\"ryk 1.2.3\\n\",\"exit_code\":0}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();

    const execution = try parseCliExecution(parsed.value.result);
    try std.testing.expectEqualStrings("ryk 1.2.3\n", execution.stdout);
    try std.testing.expectEqualStrings("", execution.stderr);
    try std.testing.expectEqual(@as(u8, 0), execution.exit_code);
}

test "parseCliExecution rejects daemon Error status" {
    const line = "{\"id\":9,\"result\":{\"status\":\"Error\",\"message\":\"unsupported command\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();

    try std.testing.expectError(error.DaemonProtocolError, parseCliExecution(parsed.value.result));
}

test "parseCliExecution rejects out of range exit code" {
    const line = "{\"id\":10,\"result\":{\"status\":\"CliExecution\",\"stdout\":\"\",\"stderr\":\"\",\"exit_code\":999}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();

    try std.testing.expectError(error.DaemonProtocolError, parseCliExecution(parsed.value.result));
}

test "parseResponse accepts deny payload" {
    const line = "{\"id\":2,\"result\":{\"status\":\"Deny\",\"reason\":\"blocked\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expect(responseStatus(parsed.value.result) == .deny);
}

test "parseResponse rejects malformed JSON" {
    const line = "{not-json";
    const result = parseResponse(std.testing.allocator, line);
    try std.testing.expectError(error.ResponseParseFailed, result);
}

test "responseErrorMessage reads daemon Error status" {
    const line = "{\"id\":3,\"result\":{\"status\":\"Error\",\"message\":\"parse error\"}}";
    var parsed = try parseResponse(std.testing.allocator, line);
    defer parsed.deinit();
    try std.testing.expect(responseStatus(parsed.value.result) == .error_status);
    try std.testing.expectEqualStrings("parse error", responseErrorMessage(parsed.value.result).?);
}

test "isStaleDaemonArtifacts false when socket missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const paths = try runtimePathsForHome(std.testing.allocator, home);
    defer freeRuntimePaths(std.testing.allocator, paths);

    try std.testing.expect(!try isStaleDaemonArtifacts(std.testing.allocator, paths));
}

test "isStaleDaemonArtifacts true when socket exists without pid file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const paths = try runtimePathsForHome(std.testing.allocator, home);
    defer freeRuntimePaths(std.testing.allocator, paths);

    try tmp.dir.createDirPath(std.testing.io, ".ryk");
    const sock = try tmp.dir.createFile(std.testing.io, ".ryk/daemon.sock", .{});
    sock.close(std.testing.io);

    try std.testing.expect(try isStaleDaemonArtifacts(std.testing.allocator, paths));
}

test "isStaleDaemonArtifacts true when live unrelated pid cannot serve ping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const paths = try runtimePathsForHome(std.testing.allocator, home);
    defer freeRuntimePaths(std.testing.allocator, paths);

    try tmp.dir.createDirPath(std.testing.io, ".ryk");
    const sock = try tmp.dir.createFile(std.testing.io, ".ryk/daemon.sock", .{});
    sock.close(std.testing.io);

    const pid_text = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{std.c.getpid()});
    defer std.testing.allocator.free(pid_text);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ryk/daemon.pid",
        .data = pid_text,
    });

    try std.testing.expect(try isStaleDaemonArtifacts(std.testing.allocator, paths));
}

test "pathIsExecutable rejects non-executable file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "not-exec.txt", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "hello");

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "not-exec.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expect(!pathIsExecutable(std.testing.io, path));
}

test "sendRequest connect failure surfaces SocketConnectFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const missing = try std.fs.path.join(std.testing.allocator, &.{ home, ".ryk", "missing.sock" });
    defer std.testing.allocator.free(missing);

    const result = sendRequest(std.testing.allocator, missing, .{
        .id = 1,
        .method = "Ping",
        .params = null,
    });
    try std.testing.expectError(error.SocketConnectFailed, result);
}

test "integration: ensureDaemonRunning when RYK_DAEMON is set" {
    const allocator = std.testing.allocator;
    const maybe_daemon_path = getEnvVar(allocator, daemon_env_var) catch return;
    defer if (maybe_daemon_path) |p| allocator.free(p);
    if (maybe_daemon_path == null) return;

    try ensureDaemonRunning(allocator);
    try ping(allocator);
}

test "cleanupStaleArtifacts clears stale socket so isStaleDaemonArtifacts is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const paths = try runtimePathsForHome(std.testing.allocator, home);
    defer freeRuntimePaths(std.testing.allocator, paths);

    try tmp.dir.createDirPath(std.testing.io, ".ryk");
    const sock = try tmp.dir.createFile(std.testing.io, ".ryk/daemon.sock", .{});
    sock.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".ryk/daemon.pid",
        .data = "999999\n",
    });

    try std.testing.expect(try isStaleDaemonArtifacts(std.testing.allocator, paths));
    cleanupStaleArtifacts(std.testing.io, paths);
    try std.testing.expect(!try isStaleDaemonArtifacts(std.testing.allocator, paths));
    try std.testing.expect(!pathAccessible(std.testing.io, paths.socket));
    try std.testing.expect(!pathAccessible(std.testing.io, paths.pid));
}

test "validateBinaryInspection accepts trusted adjacent binary" {
    const path = try std.testing.allocator.dupe(u8, "/tmp/ryk-daemon");
    defer std.testing.allocator.free(path);

    try validateBinaryInspection(.{
        .path = path,
        .source = .adjacent,
        .exists = true,
        .executable = true,
        .untrusted = false,
    });
}
