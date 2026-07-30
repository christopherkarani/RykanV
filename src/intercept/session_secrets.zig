const std = @import("std");

const policy_schema = @import("orca_core").policy.schema;

pub const Provider = policy_schema.CredentialProvider;

/// Borrowed grant configuration. `Store.captureHostEnv` duplicates every
/// retained field, so callers may release this storage after the call.
pub const GrantSpec = struct {
    env_var: []const u8,
    provider: Provider,
    allowed_hosts: []const []const u8,
};

/// A minted payload is a view into store-owned memory and expires at deinit.
pub const CaptureResult = union(enum) {
    minted: []const u8,
    skipped_unset,
    skipped_empty,
};

pub const AuthorizationError = error{
    UnmintedPhantom,
    WrongProvider,
    WrongName,
    WrongHost,
};

/// Borrowed view into a store entry. Every slice expires when the store is
/// mutated only by deinit; adding entries does not move their owned buffers.
pub const SecretView = struct {
    env_var: []const u8,
    provider: Provider,
    allowed_hosts: []const []const u8,
    phantom: []const u8,
    raw: []const u8,
};

const session_random_bytes = 16;
const session_hex_len = session_random_bytes * 2;
const nonce_random_bytes = 8;
const nonce_hex_len = nonce_random_bytes * 2;

pub const Store = struct {
    const Self = @This();

    io: std.Io,
    allocator: std.mem.Allocator,
    session_hex: [session_hex_len]u8,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
        var session_bytes: [session_random_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &session_bytes);
        try io.randomSecure(&session_bytes);

        return .{
            .io = io,
            .allocator = allocator,
            .session_hex = std.fmt.bytesToHex(session_bytes, .lower),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        std.crypto.secureZero(u8, &self.session_hex);
        self.* = undefined;
    }

    /// Captures one host environment grant. Missing and empty values are
    /// explicit non-errors; malformed grant metadata fails closed.
    pub fn captureHostEnv(
        self: *Self,
        host_env: *const std.process.Environ.Map,
        spec: GrantSpec,
    ) !CaptureResult {
        try validateGrant(spec);
        if (self.hasEnvVar(spec.env_var)) return error.DuplicateGrant;
        const raw = host_env.get(spec.env_var) orelse return .skipped_unset;
        if (raw.len == 0) return .skipped_empty;
        return .{ .minted = try self.captureRaw(spec, raw) };
    }

    /// Capture a parent-resolved broker value. The caller may wipe its source
    /// immediately after this returns; the store owns a distinct copy.
    pub fn captureResolved(self: *Self, spec: GrantSpec, raw: []const u8) ![]const u8 {
        try validateGrant(spec);
        if (self.hasEnvVar(spec.env_var)) return error.DuplicateGrant;
        if (raw.len == 0) return error.EmptyResolvedSecret;
        return try self.captureRaw(spec, raw);
    }

    fn captureRaw(self: *Self, spec: GrantSpec, raw: []const u8) ![]const u8 {
        var nonce_bytes: [nonce_random_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &nonce_bytes);
        try self.io.randomSecure(&nonce_bytes);
        var nonce_hex = std.fmt.bytesToHex(nonce_bytes, .lower);
        defer std.crypto.secureZero(u8, &nonce_hex);

        var entry = try Entry.init(
            self.allocator,
            &self.session_hex,
            &nonce_hex,
            spec,
            raw,
        );
        errdefer entry.deinit(self.allocator);
        try self.entries.append(self.allocator, entry);
        return entry.phantom;
    }

    /// Exact mint-table lookup. Prefix-shaped or one-byte-mutated tokens do
    /// not gain authority.
    pub fn lookup(self: *const Self, phantom: []const u8) ?SecretView {
        for (self.entries.items) |entry| {
            if (secureTokenEql(entry.phantom, phantom)) return entry.view();
        }
        return null;
    }

    pub fn authorize(
        self: *const Self,
        phantom: []const u8,
        provider: Provider,
        env_var: []const u8,
        upstream_host: []const u8,
    ) AuthorizationError!SecretView {
        const entry = self.findEntry(phantom) orelse return error.UnmintedPhantom;
        if (entry.provider != provider) return error.WrongProvider;
        if (!std.mem.eql(u8, entry.env_var, env_var)) return error.WrongName;
        for (entry.allowed_hosts) |allowed_host| {
            if (std.ascii.eqlIgnoreCase(allowed_host, upstream_host)) return entry.view();
        }
        return error.WrongHost;
    }

    pub fn hasProvider(self: *const Self, provider: Provider) bool {
        for (self.entries.items) |entry| {
            if (entry.provider == provider) return true;
        }
        return false;
    }

    pub fn hasEnvVar(self: *const Self, env_var: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_var, env_var)) return true;
        }
        return false;
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Inject only values minted by this store. Existing values for a granted
    /// name are replaced, so raw or free-form values cannot survive.
    pub fn injectPhantoms(self: *const Self, env_map: *std.process.Environ.Map) !usize {
        for (self.entries.items) |entry| try env_map.put(entry.env_var, entry.phantom);
        return self.entries.items.len;
    }

    /// Exact name-and-token membership used by the sandbox launch allowlist.
    pub fn isMintedEnv(self: *const Self, env_var: []const u8, value: []const u8) bool {
        const entry = self.findEntry(value) orelse return false;
        return std.mem.eql(u8, entry.env_var, env_var);
    }

    pub fn mintedEnvContains(
        context: *const anyopaque,
        env_var: []const u8,
        value: []const u8,
    ) bool {
        const self: *const Self = @ptrCast(@alignCast(context));
        return self.isMintedEnv(env_var, value);
    }

    fn findEntry(self: *const Self, phantom: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (secureTokenEql(entry.phantom, phantom)) return entry;
        }
        return null;
    }
};

const Entry = struct {
    env_var: []u8,
    provider: Provider,
    allowed_hosts: []const []const u8,
    phantom: []u8,
    raw: []u8,

    fn init(
        allocator: std.mem.Allocator,
        session_hex: []const u8,
        nonce_hex: []const u8,
        spec: GrantSpec,
        raw: []const u8,
    ) !Entry {
        const owned_env_var = try allocator.dupe(u8, spec.env_var);
        errdefer allocator.free(owned_env_var);

        const owned_hosts = try duplicateHosts(allocator, spec.allowed_hosts);
        errdefer freeHosts(allocator, owned_hosts);

        const owned_raw = try allocator.dupe(u8, raw);
        errdefer wipeAndFree(allocator, owned_raw);

        const phantom = try std.fmt.allocPrint(
            allocator,
            "orca-secret://session/{s}/{s}/{s}",
            .{ session_hex, spec.env_var, nonce_hex },
        );
        errdefer wipeAndFree(allocator, phantom);

        return .{
            .env_var = owned_env_var,
            .provider = spec.provider,
            .allowed_hosts = owned_hosts,
            .phantom = phantom,
            .raw = owned_raw,
        };
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.env_var);
        freeHosts(allocator, self.allowed_hosts);
        wipeAndFree(allocator, self.raw);
        wipeAndFree(allocator, self.phantom);
        self.* = undefined;
    }

    fn view(self: *const Entry) SecretView {
        return .{
            .env_var = self.env_var,
            .provider = self.provider,
            .allowed_hosts = self.allowed_hosts,
            .phantom = self.phantom,
            .raw = self.raw,
        };
    }
};

fn validateGrant(spec: GrantSpec) !void {
    if (!isValidEnvName(spec.env_var)) return error.InvalidEnvName;
    if (spec.allowed_hosts.len == 0) return error.MissingAllowedHost;
    for (spec.allowed_hosts) |host| {
        if (host.len == 0 or std.mem.trim(u8, host, " \t\r\n").len != host.len) {
            return error.InvalidAllowedHost;
        }
    }
}

fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] != '_' and !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |byte| {
        if (byte != '_' and !std.ascii.isAlphanumeric(byte)) return false;
    }
    return true;
}

fn duplicateHosts(
    allocator: std.mem.Allocator,
    hosts: []const []const u8,
) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, hosts.len);
    errdefer allocator.free(owned);
    var initialized: usize = 0;
    errdefer for (owned[0..initialized]) |host| allocator.free(host);
    for (hosts) |host| {
        owned[initialized] = try allocator.dupe(u8, host);
        initialized += 1;
    }
    return owned;
}

fn freeHosts(allocator: std.mem.Allocator, hosts: []const []const u8) void {
    for (hosts) |host| allocator.free(host);
    allocator.free(hosts);
}

fn wipeAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    // `Allocator.free` poisons bytes with `undefined` before delegating to the
    // allocator. Delegate directly after the volatile wipe so the final
    // observable contents before release are zero, not the secret or poison.
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

fn secureTokenEql(expected: []const u8, candidate: []const u8) bool {
    if (expected.len != candidate.len) return false;
    var difference: u8 = 0;
    for (expected, candidate) |left, right| difference |= left ^ right;
    return difference == 0;
}

test "session store mints exact tokens and distinguishes authorization denials" {
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-synthetic");

    var store = try Store.init(std.testing.io, std.testing.allocator);
    defer store.deinit();

    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try expectPhantomShape(phantom, "ANTHROPIC_API_KEY");
    const found = store.lookup(phantom).?;
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", found.env_var);
    try std.testing.expectEqualStrings("sk-ant-synthetic", found.raw);
    try std.testing.expectEqual(Provider.anthropic, found.provider);
    try std.testing.expectEqualStrings("api.anthropic.com", found.allowed_hosts[0]);
    try std.testing.expect(store.hasProvider(.anthropic));
    try std.testing.expect(!store.hasProvider(.openai));

    const authorized = try store.authorize(phantom, .anthropic, "ANTHROPIC_API_KEY", "api.anthropic.com");
    try std.testing.expectEqualStrings("sk-ant-synthetic", authorized.raw);

    var mutated = try std.testing.allocator.dupe(u8, phantom);
    defer std.testing.allocator.free(mutated);
    mutated[mutated.len - 1] = if (mutated[mutated.len - 1] == '0') '1' else '0';
    try std.testing.expect(store.lookup(mutated) == null);
    try std.testing.expectError(
        error.UnmintedPhantom,
        store.authorize(mutated, .anthropic, "ANTHROPIC_API_KEY", "api.anthropic.com"),
    );
    try std.testing.expectError(
        error.WrongProvider,
        store.authorize(phantom, .openai, "ANTHROPIC_API_KEY", "api.anthropic.com"),
    );
    try std.testing.expectError(
        error.WrongName,
        store.authorize(phantom, .anthropic, "OPENAI_API_KEY", "api.anthropic.com"),
    );
    try std.testing.expectError(
        error.WrongHost,
        store.authorize(phantom, .anthropic, "ANTHROPIC_API_KEY", "example.invalid"),
    );
}

test "host capture reports unset and empty values and validates grants" {
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();

    var store = try Store.init(std.testing.io, std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(
        CaptureResult.skipped_unset,
        try store.captureHostEnv(&host_env, .{
            .env_var = "OPENAI_API_KEY",
            .provider = .openai,
            .allowed_hosts = &.{"api.openai.com"},
        }),
    );

    try host_env.put("OPENAI_API_KEY", "");
    try std.testing.expectEqual(
        CaptureResult.skipped_empty,
        try store.captureHostEnv(&host_env, .{
            .env_var = "OPENAI_API_KEY",
            .provider = .openai,
            .allowed_hosts = &.{"api.openai.com"},
        }),
    );

    try std.testing.expectError(
        error.InvalidEnvName,
        store.captureHostEnv(&host_env, .{
            .env_var = "OPENAI-API-KEY",
            .provider = .openai,
            .allowed_hosts = &.{"api.openai.com"},
        }),
    );
    try std.testing.expectError(
        error.MissingAllowedHost,
        store.captureHostEnv(&host_env, .{
            .env_var = "OPENAI_API_KEY",
            .provider = .openai,
            .allowed_hosts = &.{},
        }),
    );
    try std.testing.expectError(
        error.InvalidAllowedHost,
        store.captureHostEnv(&host_env, .{
            .env_var = "OPENAI_API_KEY",
            .provider = .openai,
            .allowed_hosts = &.{""},
        }),
    );
}

test "session and nonce randomness make minted phantoms unique" {
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("OPENAI_API_KEY", "sk-openai-synthetic");
    try host_env.put("OPENAI_SECONDARY_KEY", "sk-openai-synthetic-secondary");

    var first_store = try Store.init(std.testing.io, std.testing.allocator);
    defer first_store.deinit();
    var second_store = try Store.init(std.testing.io, std.testing.allocator);
    defer second_store.deinit();

    const spec: GrantSpec = .{
        .env_var = "OPENAI_API_KEY",
        .provider = .openai,
        .allowed_hosts = &.{"api.openai.com"},
    };
    const first = switch (try first_store.captureHostEnv(&host_env, spec)) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const second_same_session = switch (try first_store.captureHostEnv(&host_env, .{
        .env_var = "OPENAI_SECONDARY_KEY",
        .provider = .openai,
        .allowed_hosts = &.{"api.openai.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const second_session = switch (try second_store.captureHostEnv(&host_env, spec)) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expect(!std.mem.eql(u8, first, second_same_session));
    try std.testing.expect(!std.mem.eql(u8, first, second_session));
}

test "session store cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, captureAllocationFailureProbe, .{});
}

test "session store wipes raw and phantom bytes before free" {
    var checking = WipeCheckingAllocator.init(std.testing.allocator);
    const allocator = checking.allocator();

    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-wipe-canary");

    var store = try Store.init(std.testing.io, allocator);
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const found = store.lookup(phantom).?;
    checking.watch(0, found.raw);
    checking.watch(1, found.phantom);

    store.deinit();

    try std.testing.expect(checking.observed[0]);
    try std.testing.expect(checking.observed[1]);
    try std.testing.expect(checking.zeroed[0]);
    try std.testing.expect(checking.zeroed[1]);
}

test "session store injects and retains only exact minted name-value pairs" {
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("ANTHROPIC_API_KEY", "sk-ant-host-canary");

    var store = try Store.init(std.testing.io, std.testing.allocator);
    defer store.deinit();
    const phantom = switch (try store.captureHostEnv(&host_env, .{
        .env_var = "ANTHROPIC_API_KEY",
        .provider = .anthropic,
        .allowed_hosts = &.{"api.anthropic.com"},
    })) {
        .minted => |value| value,
        else => return error.TestUnexpectedResult,
    };

    var child_env = std.process.Environ.Map.init(std.testing.allocator);
    defer child_env.deinit();
    try child_env.put("ANTHROPIC_API_KEY", "sk-ant-host-canary");
    try std.testing.expectEqual(@as(usize, 1), try store.injectPhantoms(&child_env));
    try std.testing.expectEqualStrings(phantom, child_env.get("ANTHROPIC_API_KEY").?);
    try std.testing.expect(store.isMintedEnv("ANTHROPIC_API_KEY", phantom));
    try std.testing.expect(!store.isMintedEnv("OPENAI_API_KEY", phantom));
    try std.testing.expect(!store.isMintedEnv(
        "ANTHROPIC_API_KEY",
        "orca-secret://session/evil/ANTHROPIC_API_KEY/0000000000000000",
    ));

    try std.testing.expectError(
        error.DuplicateGrant,
        store.captureHostEnv(&host_env, .{
            .env_var = "ANTHROPIC_API_KEY",
            .provider = .anthropic,
            .allowed_hosts = &.{"api.anthropic.com"},
        }),
    );
}

fn captureAllocationFailureProbe(allocator: std.mem.Allocator) !void {
    var host_env = std.process.Environ.Map.init(std.testing.allocator);
    defer host_env.deinit();
    try host_env.put("OPENAI_API_KEY", "sk-openai-allocation-canary");

    var store = try Store.init(std.testing.io, allocator);
    defer store.deinit();
    _ = try store.captureHostEnv(&host_env, .{
        .env_var = "OPENAI_API_KEY",
        .provider = .openai,
        .allowed_hosts = &.{ "api.openai.com", "uploads.openai.com" },
    });
}

fn expectPhantomShape(phantom: []const u8, env_var: []const u8) !void {
    const prefix = "orca-secret://session/";
    try std.testing.expect(std.mem.startsWith(u8, phantom, prefix));
    const after_prefix = phantom[prefix.len..];
    const session_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 32), session_end);
    try expectLowerHex(after_prefix[0..session_end]);

    const after_session = after_prefix[session_end + 1 ..];
    try std.testing.expect(std.mem.startsWith(u8, after_session, env_var));
    try std.testing.expectEqual('/', after_session[env_var.len]);
    const nonce = after_session[env_var.len + 1 ..];
    try std.testing.expectEqual(@as(usize, 16), nonce.len);
    try expectLowerHex(nonce);
}

fn expectLowerHex(value: []const u8) !void {
    for (value) |byte| {
        try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }
}

const WipeCheckingAllocator = struct {
    const Self = @This();
    const Watch = struct {
        ptr: ?[*]const u8 = null,
        len: usize = 0,
    };

    backing: std.mem.Allocator,
    watches: [2]Watch = .{ .{}, .{} },
    observed: [2]bool = .{ false, false },
    zeroed: [2]bool = .{ false, false },

    fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn watch(self: *Self, index: usize, bytes: []const u8) void {
        self.watches[index] = .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Self = @ptrCast(@alignCast(context));
        for (self.watches, 0..) |watch_item, index| {
            const watched_ptr = watch_item.ptr orelse continue;
            if (@intFromPtr(watched_ptr) != @intFromPtr(memory.ptr) or watch_item.len != memory.len) continue;
            self.observed[index] = true;
            self.zeroed[index] = std.mem.allEqual(u8, memory, 0);
        }
        self.backing.rawFree(memory, alignment, return_address);
    }
};
