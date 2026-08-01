//! Bounded extraction of exact launch inputs from `codex mcp list --json`.

const std = @import("std");
const env_scrub = @import("env_scrub.zig");

pub const max_config_bytes: usize = 1024 * 1024;
pub const max_servers: usize = 128;
pub const max_args_per_server: usize = 256;
pub const max_env_per_server: usize = 256;
pub const max_grant_paths: usize = 512;

pub const ParseError = error{
    InputTooLarge,
    InvalidConfig,
    TooManyServers,
    TooManyArguments,
    TooManyGrantPaths,
    OutOfMemory,
};

/// One enabled stdio server from Codex's canonical inventory. All strings are
/// owned. `file_args` contains canonical regular files for exact grants only.
pub const Server = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    path_env: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    file_args: []const []const u8,

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        freeOwnedSlice(allocator, self.args);
        if (self.cwd) |cwd| allocator.free(cwd);
        if (self.path_env) |path| allocator.free(path);
        for (self.env) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(self.env);
        freeOwnedSlice(allocator, self.file_args);
        self.* = undefined;
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const LaunchInventory = struct {
    servers: []Server,
    unmediated_server_names: []const []const u8,

    pub fn deinit(self: *LaunchInventory, allocator: std.mem.Allocator) void {
        for (self.servers) |*server| server.deinit(allocator);
        allocator.free(self.servers);
        freeOwnedSlice(allocator, self.unmediated_server_names);
        self.* = undefined;
    }
};

const ListEntry = struct {
    name: []const u8,
    enabled: bool,
    transport: Transport,
};

const Transport = struct {
    type: []const u8,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
};

pub fn parse(
    allocator: std.mem.Allocator,
    io: std.Io,
    list_json: []const u8,
    home: []const u8,
) ParseError!LaunchInventory {
    if (list_json.len > max_config_bytes) return error.InputTooLarge;
    if (std.mem.indexOfScalar(u8, list_json, 0) != null) return error.InvalidConfig;

    var parsed = std.json.parseFromSlice([]ListEntry, allocator, list_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer parsed.deinit();

    var servers: std.ArrayList(Server) = .empty;
    errdefer freeServerList(allocator, &servers);
    var unmediated_server_names: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &unmediated_server_names);
    var grant_path_count: usize = 0;
    var enabled_server_count: usize = 0;

    for (parsed.value) |entry| {
        if (!entry.enabled) continue;
        if (enabled_server_count == max_servers) return error.TooManyServers;
        enabled_server_count += 1;
        if (!std.mem.eql(u8, entry.transport.type, "stdio")) {
            if (entry.name.len == 0 or containsControl(entry.name)) return error.InvalidConfig;
            try appendCopy(allocator, &unmediated_server_names, entry.name);
            continue;
        }
        const server = try buildServer(allocator, io, entry, home, &grant_path_count);
        servers.append(allocator, server) catch |err| {
            var owned_server = server;
            owned_server.deinit(allocator);
            return err;
        };
    }

    const owned_servers = try servers.toOwnedSlice(allocator);
    errdefer freeServerSlice(allocator, owned_servers);
    return .{
        .servers = owned_servers,
        .unmediated_server_names = try unmediated_server_names.toOwnedSlice(allocator),
    };
}

fn buildServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: ListEntry,
    home: []const u8,
    grant_path_count: *usize,
) ParseError!Server {
    if (entry.name.len == 0 or containsControl(entry.name)) return error.InvalidConfig;
    const command = entry.transport.command orelse return error.InvalidConfig;
    const owned_cwd: ?[]const u8 = if (entry.transport.cwd) |cwd| blk: {
        if (!std.fs.path.isAbsolute(cwd) or containsControl(cwd)) return error.InvalidConfig;
        const canonical = try canonicalDirectoryAlloc(io, allocator, cwd);
        const exact = canonical orelse return error.InvalidConfig;
        if (!isSafeRuntimePath(exact, home)) {
            allocator.free(exact);
            return error.InvalidConfig;
        }
        break :blk exact;
    } else null;
    errdefer if (owned_cwd) |cwd| allocator.free(cwd);
    if (!try isSafeCommand(io, allocator, command, owned_cwd, home)) return error.InvalidConfig;
    const raw_args = entry.transport.args orelse &.{};
    if (raw_args.len > max_args_per_server) return error.TooManyArguments;

    const owned_name = try allocator.dupe(u8, entry.name);
    errdefer allocator.free(owned_name);
    const owned_command = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_command);

    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &args);
    for (raw_args) |arg| {
        if (containsNul(arg)) return error.InvalidConfig;
        try appendCopy(allocator, &args, arg);
    }

    var env_entries: std.ArrayList(EnvVar) = .empty;
    errdefer {
        for (env_entries.items) |env_entry| {
            allocator.free(env_entry.name);
            allocator.free(env_entry.value);
        }
        env_entries.deinit(allocator);
    }
    const owned_path_env: ?[]const u8 = if (entry.transport.env) |env| blk: {
        const object = switch (env) {
            .object => |value| value,
            else => return error.InvalidConfig,
        };
        if (object.count() > max_env_per_server) return error.InvalidConfig;
        var iterator = object.iterator();
        var path_env: ?[]const u8 = null;
        while (iterator.next()) |item| {
            const name = item.key_ptr.*;
            const value = switch (item.value_ptr.*) {
                .string => |string| string,
                else => return error.InvalidConfig,
            };
            if (!safeEnvName(name) or env_scrub.shouldScrubKey(name) or containsNul(value)) {
                return error.InvalidConfig;
            }
            const owned_env_name = try allocator.dupe(u8, name);
            const owned_value = allocator.dupe(u8, value) catch |err| {
                allocator.free(owned_env_name);
                return err;
            };
            env_entries.append(allocator, .{ .name = owned_env_name, .value = owned_value }) catch |err| {
                allocator.free(owned_env_name);
                allocator.free(owned_value);
                return err;
            };
            if (std.mem.eql(u8, name, "PATH")) path_env = value;
        }
        break :blk if (path_env) |value| try allocator.dupe(u8, value) else null;
    } else null;
    errdefer if (owned_path_env) |path| allocator.free(path);

    var file_args: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &file_args);
    for (raw_args) |arg| {
        const path_value = argumentPathValue(arg) orelse continue;
        const candidate = try resolveArgumentPath(allocator, path_value, owned_cwd);
        if (candidate) |path| {
            defer allocator.free(path);
            const canonical = try canonicalRegularFileAlloc(io, allocator, path);
            if (canonical) |exact_file| {
                if (!isSafeRuntimePath(exact_file, home)) {
                    allocator.free(exact_file);
                    return error.InvalidConfig;
                }
                if (containsPath(file_args.items, exact_file)) {
                    allocator.free(exact_file);
                    continue;
                }
                if (grant_path_count.* == max_grant_paths) {
                    allocator.free(exact_file);
                    return error.TooManyGrantPaths;
                }
                file_args.append(allocator, exact_file) catch |err| {
                    allocator.free(exact_file);
                    return err;
                };
                grant_path_count.* += 1;
            }
        }
    }

    const owned_args = try args.toOwnedSlice(allocator);
    errdefer freeOwnedSlice(allocator, owned_args);
    const owned_env = try env_entries.toOwnedSlice(allocator);
    std.mem.sort(EnvVar, owned_env, {}, lessThanEnvName);
    errdefer {
        for (owned_env) |env_entry| {
            allocator.free(env_entry.name);
            allocator.free(env_entry.value);
        }
        allocator.free(owned_env);
    }
    const owned_file_args = try file_args.toOwnedSlice(allocator);
    return .{
        .name = owned_name,
        .command = owned_command,
        .args = owned_args,
        .cwd = owned_cwd,
        .path_env = owned_path_env,
        .env = owned_env,
        .file_args = owned_file_args,
    };
}

pub fn fingerprint(server: Server) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, server.name);
    hashField(&hasher, server.command);
    hashField(&hasher, server.cwd orelse "");
    for (server.args) |arg| hashField(&hasher, arg);
    hashField(&hasher, "--env--");
    for (server.env) |entry| {
        hashField(&hasher, entry.name);
        hashField(&hasher, entry.value);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn lessThanEnvName(_: void, left: EnvVar, right: EnvVar) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn safeEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn containsNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

fn isSafeCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    maybe_cwd: ?[]const u8,
    home: []const u8,
) error{OutOfMemory}!bool {
    if (command.len == 0 or containsControl(command)) return false;
    if (std.fs.path.isAbsolute(command)) return isSafeRuntimePath(command, home);
    if (std.mem.indexOfScalar(u8, command, '/') == null) {
        return !std.mem.eql(u8, command, ".") and !std.mem.eql(u8, command, "..");
    }

    const candidate = try resolveArgumentPath(allocator, command, maybe_cwd);
    const path = candidate orelse return false;
    defer allocator.free(path);
    const canonical = try canonicalRegularFileAlloc(io, allocator, path);
    const exact_command = canonical orelse return false;
    defer allocator.free(exact_command);
    return isSafeRuntimePath(exact_command, home);
}

/// True when a canonical MCP runtime path is narrow enough for an exact grant.
pub fn isSafeRuntimePath(path: []const u8, home: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or containsControl(path)) return false;
    const normalized_path = stripMacOSDataAlias(trimTrailingSlashes(path));
    const normalized_home = stripMacOSDataAlias(trimTrailingSlashes(home));
    if (std.mem.eql(u8, normalized_path, "/") or
        (normalized_home.len > 0 and std.mem.eql(u8, normalized_path, normalized_home)))
    {
        return false;
    }

    var parts = std.mem.splitScalar(u8, normalized_path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.mem.eql(u8, part, ".ssh") or std.mem.eql(u8, part, ".gnupg") or
            std.mem.eql(u8, part, ".aws") or std.mem.eql(u8, part, "Keychains") or
            std.mem.eql(u8, part, "Cookies")) return false;
    }
    return true;
}

/// Positive-root policy for already-canonical command and package paths.
pub fn isApprovedRuntimeCommandPath(path: []const u8, home: []const u8) bool {
    if (!isSafeRuntimePath(path, home)) return false;
    const normalized_path = stripMacOSDataAlias(trimTrailingSlashes(path));
    const normalized_home = stripMacOSDataAlias(trimTrailingSlashes(home));

    const system_roots = [_][]const u8{
        "/usr",
        "/bin",
        "/opt/homebrew",
        "/usr/local",
        "/Applications",
        "/Library/Developer",
    };
    for (system_roots) |root| {
        if (isStrictDescendant(normalized_path, root)) return true;
    }

    const home_tool_roots = [_][]const u8{
        "/.local/bin",
        "/.local/lib/node_modules",
        "/.local/share",
        "/.bun/bin",
        "/.cargo/bin",
        "/.grok/bin",
        "/.kimi-code/bin",
    };
    for (home_tool_roots) |suffix| {
        if (isStrictDescendantOfHomeRoot(normalized_path, normalized_home, suffix)) return true;
    }
    return false;
}

fn isStrictDescendant(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn isStrictDescendantOfHomeRoot(path: []const u8, home: []const u8, suffix: []const u8) bool {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return false;
    const relative = path[home.len..];
    return isStrictDescendant(relative, suffix);
}

fn stripMacOSDataAlias(path: []const u8) []const u8 {
    const prefix = "/System/Volumes/Data";
    if (std.mem.eql(u8, path, prefix)) return "/";
    if (std.mem.startsWith(u8, path, prefix ++ "/")) return path[prefix.len..];
    return path;
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn argumentPathValue(arg: []const u8) ?[]const u8 {
    if (arg.len == 0) return null;
    if (arg[0] == '-') {
        const equals = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
        if (equals + 1 == arg.len) return null;
        return arg[equals + 1 ..];
    }
    if (arg[0] == '@') return if (arg.len > 1) arg[1..] else null;
    return arg;
}

fn resolveArgumentPath(
    allocator: std.mem.Allocator,
    arg: []const u8,
    maybe_cwd: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    if (std.fs.path.isAbsolute(arg)) return try allocator.dupe(u8, arg);
    const cwd = maybe_cwd orelse return null;
    if (!std.fs.path.isAbsolute(cwd) or containsControl(cwd)) return null;
    return try std.fs.path.join(allocator, &.{ cwd, arg });
}

fn canonicalRegularFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.kind != .file) return null;
    const canonical_z = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(canonical_z);
    return try allocator.dupe(u8, canonical_z);
}

fn canonicalDirectoryAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) error{OutOfMemory}!?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch return null;
    defer dir.close(io);
    const canonical_z = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(canonical_z);
    return try allocator.dupe(u8, canonical_z);
}

fn appendCopy(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) error{OutOfMemory}!void {
    const owned = try allocator.dupe(u8, value);
    list.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn containsPath(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

fn freeOwnedList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeServerList(allocator: std.mem.Allocator, list: *std.ArrayList(Server)) void {
    for (list.items) |*server| server.deinit(allocator);
    list.deinit(allocator);
}

fn freeServerSlice(allocator: std.mem.Allocator, servers: []Server) void {
    for (servers) |*server| server.deinit(allocator);
    allocator.free(servers);
}

fn freeOwnedSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "canonical list ignores disabled stdio and remote transports" {
    const list_json =
        \\[
        \\  {"name":"disabled","enabled":false,"transport":{"type":"stdio","command":"disabled-tool","args":[],"env":null,"cwd":null}},
        \\  {"name":"disabled-remote","enabled":false,"transport":{"type":"streamable_http","url":"https://disabled.example.invalid/mcp"}},
        \\  {"name":"remote","enabled":true,"transport":{"type":"streamable_http","url":"https://example.invalid/mcp"}}
        \\]
    ;

    var inventory = try parse(std.testing.allocator, std.testing.io, list_json, "/Users/synthetic");
    defer inventory.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), inventory.servers.len);
    try std.testing.expectEqual(@as(usize, 1), inventory.unmediated_server_names.len);
    try std.testing.expectEqualStrings("remote", inventory.unmediated_server_names[0]);
}

test "canonical list extracts enabled stdio command and absolute Agentify script" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "AgentifyDesktop");
    try tmp.dir.writeFile(io, .{ .sub_path = "AgentifyDesktop/mcp-server.mjs", .data = "// synthetic\n" });
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const script = try tmp.dir.realPathFileAlloc(io, "AgentifyDesktop/mcp-server.mjs", allocator);
    defer allocator.free(script);
    const list_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"name\":\"agentify\",\"enabled\":true,\"transport\":{{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"{s}\",\"--stdio\"],\"env\":{{\"PATH\":\"/custom/bin\"}},\"cwd\":null}}}}]",
        .{script},
    );
    defer allocator.free(list_json);

    var inventory = try parse(allocator, io, list_json, home);
    defer inventory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), inventory.servers.len);
    const server = inventory.servers[0];
    try std.testing.expectEqualStrings("agentify", server.name);
    try std.testing.expectEqualStrings("node", server.command);
    try std.testing.expectEqual(@as(usize, 2), server.args.len);
    try std.testing.expectEqualStrings(script, server.args[0]);
    try std.testing.expectEqualStrings("--stdio", server.args[1]);
    try std.testing.expect(server.cwd == null);
    try std.testing.expectEqualStrings("/custom/bin", server.path_env.?);
    try std.testing.expectEqual(@as(usize, 1), server.env.len);
    try std.testing.expectEqualStrings("PATH", server.env[0].name);
    try std.testing.expectEqualStrings("/custom/bin", server.env[0].value);
    try std.testing.expectEqual(@as(usize, 1), server.file_args.len);
    try std.testing.expectEqualStrings(script, server.file_args[0]);
}

test "canonical list accepts multiline values and rejects loader injection" {
    var accepted = try parse(
        std.testing.allocator,
        std.testing.io,
        "[{\"name\":\"safe\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"/bin/sh\",\"args\":[\"line\\nvalue\"],\"env\":{\"MCP_CERT\":\"line\\nvalue\"},\"cwd\":null}}]",
        "/Users/synthetic",
    );
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("line\nvalue", accepted.servers[0].args[0]);
    try std.testing.expectEqualStrings("line\nvalue", accepted.servers[0].env[0].value);
    try std.testing.expectError(
        error.InvalidConfig,
        parse(
            std.testing.allocator,
            std.testing.io,
            "[{\"name\":\"unsafe\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"/bin/sh\",\"args\":[],\"env\":{\"NODE_OPTIONS\":\"--require=/tmp/inject.js\"},\"cwd\":null}}]",
            "/Users/synthetic",
        ),
    );
}

test "relative plugin script resolves against transport cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "plugin/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "plugin/bin/server.js", .data = "// synthetic\n" });
    const cwd = try tmp.dir.realPathFileAlloc(io, "plugin", allocator);
    defer allocator.free(cwd);
    const cwd_dot = try std.fmt.allocPrint(allocator, "{s}/.", .{cwd});
    defer allocator.free(cwd_dot);
    const script = try tmp.dir.realPathFileAlloc(io, "plugin/bin/server.js", allocator);
    defer allocator.free(script);
    const list_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"name\":\"plugin\",\"enabled\":true,\"transport\":{{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"bin/server.js\"],\"env\":{{}},\"cwd\":\"{s}\"}}}}]",
        .{cwd_dot},
    );
    defer allocator.free(list_json);

    var inventory = try parse(allocator, io, list_json, "/Users/synthetic");
    defer inventory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), inventory.servers.len);
    const server = inventory.servers[0];
    try std.testing.expectEqualStrings(cwd, server.cwd.?);
    try std.testing.expectEqualStrings("bin/server.js", server.args[0]);
    try std.testing.expectEqual(@as(usize, 1), server.file_args.len);
    try std.testing.expectEqualStrings(script, server.file_args[0]);
}

test "bare and attached-option files resolve against transport cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "server.js", .data = "// synthetic\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}\n" });
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const server = try tmp.dir.realPathFileAlloc(io, "server.js", allocator);
    defer allocator.free(server);
    const settings = try tmp.dir.realPathFileAlloc(io, "settings.json", allocator);
    defer allocator.free(settings);
    const list_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"name\":\"files\",\"enabled\":true,\"transport\":{{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"server.js\",\"--config=settings.json\"],\"cwd\":\"{s}\"}}}}]",
        .{cwd},
    );
    defer allocator.free(list_json);

    var inventory = try parse(allocator, io, list_json, "/Users/synthetic");
    defer inventory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), inventory.servers[0].file_args.len);
    try std.testing.expectEqualStrings(server, inventory.servers[0].file_args[0]);
    try std.testing.expectEqualStrings(settings, inventory.servers[0].file_args[1]);
}

test "relative stdio command is preserved when it resolves from absolute cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "plugin/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "plugin/bin/server", .data = "#!/bin/sh\n" });
    const cwd = try tmp.dir.realPathFileAlloc(io, "plugin", allocator);
    defer allocator.free(cwd);
    const list_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"name\":\"relative-command\",\"enabled\":true,\"transport\":{{\"type\":\"stdio\",\"command\":\"./bin/server\",\"args\":[],\"cwd\":\"{s}\"}}}}]",
        .{cwd},
    );
    defer allocator.free(list_json);

    var inventory = try parse(allocator, io, list_json, "/Users/synthetic");
    defer inventory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), inventory.servers.len);
    try std.testing.expectEqualStrings("./bin/server", inventory.servers[0].command);
    try std.testing.expectEqualStrings(cwd, inventory.servers[0].cwd.?);
}

test "malformed NUL and oversized canonical output fail closed" {
    try std.testing.expectError(error.InvalidConfig, parse(
        std.testing.allocator,
        std.testing.io,
        "[{\"name\":\"bad\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":7}}]",
        "/Users/synthetic",
    ));
    try std.testing.expectError(error.InvalidConfig, parse(
        std.testing.allocator,
        std.testing.io,
        "[{\"name\":\"bad\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"no\\u0000de\",\"args\":[]}}]",
        "/Users/synthetic",
    ));

    const oversized = try std.testing.allocator.alloc(u8, max_config_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.InputTooLarge, parse(
        std.testing.allocator,
        std.testing.io,
        oversized,
        "/Users/synthetic",
    ));
}

test "root bare home secret components and macOS data alias home are rejected" {
    try std.testing.expect(!isSafeRuntimePath("/", "/Users/synthetic"));
    try std.testing.expect(!isSafeRuntimePath("/Users/synthetic", "/Users/synthetic"));
    try std.testing.expect(!isSafeRuntimePath(
        "/System/Volumes/Data/Users/synthetic",
        "/Users/synthetic",
    ));
    try std.testing.expect(!isSafeRuntimePath(
        "/System/Volumes/Data/Users/synthetic/.ssh/key",
        "/Users/synthetic",
    ));
    try std.testing.expect(isSafeRuntimePath(
        "/System/Volumes/Data/Users/synthetic/AgentifyDesktop/mcp-server.mjs",
        "/Users/synthetic",
    ));
}

test "approved runtime commands use only system package app and narrow home tool roots" {
    const home = "/Users/synthetic";
    try std.testing.expect(isApprovedRuntimeCommandPath("/usr/bin/node", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/bin/sh", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/opt/homebrew/bin/npx", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/usr/local/bin/node", home));
    try std.testing.expect(isApprovedRuntimeCommandPath(
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        home,
    ));
    try std.testing.expect(isApprovedRuntimeCommandPath(
        "/System/Volumes/Data/Users/synthetic/.local/bin/mcp-remote",
        home,
    ));
    try std.testing.expect(isApprovedRuntimeCommandPath(
        "/Users/synthetic/.local/lib/node_modules/server/index.js",
        home,
    ));
    try std.testing.expect(isApprovedRuntimeCommandPath("/Users/synthetic/.bun/bin/bun", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/Users/synthetic/.cargo/bin/tool", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/Users/synthetic/.grok/bin/grok", home));
    try std.testing.expect(isApprovedRuntimeCommandPath("/Users/synthetic/.kimi-code/bin/kimi", home));

    try std.testing.expect(!isApprovedRuntimeCommandPath("/usr", home));
    try std.testing.expect(!isApprovedRuntimeCommandPath("/Applications", home));
    try std.testing.expect(!isApprovedRuntimeCommandPath("/Users/synthetic/.codex/bin/tool", home));
    try std.testing.expect(!isApprovedRuntimeCommandPath("/Users/synthetic/Documents/tool", home));
    try std.testing.expect(!isApprovedRuntimeCommandPath("/Users/synthetic/Desktop/tool", home));
    try std.testing.expect(!isApprovedRuntimeCommandPath("/Users/synthetic/.ssh/tool", home));
}

test "result owns server fields and canonical file path independently of JSON storage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "server.js", .data = "// synthetic\n" });
    const script = try tmp.dir.realPathFileAlloc(io, "server.js", allocator);
    defer allocator.free(script);
    const list_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"name\":\"owned\",\"enabled\":true,\"transport\":{{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"{s}\"],\"cwd\":null}}}}]",
        .{script},
    );

    var inventory = try parse(allocator, io, list_json, "/Users/synthetic");
    @memset(list_json, 'x');
    allocator.free(list_json);
    defer inventory.deinit(allocator);
    const server = inventory.servers[0];
    try std.testing.expectEqualStrings("owned", server.name);
    try std.testing.expectEqualStrings("node", server.command);
    try std.testing.expectEqualStrings(script, server.args[0]);
    try std.testing.expectEqualStrings(script, server.file_args[0]);
}

test "server and per-server argument counts are bounded" {
    const allocator = std.testing.allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '[');
    for (0..max_servers + 1) |index| {
        if (index != 0) try json.append(allocator, ',');
        const entry = try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"s{d}\",\"enabled\":true,\"transport\":{{\"type\":\"streamable_http\",\"url\":\"https://example.invalid/mcp\"}}}}",
            .{index},
        );
        defer allocator.free(entry);
        try json.appendSlice(allocator, entry);
    }
    try json.append(allocator, ']');
    try std.testing.expectError(error.TooManyServers, parse(
        allocator,
        std.testing.io,
        json.items,
        "/Users/synthetic",
    ));

    json.clearRetainingCapacity();
    try json.appendSlice(allocator, "[{\"name\":\"many-args\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"node\",\"args\":[");
    for (0..max_args_per_server + 1) |index| {
        if (index != 0) try json.append(allocator, ',');
        try json.appendSlice(allocator, "\"value\"");
    }
    try json.appendSlice(allocator, "]}}]");
    try std.testing.expectError(error.TooManyArguments, parse(
        allocator,
        std.testing.io,
        json.items,
        "/Users/synthetic",
    ));
}

test "total canonical grant paths are bounded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "files");
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const cwd_json = try std.json.Stringify.valueAlloc(allocator, cwd, .{});
    defer allocator.free(cwd_json);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "[{\"name\":\"paths-a\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"node\",\"cwd\":");
    try json.appendSlice(allocator, cwd_json);
    try json.appendSlice(allocator, ",\"args\":[");
    for (0..max_args_per_server) |index| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "files/a-{d}.js", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "// synthetic\n" });
        if (index != 0) try json.append(allocator, ',');
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
        defer allocator.free(quoted);
        try json.appendSlice(allocator, quoted);
    }
    try json.appendSlice(allocator, "]}} ,{\"name\":\"paths-b\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"node\",\"cwd\":");
    try json.appendSlice(allocator, cwd_json);
    try json.appendSlice(allocator, ",\"args\":[");
    for (0..max_args_per_server) |index| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "files/b-{d}.js", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "// synthetic\n" });
        if (index != 0) try json.append(allocator, ',');
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
        defer allocator.free(quoted);
        try json.appendSlice(allocator, quoted);
    }
    try json.appendSlice(allocator, "]}} ,{\"name\":\"paths-c\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"files/overflow.js\"],\"cwd\":");
    try json.appendSlice(allocator, cwd_json);
    try json.appendSlice(allocator, "}}]");
    try tmp.dir.writeFile(io, .{ .sub_path = "files/overflow.js", .data = "// synthetic\n" });

    try std.testing.expectError(error.TooManyGrantPaths, parse(
        allocator,
        io,
        json.items,
        "/Users/synthetic",
    ));
}
