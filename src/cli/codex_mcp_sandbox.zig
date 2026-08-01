//! Protected Codex MCP launch planning for macOS Seatbelt sessions.
//!
//! Codex supplies its fully resolved MCP inventory. Ryk wraps every usable
//! stdio server through `ryk mcp proxy`, disables unmediated transports, and
//! derives filesystem grants only from positive runtime roots or a protected
//! `.orca/mcp` manifest.

const std = @import("std");
const builtin = @import("builtin");

const orca_mcp = @import("../mcp/mod.zig");
const sandbox = @import("../sandbox/mod.zig");

const inventory_limit = sandbox.mcp_runtime_grants.max_config_bytes;
const stderr_limit: usize = 32 * 1024;
const max_manifest_files: usize = 128;

pub const PlanError = error{
    InventoryCommandFailed,
    InvalidInventory,
    TooManyPaths,
    SessionTmpPrepareFailed,
    OutOfMemory,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    exec_paths: []const []const u8,
    ro_paths: []const []const u8,
    disabled_server_names: []const []const u8,
    wrapper_root: []const u8,
    audit_root: []const u8,

    pub fn deinit(self: *Plan, io: std.Io) void {
        freeOwnedStrings(self.allocator, self.argv);
        freeOwnedStrings(self.allocator, self.exec_paths);
        freeOwnedStrings(self.allocator, self.ro_paths);
        freeOwnedStrings(self.allocator, self.disabled_server_names);
        std.Io.Dir.cwd().deleteTree(io, self.wrapper_root) catch {};
        // Child-writable proxy logs are operational output, not durable
        // attestation. Remove them with the launch plan to avoid unbounded,
        // tamperable audit accumulation.
        std.Io.Dir.cwd().deleteTree(io, self.audit_root) catch {};
        self.allocator.free(self.wrapper_root);
        self.allocator.free(self.audit_root);
        self.* = undefined;
    }
};

pub fn prepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    original_argv: []const []const u8,
    workspace_root: []const u8,
    policy_path: []const u8,
    mode: []const u8,
    env_map: *const std.process.Environ.Map,
) !?Plan {
    if (builtin.os.tag != .macos or original_argv.len == 0) return null;
    // Require trusted codex launch identity — do not grant inventory host-config
    // from a basename spoof or bare string (F-02 / S1A).
    var identity = try sandbox.host_identity.resolveHostIdentity(
        io,
        allocator,
        original_argv[0],
        env_map,
        .{ .workspace_root = workspace_root },
    );
    defer identity.deinit(allocator);
    if (!identity.isTrusted() or !std.mem.eql(u8, identity.hostKey(), "codex")) {
        return null;
    }

    var list_argv: std.ArrayList([]const u8) = .empty;
    defer list_argv.deinit(allocator);
    try list_argv.append(allocator, original_argv[0]);
    var inventory_cwd: ?[]const u8 = null;
    try appendInventorySelectors(allocator, &list_argv, original_argv[1..], &inventory_cwd);
    try list_argv.appendSlice(allocator, &.{ "mcp", "list", "--json" });
    const selected_cwd = inventory_cwd orelse workspace_root;
    const owned_inventory_cwd = if (std.fs.path.isAbsolute(selected_cwd))
        null
    else
        try std.fs.path.join(allocator, &.{ workspace_root, selected_cwd });
    defer if (owned_inventory_cwd) |path| allocator.free(path);
    const effective_inventory_cwd = owned_inventory_cwd orelse selected_cwd;
    // Single bind: reuse prepare()'s trusted host key; do not re-resolve argv0.
    const result = runCanonicalInventorySandboxed(
        io,
        allocator,
        list_argv.items,
        effective_inventory_cwd,
        workspace_root,
        env_map,
        identity.hostKey(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionTmpPrepareFailed => return error.SessionTmpPrepareFailed,
        else => return error.InventoryCommandFailed,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.InventoryCommandFailed,
        else => return error.InventoryCommandFailed,
    }

    const home = env_map.get("HOME") orelse "";
    var inventory = sandbox.mcp_runtime_grants.parse(allocator, io, result.stdout, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInventory,
    };
    defer inventory.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    return try buildFromInventory(
        io,
        allocator,
        original_argv,
        workspace_root,
        policy_path,
        mode,
        home,
        env_map,
        self_exe,
        inventory,
    );
}

fn runCanonicalInventorySandboxed(
    io: std.Io,
    allocator: std.mem.Allocator,
    inventory_argv: []const []const u8,
    inventory_cwd: []const u8,
    workspace_root: []const u8,
    env_map: *const std.process.Environ.Map,
    /// Already-bound trusted host_config_table key from prepare() (empty → no host grants).
    trusted_host_key: []const u8,
) !std.process.RunResult {
    if (builtin.os.tag != .macos or inventory_argv.len == 0) return error.InventoryCommandFailed;
    std.Io.Dir.cwd().access(io, "/usr/bin/sandbox-exec", .{}) catch return error.InventoryCommandFailed;
    if (!sandbox.apply.ensureWorkspaceSessionTmp(workspace_root)) return error.SessionTmpPrepareFailed;
    const workspace_tmp = try sandbox.apply.workspaceSessionTmpPath(allocator, workspace_root);
    defer allocator.free(workspace_tmp);
    const inventory_tmp = try sandbox.apply.createFreshAttachTmp(io, allocator, workspace_tmp);
    defer {
        std.Io.Dir.cwd().deleteTree(io, inventory_tmp) catch {};
        allocator.free(inventory_tmp);
    }

    const home = env_map.get("HOME") orelse "";
    // Grants use the single-bound table key from prepare() only — never re-resolve
    // argv0 or hardcode a host string here (M-7 / F-02 single-bind).
    const host_ro = if (trusted_host_key.len > 0)
        try sandbox.host_config_grants.collectHostConfigPaths(io, allocator, trusted_host_key, home)
    else
        try allocator.alloc([]const u8, 0);
    defer sandbox.host_config_grants.freeHostConfigPaths(allocator, host_ro);
    var ro_paths: std.ArrayList([]const u8) = .empty;
    defer ro_paths.deinit(allocator);
    try ro_paths.append(allocator, workspace_root);
    try ro_paths.appendSlice(allocator, host_ro);
    if (env_map.get("CODEX_HOME")) |custom_root| {
        if (std.fs.path.isAbsolute(custom_root) and isPathWithin(custom_root, home) and
            !sandbox.host_config_grants.isForbiddenHostConfigPath(custom_root, home))
        {
            try ro_paths.append(allocator, custom_root);
        }
    }

    const codex_exec = try sandbox.apply.collectLaunchExecPaths(
        io,
        allocator,
        inventory_argv[0],
        env_map,
    );
    defer sandbox.apply.freeLaunchExecPaths(allocator, codex_exec);
    if (codex_exec.len == 0) return error.InventoryCommandFailed;
    var compiled = try sandbox.profile.compileProfile(allocator, .{
        .workspace_root = inventory_tmp,
        .exec_paths = codex_exec,
        .ro_paths = ro_paths.items,
        .include_tmp = false,
    });
    defer compiled.deinit();
    const sbpl = try sandbox.macos_profile.renderSbplWithOptions(allocator, &compiled, .{
        .profile_grade = .strict,
    });
    defer allocator.free(sbpl);

    var child_env = try env_map.clone(allocator);
    defer child_env.deinit();
    for ([_][]const u8{ "TMPDIR", "TMP", "TEMP", "XDG_CACHE_HOME" }) |name| {
        try child_env.put(name, inventory_tmp);
    }
    var sandbox_argv: std.ArrayList([]const u8) = .empty;
    defer sandbox_argv.deinit(allocator);
    try sandbox_argv.appendSlice(allocator, &.{ "/usr/bin/sandbox-exec", "-p", sbpl });
    try sandbox_argv.appendSlice(allocator, inventory_argv);
    return std.process.run(allocator, io, .{
        .argv = sandbox_argv.items,
        .cwd = .{ .path = inventory_cwd },
        .environ_map = &child_env,
        .expand_arg0 = .no_expand,
        .stdout_limit = .limited(inventory_limit),
        .stderr_limit = .limited(stderr_limit),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
}

fn buildFromInventory(
    io: std.Io,
    allocator: std.mem.Allocator,
    original_argv: []const []const u8,
    workspace_root: []const u8,
    policy_path: []const u8,
    mode: []const u8,
    home: []const u8,
    env_map: *const std.process.Environ.Map,
    ryk_exe: []const u8,
    inventory: sandbox.mcp_runtime_grants.LaunchInventory,
) !Plan {
    if (!std.fs.path.isAbsolute(workspace_root) or !std.fs.path.isAbsolute(ryk_exe)) {
        return error.InvalidInventory;
    }
    if (!sandbox.apply.ensureWorkspaceSessionTmp(workspace_root)) return error.SessionTmpPrepareFailed;
    const workspace_tmp = try sandbox.apply.workspaceSessionTmpPath(allocator, workspace_root);
    defer allocator.free(workspace_tmp);
    const audit_root = sandbox.apply.createFreshAttachTmp(io, allocator, workspace_tmp) catch
        return error.SessionTmpPrepareFailed;
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, audit_root) catch {};
        allocator.free(audit_root);
    }
    const wrapper_parent = try prepareProtectedWrapperParent(io, allocator, workspace_root);
    defer allocator.free(wrapper_parent);
    const wrapper_root = sandbox.apply.createFreshAttachTmp(io, allocator, wrapper_parent) catch
        return error.SessionTmpPrepareFailed;
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, wrapper_root) catch {};
        allocator.free(wrapper_root);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &argv);
    if (original_argv.len == 0) return error.InvalidInventory;
    try appendCopy(allocator, &argv, original_argv[0]);
    const delimiter_index = findDelimiter(original_argv);
    for (original_argv[1..delimiter_index]) |arg| try appendCopy(allocator, &argv, arg);
    // Replace the complete table before adding protected entries. Per-server
    // overrides alone leave a race where a newly added config entry can launch
    // directly between inventory and the real Codex process.
    try appendCopy(allocator, &argv, "-c");
    try appendCopy(allocator, &argv, "mcp_servers={}");

    var exec_paths: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &exec_paths);
    var ro_paths: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &ro_paths);
    var disabled: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &disabled);

    // The generated wrappers exec the currently running Ryk binary. Grant the
    // exact resolved launch files as part of the protected plan so installs in
    // non-system locations do not fail after Seatbelt attaches.
    const ryk_exec = try sandbox.apply.collectLaunchExecPaths(io, allocator, ryk_exe, env_map);
    defer sandbox.apply.freeLaunchExecPaths(allocator, ryk_exec);
    if (ryk_exec.len == 0) return error.InvalidInventory;
    for (ryk_exec) |path| try appendUniqueCopy(allocator, &exec_paths, path);

    for (inventory.servers, 0..) |server, index| {
        var command_env_storage: ?std.process.Environ.Map = null;
        defer if (command_env_storage) |*map| map.deinit();
        const command_env = if (server.path_env) |path| blk: {
            var map = try env_map.clone(allocator);
            errdefer map.deinit();
            try map.put("PATH", path);
            command_env_storage = map;
            break :blk &command_env_storage.?;
        } else env_map;
        const launch_command = try commandForResolution(allocator, server);
        defer allocator.free(launch_command);
        const command_exec = try sandbox.apply.collectLaunchExecPaths(io, allocator, launch_command, command_env);
        defer sandbox.apply.freeLaunchExecPaths(allocator, command_exec);
        const command_ro = try sandbox.apply.collectLaunchInstallRoPaths(io, allocator, launch_command, command_env);
        defer sandbox.apply.freeLaunchInstallRoPaths(allocator, command_ro);

        var approved = command_exec.len > 0;
        for (command_exec) |path| {
            if (!sandbox.mcp_runtime_grants.isApprovedRuntimeCommandPath(path, home)) approved = false;
        }
        for (command_ro) |path| {
            if (!sandbox.mcp_runtime_grants.isApprovedRuntimeCommandPath(path, home)) approved = false;
        }

        const external_files = try hasExternalFiles(
            allocator,
            server,
            workspace_root,
            home,
            env_map,
        );
        const manifest_path = if (external_files)
            try snapshotMatchingManifest(io, allocator, workspace_root, wrapper_root, index, server)
        else
            null;
        defer if (manifest_path) |path| allocator.free(path);
        if (external_files and manifest_path == null) approved = false;

        if (!approved) {
            // The root table was replaced above, so absence is the only valid
            // fail-closed representation. Re-adding an enabled=false partial
            // table leaves Codex with no transport and fails config loading.
            try appendUniqueCopy(allocator, &disabled, server.name);
            continue;
        }

        for (command_exec) |path| try appendUniqueCopy(allocator, &exec_paths, path);
        for (command_ro) |path| try appendUniqueCopy(allocator, &ro_paths, path);
        if (manifest_path != null) {
            try appendUniqueCopy(allocator, &ro_paths, manifest_path.?);
            for (server.file_args) |path| try appendUniqueCopy(allocator, &ro_paths, path);
            if (server.cwd) |cwd| {
                if (!isPathWithin(cwd, workspace_root)) try appendUniqueCopy(allocator, &ro_paths, cwd);
            }
        }
        if (exec_paths.items.len + ro_paths.items.len > sandbox.mcp_runtime_grants.max_grant_paths) {
            return error.TooManyPaths;
        }

        const wrapper = try createProxyWrapper(
            io,
            allocator,
            wrapper_root,
            audit_root,
            index,
            ryk_exe,
            workspace_root,
            policy_path,
            mode,
            server,
            manifest_path,
            original_argv[0],
        );
        defer allocator.free(wrapper);
        try appendUniqueCopy(allocator, &exec_paths, wrapper);
        if (exec_paths.items.len + ro_paths.items.len > sandbox.mcp_runtime_grants.max_grant_paths) {
            return error.TooManyPaths;
        }
        try appendCommandOverride(allocator, &argv, server.name, wrapper);
    }

    for (inventory.unmediated_server_names) |name| {
        try appendUniqueCopy(allocator, &disabled, name);
    }
    for (original_argv[delimiter_index..]) |arg| try appendCopy(allocator, &argv, arg);

    const owned_argv = try argv.toOwnedSlice(allocator);
    errdefer freeOwnedStrings(allocator, owned_argv);
    const owned_exec_paths = try exec_paths.toOwnedSlice(allocator);
    errdefer freeOwnedStrings(allocator, owned_exec_paths);
    const owned_ro_paths = try ro_paths.toOwnedSlice(allocator);
    errdefer freeOwnedStrings(allocator, owned_ro_paths);
    const owned_disabled = try disabled.toOwnedSlice(allocator);
    errdefer freeOwnedStrings(allocator, owned_disabled);
    return .{
        .allocator = allocator,
        .argv = owned_argv,
        .exec_paths = owned_exec_paths,
        .ro_paths = owned_ro_paths,
        .disabled_server_names = owned_disabled,
        .wrapper_root = wrapper_root,
        .audit_root = audit_root,
    };
}

fn findDelimiter(argv: []const []const u8) usize {
    for (argv, 0..) |arg, index| if (std.mem.eql(u8, arg, "--")) return index;
    return argv.len;
}

fn appendInventorySelectors(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    original: []const []const u8,
    inventory_cwd: *?[]const u8,
) !void {
    var index: usize = 0;
    while (index < original.len) : (index += 1) {
        const arg = original[index];
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--cd")) {
            if (index + 1 >= original.len) return error.InvalidInventory;
            index += 1;
            inventory_cwd.* = original[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cd=")) {
            const cwd = arg["--cd=".len..];
            if (cwd.len == 0) return error.InvalidInventory;
            inventory_cwd.* = cwd;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-C") and arg.len > 2) {
            inventory_cwd.* = arg[2..];
            continue;
        }
        if ((std.mem.startsWith(u8, arg, "-c") or std.mem.startsWith(u8, arg, "-p")) and arg.len > 2) {
            try argv.append(allocator, arg);
            continue;
        }
        const takes_value = std.mem.eql(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "-p") or
            std.mem.eql(u8, arg, "--profile") or
            std.mem.eql(u8, arg, "--enable") or
            std.mem.eql(u8, arg, "--disable");
        if (takes_value) {
            if (index + 1 >= original.len) return error.InvalidInventory;
            try argv.append(allocator, arg);
            index += 1;
            try argv.append(allocator, original[index]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=") or
            std.mem.startsWith(u8, arg, "--profile=") or
            std.mem.startsWith(u8, arg, "--enable=") or
            std.mem.startsWith(u8, arg, "--disable="))
        {
            try argv.append(allocator, arg);
        }
    }
}

fn prepareProtectedWrapperParent(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]u8 {
    const control_root = try std.fs.path.join(allocator, &.{ workspace_root, ".orca" });
    defer allocator.free(control_root);
    try ensureDirectoryNoFollow(io, control_root);
    const wrapper_parent = try std.fs.path.join(allocator, &.{ control_root, "mcp-runtime" });
    errdefer allocator.free(wrapper_parent);
    try ensureDirectoryNoFollow(io, wrapper_parent);
    return wrapper_parent;
}

fn ensureDirectoryNoFollow(io: std.Io, path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.SessionTmpPrepareFailed,
    };
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch
        return error.SessionTmpPrepareFailed;
    dir.close(io);
}

fn commandForResolution(
    allocator: std.mem.Allocator,
    server: sandbox.mcp_runtime_grants.Server,
) error{OutOfMemory}![]u8 {
    if (std.fs.path.isAbsolute(server.command) or std.mem.indexOfScalar(u8, server.command, '/') == null) {
        return allocator.dupe(u8, server.command);
    }
    const cwd = server.cwd orelse return allocator.dupe(u8, server.command);
    return std.fs.path.join(allocator, &.{ cwd, server.command });
}

fn hasExternalFiles(
    allocator: std.mem.Allocator,
    server: sandbox.mcp_runtime_grants.Server,
    workspace_root: []const u8,
    home: []const u8,
    env_map: *const std.process.Environ.Map,
) error{OutOfMemory}!bool {
    const custom_codex_home = env_map.get("CODEX_HOME");
    const owned_default = if (custom_codex_home == null and home.len > 0 and std.fs.path.isAbsolute(home))
        try std.fs.path.join(allocator, &.{ home, ".codex" })
    else
        null;
    defer if (owned_default) |path| allocator.free(path);
    const codex_root = custom_codex_home orelse owned_default;
    if (server.cwd) |cwd| {
        if (!isPathWithin(cwd, workspace_root) and
            (codex_root == null or !isPathWithin(cwd, codex_root.?))) return true;
    }
    for (server.file_args) |path| {
        if (isPathWithin(path, workspace_root)) continue;
        if (codex_root) |root| if (isPathWithin(path, root)) continue;
        return true;
    }
    return false;
}

fn snapshotMatchingManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    wrapper_root: []const u8,
    server_index: usize,
    server: sandbox.mcp_runtime_grants.Server,
) !?[]u8 {
    const directory = try std.fs.path.join(allocator, &.{ workspace_root, ".orca", "mcp" });
    defer allocator.free(directory);
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    var matched_text: ?[]u8 = null;
    defer if (matched_text) |text| allocator.free(text);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or
            (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")))
        {
            continue;
        }
        count += 1;
        if (count > max_manifest_files) return error.TooManyPaths;
        const source_path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        defer allocator.free(source_path);
        var file = dir.openFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        defer file.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const text = reader.interface.allocRemaining(allocator, .limited(inventory_limit)) catch continue;
        defer allocator.free(text);
        var manifest = orca_mcp.manifests.parseFromSlice(allocator, text, source_path) catch continue;
        defer manifest.deinit(allocator);
        if (!std.mem.eql(u8, manifest.server.name, server.name) or
            !std.mem.eql(u8, manifest.server.command, server.command) or
            !equalStrings(manifest.server.args, server.args) or
            !equalOptionalStrings(manifest.server.cwd, server.cwd))
        {
            continue;
        }
        if (matched_text != null) return error.AmbiguousManifest;
        matched_text = try allocator.dupe(u8, text);
    }
    const exact_text = matched_text orelse return null;
    const snapshot_path = try std.fmt.allocPrint(
        allocator,
        "{s}/manifest-{d}.yaml",
        .{ wrapper_root, server_index },
    );
    errdefer allocator.free(snapshot_path);
    var snapshot = try std.Io.Dir.createFileAbsolute(io, snapshot_path, .{ .exclusive = true });
    defer snapshot.close(io);
    try snapshot.writeStreamingAll(io, exact_text);
    try snapshot.sync(io);
    return snapshot_path;
}

fn createProxyWrapper(
    io: std.Io,
    allocator: std.mem.Allocator,
    wrapper_root: []const u8,
    audit_root: []const u8,
    index: usize,
    ryk_exe: []const u8,
    workspace_root: []const u8,
    policy_path: []const u8,
    mode: []const u8,
    server: sandbox.mcp_runtime_grants.Server,
    manifest_path: ?[]const u8,
    codex_bin: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/mcp-{d}.sh", .{ wrapper_root, index });
    errdefer allocator.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll("#!/bin/sh\n");
    if (server.cwd) |cwd| {
        try writer.interface.writeAll("cd ");
        try writeShellQuoted(&writer.interface, cwd);
        try writer.interface.writeAll(" || exit 126\n");
    }
    try writer.interface.writeAll("exec ");
    try writeShellQuoted(&writer.interface, ryk_exe);
    try writer.interface.writeAll(" mcp proxy --name ");
    try writeShellQuoted(&writer.interface, server.name);
    try writer.interface.writeAll(" --policy ");
    try writeShellQuoted(&writer.interface, policy_path);
    try writer.interface.writeAll(" --mode ");
    try writeShellQuoted(&writer.interface, mode);
    try writer.interface.writeAll(" --workspace ");
    try writeShellQuoted(&writer.interface, workspace_root);
    if (!isPathWithin(audit_root, workspace_root) or audit_root.len <= workspace_root.len + 1) {
        return error.InvalidInventory;
    }
    const relative_audit_root = audit_root[workspace_root.len + 1 ..];
    const audit_dir_name = try std.fmt.allocPrint(
        allocator,
        "{s}/mcp-audit-{d}",
        .{ relative_audit_root, index },
    );
    defer allocator.free(audit_dir_name);
    try writer.interface.writeAll(" --audit-dir-name ");
    try writeShellQuoted(&writer.interface, audit_dir_name);
    if (manifest_path) |manifest| {
        try writer.interface.writeAll(" --manifest ");
        try writeShellQuoted(&writer.interface, manifest);
    }
    try writer.interface.writeAll(" --codex-inventory-bin ");
    try writeShellQuoted(&writer.interface, codex_bin);
    const server_fingerprint = sandbox.mcp_runtime_grants.fingerprint(server);
    try writer.interface.writeAll(" --codex-inventory-fingerprint ");
    try writeShellQuoted(&writer.interface, &server_fingerprint);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    if (builtin.os.tag != .windows) try file.setPermissions(io, .executable_file);
    return path;
}

fn appendCommandOverride(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    name: []const u8,
    command: []const u8,
) !void {
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    const command_json = try std.json.Stringify.valueAlloc(allocator, command, .{});
    defer allocator.free(command_json);
    try appendCopy(allocator, argv, "-c");
    const value = try std.fmt.allocPrint(
        allocator,
        "mcp_servers.{s}={{command={s},args=[]}}",
        .{ name_json, command_json },
    );
    argv.append(allocator, value) catch |err| {
        allocator.free(value);
        return err;
    };
}

fn writeShellQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\"'\"'");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

const isPathWithin = sandbox.profile.isPathWithin;

fn equalStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn equalOptionalStrings(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
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

fn appendUniqueCopy(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) error{OutOfMemory}!void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try appendCopy(allocator, list, value);
}

fn freeOwnedList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "protected plan proxies stdio without copying MCP argument secrets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    const secret_arg = "synthetic-secret-must-not-persist";
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "synthetic",
        .command = "/bin/sh",
        .args = &.{ "-c", secret_arg },
        .cwd = null,
        .env = &.{.{ .name = "MCP_SYNTHETIC", .value = "synthetic-env" }},
        .file_args = &.{},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{ "codex", "-c", "mcp_servers.synthetic.command=\"/bin/false\"", "--", "synthetic prompt" },
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);

    try std.testing.expectEqual(@as(usize, 0), plan.disabled_server_names.len);
    try std.testing.expect(pathPresent(plan.exec_paths, "/bin/echo"));
    var user_override_index: ?usize = null;
    var closed_inventory_index: ?usize = null;
    var protected_override_index: ?usize = null;
    var delimiter_index: ?usize = null;
    for (plan.argv, 0..) |arg, index| {
        if (std.mem.indexOf(u8, arg, "/bin/false") != null) user_override_index = index;
        if (std.mem.eql(u8, arg, "mcp_servers={}")) closed_inventory_index = index;
        if (std.mem.indexOf(u8, arg, plan.wrapper_root) != null) {
            protected_override_index = index;
            try std.testing.expect(std.mem.indexOf(u8, arg, "args=[]") != null);
        }
        if (std.mem.eql(u8, arg, "--")) delimiter_index = index;
    }
    try std.testing.expect(user_override_index.? < protected_override_index.?);
    try std.testing.expect(user_override_index.? < closed_inventory_index.?);
    try std.testing.expect(closed_inventory_index.? < protected_override_index.?);
    try std.testing.expect(protected_override_index.? < delimiter_index.?);
    try std.testing.expectEqualStrings("--", plan.argv[plan.argv.len - 2]);
    for (plan.argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, secret_arg) == null);
    const wrapper = try std.fs.path.join(allocator, &.{ plan.wrapper_root, "mcp-0.sh" });
    defer allocator.free(wrapper);
    try std.testing.expect(pathPresent(plan.exec_paths, wrapper));
    const control_root = try std.fs.path.join(allocator, &.{ workspace, ".orca" });
    defer allocator.free(control_root);
    try std.testing.expect(isPathWithin(plan.wrapper_root, control_root));
    try std.testing.expect(!isPathWithin(plan.wrapper_root, plan.audit_root));
    const text = try std.Io.Dir.cwd().readFileAlloc(io, wrapper, allocator, .limited(16 * 1024));
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "mcp proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--audit-dir-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, secret_arg) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--codex-inventory-bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--codex-inventory-fingerprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"$@\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "synthetic-env") == null);
}

test "proxy wrapper pins configured cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "server-cwd");
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const cwd = try tmp.dir.realPathFileAlloc(io, "server-cwd", allocator);
    defer allocator.free(cwd);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "cwd-server",
        .command = "/bin/sh",
        .args = &.{},
        .cwd = cwd,
        .file_args = &.{},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), plan.disabled_server_names.len);
    const wrapper = try std.fs.path.join(allocator, &.{ plan.wrapper_root, "mcp-0.sh" });
    defer allocator.free(wrapper);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, wrapper, allocator, .limited(16 * 1024));
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cd ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, cwd) != null);
}

test "inventory selectors preserve effective Codex config and apply cd as process cwd" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    var cwd: ?[]const u8 = null;
    try appendInventorySelectors(
        std.testing.allocator,
        &argv,
        &.{ "-pwork", "-cmcp_servers.x.enabled=true", "--enable=search", "-C/tmp/project", "--", "prompt" },
        &cwd,
    );
    try std.testing.expectEqualStrings("/tmp/project", cwd.?);
    const expected = [_][]const u8{ "-pwork", "-cmcp_servers.x.enabled=true", "--enable=search" };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "external MCP script is disabled without protected manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "workspace", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "external.mjs", .data = "// synthetic\n" });
    const workspace = try tmp.dir.realPathFileAlloc(io, "workspace", allocator);
    defer allocator.free(workspace);
    const script = try tmp.dir.realPathFileAlloc(io, "external.mjs", allocator);
    defer allocator.free(script);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "external",
        .command = "/bin/sh",
        .args = &.{script},
        .cwd = null,
        .file_args = &.{script},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), plan.disabled_server_names.len);
    try std.testing.expect(pathPresent(plan.exec_paths, "/bin/echo"));
    try std.testing.expect(!pathPresent(plan.exec_paths, script));
}

test "server PATH cannot replace an approved bare MCP command with a workspace executable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mcp-tool", .data = "#!/bin/sh\nexit 0\n" });
    var tool = try tmp.dir.openFile(io, "mcp-tool", .{});
    defer tool.close(io);
    try tool.setPermissions(io, .executable_file);
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "path-shadow",
        .command = "mcp-tool",
        .args = &.{},
        .cwd = null,
        .path_env = workspace,
        .file_args = &.{},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), plan.disabled_server_names.len);
}

test "unmediated remote MCP transport is explicitly disabled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var names = [_][]const u8{"remote"};
    var servers: [0]sandbox.mcp_runtime_grants.Server = .{};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &names },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), plan.disabled_server_names.len);
    var found_partial_entry = false;
    for (plan.argv) |arg| {
        if (std.mem.indexOf(u8, arg, "mcp_servers.\"remote\".enabled=false") != null) {
            found_partial_entry = true;
        }
    }
    try std.testing.expect(!found_partial_entry);
}

test "manifest discovery rejects a symlinked authority directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "workspace/.orca");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.createDirPath(io, "runtime");
    try tmp.dir.writeFile(io, .{
        .sub_path = "outside/server.yaml",
        .data = "version: 1\nserver:\n  name: external\n  transport: stdio\n  command: /bin/sh\n",
    });
    tmp.dir.symLink(io, "../../outside", "workspace/.orca/mcp", .{}) catch return error.SkipZigTest;
    const workspace = try tmp.dir.realPathFileAlloc(io, "workspace", allocator);
    defer allocator.free(workspace);
    const runtime = try tmp.dir.realPathFileAlloc(io, "runtime", allocator);
    defer allocator.free(runtime);
    const server: sandbox.mcp_runtime_grants.Server = .{
        .name = "external",
        .command = "/bin/sh",
        .args = &.{},
        .cwd = null,
        .file_args = &.{},
    };
    const snapshot = try snapshotMatchingManifest(io, allocator, workspace, runtime, 0, server);
    defer if (snapshot) |path| allocator.free(path);
    try std.testing.expect(snapshot == null);
}

test "protected manifest binds external script to exact literal grant" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".orca/mcp");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/server.mjs", .data = "// synthetic\n" });
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const script = try tmp.dir.realPathFileAlloc(io, "outside/server.mjs", allocator);
    defer allocator.free(script);
    const manifest = try std.fmt.allocPrint(
        allocator,
        "version: 1\nserver:\n  name: external\n  transport: stdio\n  command: /bin/sh\n  args:\n    - {s}\n",
        .{script},
    );
    defer allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = ".orca/mcp/external.yaml", .data = manifest });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "external",
        .command = "/bin/sh",
        .args = &.{script},
        .cwd = null,
        .file_args = &.{script},
    }};
    // Treat the script as external to the protected workspace while manifests
    // remain rooted in it by placing HOME/workspace checks elsewhere.
    const nested_workspace = try std.fs.path.join(allocator, &.{ workspace, "nested" });
    defer allocator.free(nested_workspace);
    try tmp.dir.createDir(io, "nested", .default_dir);
    // Copy the protected manifest tree into the effective workspace.
    try tmp.dir.createDirPath(io, "nested/.orca/mcp");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/.orca/mcp/external.yaml", .data = manifest });

    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        nested_workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), plan.disabled_server_names.len);
    try std.testing.expect(!pathPresent(plan.exec_paths, script));
    try std.testing.expect(pathPresent(plan.ro_paths, script));

    try tmp.dir.writeFile(io, .{ .sub_path = "nested/.orca/mcp/duplicate.yaml", .data = manifest });
    try std.testing.expectError(
        error.AmbiguousManifest,
        buildFromInventory(
            io,
            allocator,
            &.{"codex"},
            nested_workspace,
            "/tmp/synthetic-policy.yaml",
            "strict",
            "/Users/synthetic",
            &env_map,
            "/bin/echo",
            .{ .servers = &servers, .unmediated_server_names = &.{} },
        ),
    );
}

test "protected manifest cwd cannot authorize the same relative arg from another directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "workspace/.orca/mcp");
    try tmp.dir.createDirPath(io, "server-a");
    try tmp.dir.createDirPath(io, "server-b");
    try tmp.dir.writeFile(io, .{ .sub_path = "server-a/server.mjs", .data = "// a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "server-b/server.mjs", .data = "// b\n" });
    const workspace = try tmp.dir.realPathFileAlloc(io, "workspace", allocator);
    defer allocator.free(workspace);
    const cwd_a = try tmp.dir.realPathFileAlloc(io, "server-a", allocator);
    defer allocator.free(cwd_a);
    const cwd_b = try tmp.dir.realPathFileAlloc(io, "server-b", allocator);
    defer allocator.free(cwd_b);
    const script_b = try tmp.dir.realPathFileAlloc(io, "server-b/server.mjs", allocator);
    defer allocator.free(script_b);
    const manifest = try std.fmt.allocPrint(
        allocator,
        "version: 1\nserver:\n  name: external\n  transport: stdio\n  command: /bin/sh\n  args:\n    - server.mjs\n  cwd: {s}\n",
        .{cwd_a},
    );
    defer allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace/.orca/mcp/external.yaml", .data = manifest });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "external",
        .command = "/bin/sh",
        .args = &.{"server.mjs"},
        .cwd = cwd_b,
        .file_args = &.{script_b},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 1), plan.disabled_server_names.len);
    try std.testing.expect(!pathPresent(plan.exec_paths, script_b));
}

test "protected manifest grants exact external cwd read-only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/.orca/mcp");
    try tmp.dir.createDirPath(io, "external-cwd");
    const workspace = try tmp.dir.realPathFileAlloc(io, "project", allocator);
    defer allocator.free(workspace);
    const external_cwd = try tmp.dir.realPathFileAlloc(io, "external-cwd", allocator);
    defer allocator.free(external_cwd);
    const manifest = try std.fmt.allocPrint(
        allocator,
        "version: 1\nserver:\n  name: external-cwd\n  transport: stdio\n  command: /bin/sh\n  cwd: {s}\n",
        .{external_cwd},
    );
    defer allocator.free(manifest);
    const manifest_path = try std.fs.path.join(allocator, &.{ workspace, ".orca", "mcp", "external.yaml" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers = [_]sandbox.mcp_runtime_grants.Server{.{
        .name = "external-cwd",
        .command = "/bin/sh",
        .args = &.{},
        .cwd = external_cwd,
        .file_args = &.{},
    }};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    defer plan.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), plan.disabled_server_names.len);
    try std.testing.expect(pathPresent(plan.ro_paths, external_cwd));
}

test "plan cleanup removes child-writable MCP audit output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/synthetic");
    try env_map.put("PATH", "/usr/bin:/bin");
    var servers: [0]sandbox.mcp_runtime_grants.Server = .{};
    var plan = try buildFromInventory(
        io,
        allocator,
        &.{"codex"},
        workspace,
        "/tmp/synthetic-policy.yaml",
        "strict",
        "/Users/synthetic",
        &env_map,
        "/bin/echo",
        .{ .servers = &servers, .unmediated_server_names = &.{} },
    );
    const audit_root = try allocator.dupe(u8, plan.audit_root);
    defer allocator.free(audit_root);
    try std.Io.Dir.cwd().access(io, audit_root, .{});
    plan.deinit(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, audit_root, .{}));
}

fn pathPresent(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}
