const std = @import("std");
const builtin = @import("builtin");
const gateway = @import("provider_gateway.zig");
const protocol = @import("provider_gateway_protocol.zig");
const session_secrets = @import("session_secrets.zig");

const AuditKind = gateway.AuditKind;
const Runtime = gateway.Runtime;
const listen = gateway.listen;
const listenWithOrigin = gateway.testing.listenWithOrigin;
const parseInbound = protocol.parseInbound;

test "gateway parser accepts exact Anthropic phantom and rejects phantom smuggling" {
    const phantom = "orca-secret://session/0123456789abcdef0123456789abcdef/ANTHROPIC_API_KEY/0123456789abcdef";
    const request = try std.fmt.allocPrint(std.testing.allocator, "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: {s}\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n{{}}", .{phantom});
    defer std.testing.allocator.free(request);
    var parsed = try parseInbound(std.testing.allocator, .anthropic, request, .{});
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(phantom, parsed.phantom);
    try std.testing.expectEqual(@as(usize, 2), parsed.content_length);
    const smuggled = try std.fmt.allocPrint(std.testing.allocator, "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: {s}\r\nx-extra: orca-secret://evil\r\n\r\n", .{phantom});
    defer std.testing.allocator.free(smuggled);
    try std.testing.expectError(
        error.PhantomInUnexpectedHeader,
        parseInbound(std.testing.allocator, .anthropic, smuggled, .{}),
    );

    const malformed_headers = [_][]const u8{
        "Content-Length : 0",
        "Transfer-Encoding : chunked",
        "x-extra: ok\nInjected: yes",
        "x-extra: ok\rInjected: yes",
        "x-extra:\tok",
    };
    for (malformed_headers) |malformed_header| {
        const malformed = try std.fmt.allocPrint(
            std.testing.allocator,
            "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: {s}\r\n{s}\r\n\r\n",
            .{ phantom, malformed_header },
        );
        defer std.testing.allocator.free(malformed);
        try std.testing.expectError(
            error.InvalidHeader,
            parseInbound(std.testing.allocator, .anthropic, malformed, .{}),
        );
    }
}

test "gateway rejects a socket timeout that cannot fit poll" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-invalid-timeout-canary");
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    _ = try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    });

    try std.testing.expectError(error.InvalidLimits, listen(
        std.testing.allocator,
        &store,
        .anthropic,
        .{ .io_timeout_ms = @as(u32, std.math.maxInt(i32)) + 1 },
    ));
}

test "gateway header deadline is absolute under byte drip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-header-deadline-canary");
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    _ = try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    });
    var runtime = try listenWithOrigin(
        std.testing.allocator,
        &store,
        .anthropic,
        .{ .io_timeout_ms = 80 },
        "http://127.0.0.1:1",
    );
    defer runtime.deinit();
    try runtime.startServing();

    var client_state: DripClientState = .{ .io = io, .port = runtime.bindPort() };
    const client_thread = try std.Thread.spawn(.{}, dripClient, .{&client_state});
    defer client_thread.join();
    try waitForFlag(&client_state.connected, 1_000);
    try waitForActiveConnection(runtime, 1_000);

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try runtime.waitForIdle(std.time.ns_per_s);
    const elapsed = started.durationFromNow(io).raw.nanoseconds;
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
}

test "gateway deinit interrupts a stalled partial header" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-deinit-header-canary");
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    _ = try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    });
    var runtime = try listenWithOrigin(
        std.testing.allocator,
        &store,
        .anthropic,
        .{ .io_timeout_ms = 5_000 },
        "http://127.0.0.1:1",
    );
    try runtime.startServing();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", runtime.bindPort());
    var client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var client_buffer: [1]u8 = undefined;
    var client_writer = client.writer(io, &client_buffer);
    try client_writer.interface.writeAll("G");
    try client_writer.interface.flush();
    try waitForActiveConnection(runtime, 1_000);

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    runtime.deinit();
    const elapsed = started.durationFromNow(io).raw.nanoseconds;
    try std.testing.expect(elapsed < std.time.ns_per_s);
}

test "gateway swaps an exact phantom for fixed synthetic upstream and denies unminted token" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const raw_secret = "sk-ant-gateway-wire-canary";
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", raw_secret);
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };

    const upstream_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var upstream = try upstream_address.listen(io, .{ .reuse_address = true });
    defer upstream.deinit(io);
    var upstream_state: TestUpstreamState = .{
        .io = io,
        .server = &upstream,
        .expected_raw = raw_secret,
    };
    const upstream_thread = try std.Thread.spawn(.{}, testUpstream, .{&upstream_state});
    defer upstream_thread.join();
    const origin = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{upstream.socket.address.getPort()},
    );
    defer std.testing.allocator.free(origin);

    var runtime = try listenWithOrigin(std.testing.allocator, &store, .anthropic, .{}, origin);
    defer runtime.deinit();
    try runtime.startServing();

    const allowed = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: {s}\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{phantom},
    );
    defer std.testing.allocator.free(allowed);
    const allowed_response = try gatewayExchange(io, runtime.bindPort(), allowed);
    try std.testing.expect(std.mem.indexOf(u8, &allowed_response, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, &allowed_response, "synthetic-ok") != null);

    const wrong_host = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST http://evil.invalid/v1/messages HTTP/1.1\r\nHost: evil.invalid\r\nx-api-key: {s}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{phantom},
    );
    defer std.testing.allocator.free(wrong_host);
    const wrong_host_response = try gatewayExchange(io, runtime.bindPort(), wrong_host);
    try std.testing.expect(std.mem.indexOf(u8, &wrong_host_response, "400 Bad Request") != null);

    const denied =
        "POST /v1/messages HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "x-api-key: orca-secret://session/evil/ANTHROPIC_API_KEY/0000000000000000\r\n" ++
        "content-length: 2\r\nconnection: close\r\n\r\n{}";
    const denied_response = try gatewayExchange(io, runtime.bindPort(), denied);
    try std.testing.expect(std.mem.indexOf(u8, &denied_response, "403 Forbidden") != null);

    try runtime.waitForIdle(2 * std.time.ns_per_s);
    const events = try runtime.snapshotAuditEvents(std.testing.allocator);
    defer runtime.freeAuditEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(AuditKind.phantom_swap, events[0].kind);
    try std.testing.expectEqual(AuditKind.phantom_denied, events[1].kind);
    try std.testing.expectEqualStrings("invalid_target", events[1].reason_code);
    try std.testing.expectEqual(AuditKind.phantom_denied, events[2].kind);
    for (events) |event| {
        try std.testing.expect(std.mem.indexOf(u8, event.env_var, raw_secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, event.reason_code, raw_secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, event.reason_code, phantom) == null);
    }
    try std.testing.expect(upstream_state.saw_raw);
    try std.testing.expect(!upstream_state.saw_phantom);
}

test "OpenAI gateway swaps only exact Bearer phantom" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const raw_secret = "sk-openai-gateway-wire-canary";
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("OPENAI_API_KEY", raw_secret);
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "OPENAI_API_KEY",
        .provider = .openai,
        .allowed_hosts = &.{"api.openai.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const upstream_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var upstream = try upstream_address.listen(io, .{ .reuse_address = true });
    defer upstream.deinit(io);
    var upstream_state: TestUpstreamState = .{
        .io = io,
        .server = &upstream,
        .expected_raw = raw_secret,
    };
    const upstream_thread = try std.Thread.spawn(.{}, testUpstream, .{&upstream_state});
    defer upstream_thread.join();
    const origin = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{upstream.socket.address.getPort()},
    );
    defer std.testing.allocator.free(origin);
    var runtime = try listenWithOrigin(std.testing.allocator, &store, .openai, .{}, origin);
    defer runtime.deinit();
    try runtime.startServing();
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{phantom},
    );
    defer std.testing.allocator.free(request);
    const response = try gatewayExchange(io, runtime.bindPort(), request);
    try std.testing.expect(std.mem.indexOf(u8, &response, "200 OK") != null);
    try runtime.waitForIdle(2 * std.time.ns_per_s);
    try std.testing.expect(upstream_state.saw_raw);
    try std.testing.expect(!upstream_state.saw_phantom);
}

test "gateway streams an upstream response before the whole body arrives" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-streaming-canary");
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const upstream_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var upstream = try upstream_address.listen(io, .{ .reuse_address = true });
    defer upstream.deinit(io);
    var upstream_state: StreamingUpstreamState = .{ .io = io, .server = &upstream };
    const upstream_thread = try std.Thread.spawn(.{}, streamingUpstream, .{&upstream_state});
    defer {
        upstream_state.release.store(true, .release);
        upstream_thread.join();
    }
    const origin = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{upstream.socket.address.getPort()},
    );
    defer std.testing.allocator.free(origin);
    var runtime = try listenWithOrigin(std.testing.allocator, &store, .anthropic, .{}, origin);
    defer runtime.deinit();
    defer upstream_state.release.store(true, .release);
    try runtime.startServing();
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: {s}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{phantom},
    );
    defer std.testing.allocator.free(request);
    const gateway_address = try std.Io.net.IpAddress.parse("127.0.0.1", runtime.bindPort());
    var client = try gateway_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var request_buffer: [4096]u8 = undefined;
    var client_writer = client.writer(io, &request_buffer);
    try client_writer.interface.writeAll(request);
    try client_writer.interface.flush();
    try waitForFlag(&upstream_state.first_chunk_written, 1_000);
    var descriptor = [_]std.posix.pollfd{.{
        .fd = client.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var response: [4096]u8 = undefined;
    var total: usize = 0;
    var attempts: u8 = 0;
    while (std.mem.indexOf(u8, response[0..total], "synthetic-") == null and attempts < 50) : (attempts += 1) {
        if ((try std.posix.poll(&descriptor, 10)) == 0) continue;
        const n = try std.posix.read(client.socket.handle, response[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(std.mem.indexOf(u8, response[0..total], "synthetic-") != null);
    upstream_state.release.store(true, .release);
}

test "gateway cancels a stalled upstream and deinitializes within its deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-stalled-upstream-canary");
    var store = try session_secrets.Store.init(io, std.testing.allocator);
    defer store.deinit();
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const upstream_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var upstream = try upstream_address.listen(io, .{ .reuse_address = true });
    defer upstream.deinit(io);
    var upstream_state: StalledUpstreamState = .{ .io = io, .server = &upstream };
    const upstream_thread = try std.Thread.spawn(.{}, stalledUpstream, .{&upstream_state});
    defer {
        upstream_state.release.store(true, .release);
        upstream_thread.join();
    }
    const origin = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}",
        .{upstream.socket.address.getPort()},
    );
    defer std.testing.allocator.free(origin);
    var runtime = try listenWithOrigin(std.testing.allocator, &store, .anthropic, .{
        .upstream_timeout_ms = 150,
    }, origin);
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    try runtime.startServing();
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: {s}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}",
        .{phantom},
    );
    defer std.testing.allocator.free(request);

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const response = try gatewayExchange(io, runtime.bindPort(), request);
    try std.testing.expect(std.mem.indexOf(u8, &response, "502 Bad Gateway") != null);
    try runtime.waitForIdle(std.time.ns_per_s);
    runtime.deinit();
    runtime_live = false;
    const elapsed = started.durationFromNow(io).raw.nanoseconds;
    try std.testing.expect(elapsed < 2 * std.time.ns_per_s);
    try std.testing.expect(upstream_state.request_received.load(.acquire));
}

const TestUpstreamState = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    expected_raw: []const u8,
    saw_raw: bool = false,
    saw_phantom: bool = false,
};

const StreamingUpstreamState = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    first_chunk_written: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
};

const StalledUpstreamState = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    request_received: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
};

const DripClientState = struct {
    io: std.Io,
    port: u16,
    connected: std.atomic.Value(bool) = .init(false),
};

fn dripClient(state: *DripClientState) void {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", state.port) catch return;
    var stream = address.connect(state.io, .{ .mode = .stream }) catch return;
    defer stream.close(state.io);
    state.connected.store(true, .release);
    var buffer: [1]u8 = undefined;
    var writer = stream.writer(state.io, &buffer);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        writer.interface.writeAll("G") catch return;
        writer.interface.flush() catch return;
        std.Io.sleep(state.io, std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch return;
    }
}

fn streamingUpstream(state: *StreamingUpstreamState) void {
    var stream = state.server.accept(state.io) catch return;
    defer stream.close(state.io);
    var request: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < request.len) {
        const n = std.posix.read(stream.socket.handle, request[total..]) catch return;
        if (n == 0) return;
        total += n;
        if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n") != null) break;
    }
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(state.io, &buffer);
    writer.interface.writeAll(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 12\r\nconnection: close\r\n\r\nsynthetic-",
    ) catch return;
    writer.interface.flush() catch return;
    state.first_chunk_written.store(true, .release);
    while (!state.release.load(.acquire)) {
        std.Io.sleep(state.io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch return;
    }
    writer.interface.writeAll("ok") catch return;
    writer.interface.flush() catch {};
}

fn stalledUpstream(state: *StalledUpstreamState) void {
    var stream = state.server.accept(state.io) catch return;
    defer stream.close(state.io);
    var request: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < request.len) {
        const n = std.posix.read(stream.socket.handle, request[total..]) catch return;
        if (n == 0) return;
        total += n;
        if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n{}") != null) break;
    }
    state.request_received.store(true, .release);
    while (!state.release.load(.acquire)) {
        std.Io.sleep(state.io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch return;
    }
}

fn waitForFlag(flag: *std.atomic.Value(bool), timeout_ms: u32) !void {
    var elapsed_ms: u32 = 0;
    while (!flag.load(.acquire)) {
        if (elapsed_ms >= timeout_ms) return error.TestExpectedEqual;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        elapsed_ms += 1;
    }
}

fn waitForActiveConnection(runtime: Runtime, timeout_ms: u32) !void {
    var elapsed_ms: u32 = 0;
    while (gateway.testing.activeConnectionCount(runtime) == 0) {
        if (elapsed_ms >= timeout_ms) return error.TestExpectedEqual;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        elapsed_ms += 1;
    }
}

fn testUpstream(state: *TestUpstreamState) void {
    var stream = state.server.accept(state.io) catch return;
    defer stream.close(state.io);
    var request: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < request.len) {
        const n = std.posix.read(stream.socket.handle, request[total..]) catch return;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n{}") != null) break;
    }
    state.saw_raw = std.mem.indexOf(u8, request[0..total], state.expected_raw) != null;
    state.saw_phantom = std.mem.indexOf(u8, request[0..total], "orca-secret://") != null;
    var writer_buffer: [512]u8 = undefined;
    var writer = stream.writer(state.io, &writer_buffer);
    writer.interface.writeAll(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 12\r\nconnection: close\r\n\r\nsynthetic-ok",
    ) catch return;
    writer.interface.flush() catch return;
}

fn gatewayExchange(io: std.Io, port: u16, request: []const u8) ![4096]u8 {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var response: [4096]u8 = @splat(0);
    var total: usize = 0;
    while (total < response.len) {
        const n = try std.posix.read(stream.socket.handle, response[total..]);
        if (n == 0) break;
        total += n;
    }
    return response;
}
