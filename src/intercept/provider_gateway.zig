const std = @import("std");
const builtin = @import("builtin");
const session_secrets = @import("session_secrets.zig");

pub const Provider = session_secrets.Provider;
pub const Limits = struct {
    request_head: usize = 32 * 1024,
    request_body: usize = 32 * 1024 * 1024,
    response_head: usize = 32 * 1024,
    response_body: usize = 64 * 1024 * 1024,
};
pub const AuditKind = enum { phantom_swap, phantom_denied };
pub const AuditEvent = struct {
    kind: AuditKind,
    provider: Provider,
    env_var: []const u8,
    reason_code: []const u8,
};

const ProviderConfig = struct {
    logical_host: []const u8,
    env_var: []const u8,
    production_origin: []const u8,

    fn get(provider: Provider) ProviderConfig {
        return switch (provider) {
            .anthropic => .{
                .logical_host = "api.anthropic.com",
                .env_var = "ANTHROPIC_API_KEY",
                .production_origin = "https://api.anthropic.com",
            },
            .openai => .{
                .logical_host = "api.openai.com",
                .env_var = "OPENAI_API_KEY",
                .production_origin = "https://api.openai.com",
            },
        };
    }
};

pub const Runtime = struct {
    state: *State,

    pub fn bindUrl(self: Runtime) []const u8 {
        return self.state.bind_url;
    }
    pub fn bindPort(self: Runtime) u16 {
        return self.state.bind_port;
    }
    pub fn provider(self: Runtime) Provider {
        return self.state.provider;
    }
    pub fn isServing(self: Runtime) bool {
        return self.state.serving.load(.acquire);
    }
    pub fn isHealthy(self: Runtime) bool {
        return self.state.serving.load(.acquire) and
            !self.state.stop.load(.acquire) and
            !self.state.failed.load(.acquire);
    }
    pub fn failed(self: Runtime) bool {
        return self.state.failed.load(.acquire);
    }
    pub fn startServing(self: *Runtime) !void {
        if (self.state.serving.swap(true, .acq_rel)) return;
        self.state.thread = std.Thread.spawn(.{}, serverLoop, .{self.state}) catch |err| {
            self.state.serving.store(false, .release);
            return err;
        };
        self.state.thread_started = true;
    }
    pub fn waitForIdle(self: Runtime, timeout_ns: u64) !void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        while (self.state.active_connections.load(.acquire) > 0) {
            if (started.durationFromNow(io).raw.nanoseconds > timeout_ns)
                return error.GatewayConnectionsActive;
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
        }
    }
    pub fn snapshotAuditEvents(self: Runtime, allocator: std.mem.Allocator) ![]AuditEvent {
        const io = self.state.threaded.io();
        try self.state.audit_mutex.lock(io);
        defer self.state.audit_mutex.unlock(io);
        return try allocator.dupe(AuditEvent, self.state.audit_events.items);
    }
    pub fn freeAuditEvents(_: Runtime, allocator: std.mem.Allocator, events: []AuditEvent) void {
        allocator.free(events);
    }
    pub fn deinit(self: *Runtime) void {
        const state = self.state;
        const io = state.threaded.io();
        state.stop.store(true, .release);
        wake(io, state.bind_port);
        if (state.thread_started) state.thread.join();
        state.server.deinit(io);
        while (state.active_connections.load(.acquire) > 0)
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
        state.http_client.deinit();
        state.audit_events.deinit(state.allocator);
        state.allocator.free(state.bind_url);
        state.allocator.free(state.upstream_origin);
        state.allocator.destroy(state);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    server: std.Io.net.Server,
    bind_port: u16,
    bind_url: []u8,
    provider: Provider,
    store: *const session_secrets.Store,
    limits: Limits,
    upstream_origin: []u8,
    threaded: std.Io.Threaded,
    http_client: std.http.Client,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    serving: std.atomic.Value(bool) = .init(false),
    active_connections: std.atomic.Value(usize) = .init(0),
    audit_mutex: std.Io.Mutex = .init,
    audit_events: std.ArrayList(AuditEvent) = .empty,
    thread: std.Thread = undefined,
    thread_started: bool = false,

    fn record(self: *State, kind: AuditKind, reason_code: []const u8) !void {
        const config = ProviderConfig.get(self.provider);
        const io = self.threaded.io();
        try self.audit_mutex.lock(io);
        defer self.audit_mutex.unlock(io);
        try self.audit_events.append(self.allocator, .{
            .kind = kind,
            .provider = self.provider,
            .env_var = config.env_var,
            .reason_code = reason_code,
        });
    }
};

pub fn listen(
    allocator: std.mem.Allocator,
    store: *const session_secrets.Store,
    provider: Provider,
    limits: Limits,
) !Runtime {
    return listenWithOrigin(allocator, store, provider, limits, ProviderConfig.get(provider).production_origin);
}

pub fn start(
    allocator: std.mem.Allocator,
    store: *const session_secrets.Store,
    provider: Provider,
    limits: Limits,
) !Runtime {
    var runtime = try listen(allocator, store, provider, limits);
    errdefer runtime.deinit();
    try runtime.startServing();
    return runtime;
}

fn listenWithOrigin(
    allocator: std.mem.Allocator,
    store: *const session_secrets.Store,
    provider: Provider,
    limits: Limits,
    upstream_origin: []const u8,
) !Runtime {
    if (!store.hasProvider(provider)) return error.ProviderGrantMissing;
    if (limits.request_head < 1024 or limits.response_head < 1024) return error.InvalidLimits;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = false });
    errdefer server.deinit(io);
    try setServerSocketCloexec(server.socket.handle);
    const port = server.socket.address.getPort();
    const bind_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    errdefer allocator.free(bind_url);
    const owned_origin = try allocator.dupe(u8, upstream_origin);
    errdefer allocator.free(owned_origin);
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .server = server,
        .bind_port = port,
        .bind_url = bind_url,
        .provider = provider,
        .store = store,
        .limits = limits,
        .upstream_origin = owned_origin,
        .threaded = threaded,
        .http_client = undefined,
    };
    state.http_client = .{
        .allocator = allocator,
        .io = state.threaded.io(),
        .read_buffer_size = limits.response_head,
    };
    return .{ .state = state };
}

fn setServerSocketCloexec(handle: std.Io.net.Socket.Handle) !void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => if (std.c.fcntl(handle, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) == -1)
            return error.Unexpected,
    }
}

fn serverLoop(state: *State) void {
    const io = state.threaded.io();
    while (!state.stop.load(.acquire)) {
        var stream = state.server.accept(io) catch {
            if (!state.stop.load(.acquire)) state.failed.store(true, .release);
            break;
        };
        if (state.stop.load(.acquire)) {
            stream.close(io);
            break;
        }
        const context = state.allocator.create(ConnectionContext) catch {
            stream.close(io);
            continue;
        };
        context.* = .{ .state = state, .client = stream };
        _ = state.active_connections.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, connectionLoop, .{context}) catch {
            _ = state.active_connections.fetchSub(1, .acq_rel);
            stream.close(io);
            state.allocator.destroy(context);
            continue;
        };
        thread.detach();
    }
}

const ConnectionContext = struct { state: *State, client: std.Io.net.Stream };
fn connectionLoop(context: *ConnectionContext) void {
    const state = context.state;
    const io = state.threaded.io();
    defer {
        const allocator = context.state.allocator;
        _ = context.state.active_connections.fetchSub(1, .acq_rel);
        allocator.destroy(context);
    }
    handleConnection(state, io, context.client) catch {};
}

const ParsedInbound = struct {
    method: std.http.Method,
    target: []const u8,
    headers_end: usize,
    content_length: usize,
    forwarded_headers: std.ArrayList(std.http.Header),
    phantom: []const u8,
    fn deinit(self: *ParsedInbound, allocator: std.mem.Allocator) void {
        self.forwarded_headers.deinit(allocator);
    }
};

fn handleConnection(state: *State, io: std.Io, client: std.Io.net.Stream) !void {
    defer client.close(io);
    const head_buffer = try state.allocator.alloc(u8, state.limits.request_head);
    defer state.allocator.free(head_buffer);
    const read_len = readHeaders(client, head_buffer) catch |err| {
        const status: u16 = if (err == error.RequestTooLarge) 431 else 400;
        writeError(io, client, status, if (status == 431) "Request Header Fields Too Large" else "Bad Request") catch {};
        return;
    };
    var parsed = parseInbound(state.allocator, state.provider, head_buffer[0..read_len], state.limits) catch |err| {
        state.record(.phantom_denied, denialReason(err)) catch {};
        const status: u16 = if (err == error.RequestBodyTooLarge) 413 else if (isAuthorizationError(err)) 403 else 400;
        writeError(io, client, status, if (status == 403) "Forbidden" else if (status == 413) "Payload Too Large" else "Bad Request") catch {};
        return;
    };
    defer parsed.deinit(state.allocator);
    const config = ProviderConfig.get(state.provider);
    const authorized = state.store.authorize(
        parsed.phantom,
        state.provider,
        config.env_var,
        config.logical_host,
    ) catch |err| {
        state.record(.phantom_denied, authorizationReason(err)) catch {};
        try writeError(io, client, 403, "Forbidden");
        return;
    };
    const body = try readBody(
        state.allocator,
        client,
        head_buffer[parsed.headers_end..read_len],
        parsed.content_length,
        state.limits.request_body,
    );
    defer state.allocator.free(body);
    state.record(.phantom_swap, "authorized") catch {
        try writeError(io, client, 503, "Service Unavailable");
        return;
    };
    forwardRequest(state, io, client, &parsed, body, authorized.raw) catch {
        writeError(io, client, 502, "Bad Gateway") catch {};
    };
}

fn readHeaders(stream: std.Io.net.Stream, buffer: []u8) !usize {
    var total: usize = 0;
    var idle_ms: usize = 0;
    while (total < buffer.len) {
        var descriptor = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&descriptor, 100);
        if (ready == 0) {
            idle_ms += 100;
            if (idle_ms >= 5000) return error.RequestTimeout;
            continue;
        }
        const n = std.posix.read(stream.socket.handle, buffer[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.InvalidRequest;
        idle_ms = 0;
        total += n;
        if (std.mem.indexOf(u8, buffer[0..total], "\r\n\r\n") != null) return total;
    }
    return error.RequestTooLarge;
}

fn parseInbound(
    allocator: std.mem.Allocator,
    provider: Provider,
    bytes: []const u8,
    limits: Limits,
) !ParsedInbound {
    const headers_end = (std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.InvalidRequest) + 4;
    const line_end = std.mem.indexOf(u8, bytes[0..headers_end], "\r\n") orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, bytes[0..line_end], ' ');
    const method_text = parts.next() orelse return error.InvalidRequest;
    const target = parts.next() orelse return error.InvalidRequest;
    const version = parts.next() orelse return error.InvalidRequest;
    if (parts.next() != null or !std.mem.eql(u8, version, "HTTP/1.1")) return error.InvalidRequest;
    const method = std.meta.stringToEnum(std.http.Method, method_text) orelse return error.UnsupportedMethod;
    if (method == .CONNECT or target.len == 0 or target[0] != '/' or
        std.mem.indexOf(u8, target, "://") != null or std.mem.indexOfScalar(u8, target, '#') != null)
        return error.InvalidTarget;

    var forwarded: std.ArrayList(std.http.Header) = .empty;
    errdefer forwarded.deinit(allocator);
    var content_length: ?usize = null;
    var phantom: ?[]const u8 = null;
    var saw_host = false;
    var lines = std.mem.splitSequence(u8, bytes[line_end + 2 .. headers_end - 2], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        if (colon == 0) return error.InvalidHeader;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (saw_host) return error.DuplicateHeader;
            saw_host = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null) return error.DuplicateHeader;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
            if (content_length.? > limits.request_body) return error.RequestBodyTooLarge;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.UnsupportedTransferEncoding;
        if (isHopByHop(name) or std.ascii.eqlIgnoreCase(name, "accept-encoding")) continue;
        const anthropic_auth = std.ascii.eqlIgnoreCase(name, "x-api-key");
        const authorization = std.ascii.eqlIgnoreCase(name, "authorization");
        switch (provider) {
            .anthropic => {
                if (authorization) return error.UnexpectedAuthorizationHeader;
                if (anthropic_auth) {
                    if (phantom != null) return error.DuplicateAuthorizationHeader;
                    phantom = value;
                    continue;
                }
            },
            .openai => {
                if (anthropic_auth) return error.UnexpectedAuthorizationHeader;
                if (authorization) {
                    if (phantom != null) return error.DuplicateAuthorizationHeader;
                    if (!std.mem.startsWith(u8, value, "Bearer ")) return error.InvalidAuthorizationScheme;
                    phantom = value["Bearer ".len..];
                    if (phantom.?.len == 0) return error.InvalidAuthorizationScheme;
                    continue;
                }
            },
        }
        if (std.mem.indexOf(u8, value, "orca-secret://") != null) return error.PhantomInUnexpectedHeader;
        try forwarded.append(allocator, .{ .name = name, .value = value });
    }
    if (!saw_host) return error.MissingHost;
    return .{
        .method = method,
        .target = target,
        .headers_end = headers_end,
        .content_length = content_length orelse 0,
        .forwarded_headers = forwarded,
        .phantom = phantom orelse return error.MissingAuthorization,
    };
}

fn readBody(
    allocator: std.mem.Allocator,
    client: std.Io.net.Stream,
    initial: []const u8,
    content_length: usize,
    max_body: usize,
) ![]u8 {
    if (content_length > max_body) return error.RequestBodyTooLarge;
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    const copied = @min(initial.len, body.len);
    @memcpy(body[0..copied], initial[0..copied]);
    var offset = copied;
    var idle_ms: usize = 0;
    while (offset < body.len) {
        var descriptor = [_]std.posix.pollfd{.{
            .fd = client.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&descriptor, 100);
        if (ready == 0) {
            idle_ms += 100;
            if (idle_ms >= 5000) return error.RequestTimeout;
            continue;
        }
        const n = std.posix.read(client.socket.handle, body[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.IncompleteBody;
        idle_ms = 0;
        offset += n;
    }
    return body;
}

fn forwardRequest(
    state: *State,
    io: std.Io,
    downstream: std.Io.net.Stream,
    inbound: *const ParsedInbound,
    body: []const u8,
    raw: []const u8,
) !void {
    const uri_text = try std.fmt.allocPrint(state.allocator, "{s}{s}", .{ state.upstream_origin, inbound.target });
    defer state.allocator.free(uri_text);
    const uri = try std.Uri.parse(uri_text);
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| wipeAndFree(state.allocator, value);
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(state.allocator);
    try extra_headers.appendSlice(state.allocator, inbound.forwarded_headers.items);
    var request_headers: std.http.Client.Request.Headers = .{
        .authorization = .omit,
        .user_agent = .omit,
        .connection = .{ .override = "close" },
        .accept_encoding = .omit,
        .content_type = .omit,
    };
    switch (state.provider) {
        .anthropic => try extra_headers.append(state.allocator, .{ .name = "x-api-key", .value = raw }),
        .openai => {
            auth_header = try std.fmt.allocPrint(state.allocator, "Bearer {s}", .{raw});
            request_headers.authorization = .{ .override = auth_header.? };
        },
    }
    var request = try state.http_client.request(inbound.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = request_headers,
        .extra_headers = extra_headers.items,
    });
    defer request.deinit();
    if (inbound.method.requestHasBody()) {
        request.transfer_encoding = .{ .content_length = body.len };
        var write_buffer: [16 * 1024]u8 = undefined;
        var body_writer = try request.sendBody(&write_buffer);
        try body_writer.writer.writeAll(body);
        try body_writer.end();
    } else {
        if (body.len != 0) return error.BodyNotAllowed;
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});
    const status = response.head.status;
    const reason = try state.allocator.dupe(u8, response.head.reason);
    defer state.allocator.free(reason);
    const response_headers = try copyResponseHeaders(state.allocator, response.head, state.limits.response_head);
    defer freeHeaders(state.allocator, response_headers);
    var output: std.Io.Writer.Allocating = .init(state.allocator);
    defer output.deinit();
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (output.writer.end + n > state.limits.response_body) return error.ResponseBodyTooLarge;
        try output.writer.writeAll(chunk[0..n]);
    }
    const response_body = try output.toOwnedSlice();
    defer state.allocator.free(response_body);
    try writeResponse(io, downstream, @intFromEnum(status), reason, response_headers, response_body);
}

fn copyResponseHeaders(
    allocator: std.mem.Allocator,
    head: std.http.Client.Response.Head,
    max_bytes: usize,
) ![]std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer freeHeaderList(allocator, &headers);
    var total: usize = 0;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (isHopByHop(header.name) or std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
        total += header.name.len + header.value.len + 4;
        if (total > max_bytes) return error.ResponseHeadersTooLarge;
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .name = name, .value = value });
    }
    return try headers.toOwnedSlice(allocator);
}
fn freeHeaderList(allocator: std.mem.Allocator, headers: *std.ArrayList(std.http.Header)) void {
    for (headers.items) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    headers.deinit(allocator);
}
fn freeHeaders(allocator: std.mem.Allocator, headers: []std.http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}
fn writeResponse(
    io: std.Io,
    stream: std.Io.net.Stream,
    status: u16,
    reason: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason });
    for (headers) |header| try writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
    try writer.interface.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}
fn writeError(io: std.Io, stream: std.Io.net.Stream, status: u16, reason: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ status, reason },
    );
    try writer.interface.flush();
}
fn isHopByHop(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-authenticate") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or std.ascii.eqlIgnoreCase(name, "te") or
        std.ascii.eqlIgnoreCase(name, "trailer") or std.ascii.eqlIgnoreCase(name, "upgrade");
}
fn isAuthorizationError(err: anyerror) bool {
    return err == error.MissingAuthorization or err == error.DuplicateAuthorizationHeader or
        err == error.UnexpectedAuthorizationHeader or err == error.InvalidAuthorizationScheme or
        err == error.PhantomInUnexpectedHeader;
}
fn denialReason(err: anyerror) []const u8 {
    if (isAuthorizationError(err)) return "invalid_auth";
    return switch (err) {
        error.RequestBodyTooLarge => "request_body_too_large",
        error.InvalidTarget => "invalid_target",
        error.UnsupportedTransferEncoding => "unsupported_transfer_encoding",
        else => "invalid_request",
    };
}
fn authorizationReason(err: session_secrets.AuthorizationError) []const u8 {
    return switch (err) {
        error.UnmintedPhantom => "unminted",
        error.WrongProvider => "wrong_provider",
        error.WrongName => "wrong_name",
        error.WrongHost => "wrong_host",
    };
}
fn wipeAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}
fn wake(io: std.Io, port: u16) void {
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    var stream = address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

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

const TestUpstreamState = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    expected_raw: []const u8,
    saw_raw: bool = false,
    saw_phantom: bool = false,
};

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
