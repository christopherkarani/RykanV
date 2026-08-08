const std = @import("std");
const contract = @import("telemetry_contract.zig");
const store = @import("telemetry_store.zig");

pub fn sendQueued(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
) !void {
    var paths = (try store.resolvePaths(allocator, environ_map)) orelse return;
    defer paths.deinit(allocator);
    try store.ensureConfigDir(io, &paths);
    var sender = (try store.SendLock.tryAcquire(io, &paths)) orelse return;
    defer sender.release(io);

    // Keep the store lock through the POST so an append cannot evict an event
    // from the snapshot after it has been sent but before it is removed.
    var lock = try store.StoreLock.acquire(io, &paths);
    defer lock.release(io);

    var state = try store.readState(allocator, io, &paths);
    defer state.deinit(allocator);
    var queue = try store.readQueue(allocator, io, &paths);
    defer queue.deinit(allocator);
    if (queue.items.items.len == 0) return;
    if (!state.state.enabled) {
        try store.writeQueue(io, allocator, &paths, &.{});
        return;
    }

    const body = try contract.renderBatch(allocator, queue.items.items);
    defer allocator.free(body);
    try postBatch(io, environ_map, allocator, body);
    try store.writeQueue(io, allocator, &paths, &.{});
}

fn postBatch(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    body: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    if (!posthogProxyBypassed(environ_map)) {
        try client.initDefaultProxies(arena.allocator(), environ_map);
    }
    const result = try client.fetch(.{
        .location = .{ .url = contract.posthog_batch_endpoint },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    if (result.status.class() != .success) return error.PostHogRejected;
}

pub fn posthogProxyBypassed(environ_map: *const std.process.Environ.Map) bool {
    const raw = environ_map.get("no_proxy") orelse environ_map.get("NO_PROXY") orelse return false;
    var entries = std.mem.splitScalar(u8, raw, ',');
    while (entries.next()) |entry| {
        var host = std.mem.trim(u8, entry, " \t");
        if (host.len == 0) continue;
        if (std.mem.eql(u8, host, "*")) return true;

        if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
            const port = host[colon + 1 ..];
            if (port.len > 0 and std.ascii.isDigit(port[0])) host = host[0..colon];
        }
        if (std.mem.startsWith(u8, host, "*.")) host = host[1..];
        if (std.mem.startsWith(u8, host, ".")) {
            if (std.ascii.eqlIgnoreCase(host[1..], "us.i.posthog.com") or
                std.ascii.endsWithIgnoreCase("us.i.posthog.com", host)) return true;
        } else if (std.ascii.eqlIgnoreCase(host, "us.i.posthog.com")) {
            return true;
        }
    }
    return false;
}
