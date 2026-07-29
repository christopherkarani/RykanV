//! Single-threaded backing-store and request dispatcher for the Linux secret-boundary
//! FUSE workspace view.
//!
//! Namespace creation, mounting, bootstrap IPC, and process supervision belong to
//! the caller. This module owns only pinned backing descriptors, bounded daemon
//! state, name policy, and FUSE request execution.

const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const protocol = @import("linux_fuse_protocol.zig");
const uapi = @import("linux_fuse_uapi.zig");

const errno_notty: u16 = 25;
const errno_mfile: u16 = 24;
const errno_range: u16 = 34;
const errno_proto: u16 = 71;
const errno_opnotsupp: u16 = 95;

const o_access_mode: u32 = 0x3;
const o_readonly: u32 = 0;
const o_readwrite: u32 = 2;
const o_create: u32 = 0x40;
const o_exclusive: u32 = 0x80;
const o_truncate: u32 = 0x200;
const o_directory: u32 = 0x10000;
const o_nofollow: u32 = 0x20000;
const o_cloexec: u32 = 0x80000;
const o_path: u32 = 0x200000;
const o_tmpfile_bit: u32 = 0x400000;

const mode_type_mask: u32 = 0o170000;
const mode_fifo: u32 = 0o010000;
const mode_char: u32 = 0o020000;
const mode_directory: u32 = 0o040000;
const mode_block: u32 = 0o060000;
const mode_regular: u32 = 0o100000;
const mode_symlink: u32 = 0o120000;

const rename_noreplace: u32 = 1;
const rename_exchange: u32 = 2;

const resolve_no_xdev: u64 = 0x01;
const resolve_no_magiclinks: u64 = 0x02;
const resolve_beneath: u64 = 0x08;
const safe_resolve: u64 = resolve_no_xdev | resolve_no_magiclinks | resolve_beneath;

const setattr_mode: u32 = 1 << 0;
const setattr_uid: u32 = 1 << 1;
const setattr_gid: u32 = 1 << 2;
const setattr_size: u32 = 1 << 3;
const setattr_atime: u32 = 1 << 4;
const setattr_mtime: u32 = 1 << 5;
const setattr_fh: u32 = 1 << 6;
const setattr_atime_now: u32 = 1 << 7;
const setattr_mtime_now: u32 = 1 << 8;
const setattr_lockowner: u32 = 1 << 9;
const setattr_ctime: u32 = 1 << 10;
const setattr_kill_suidgid: u32 = 1 << 11;
const setattr_supported = setattr_mode |
    setattr_uid |
    setattr_gid |
    setattr_size |
    setattr_atime |
    setattr_mtime |
    setattr_fh |
    setattr_atime_now |
    setattr_mtime_now |
    setattr_lockowner |
    setattr_ctime |
    setattr_kill_suidgid;

const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

const LinuxOpenError = error{
    AccessDenied,
    NotFound,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
    SymlinkLoop,
    CrossDevice,
    Invalid,
    TooManyFiles,
    Unsupported,
    Io,
};

const FdResult = union(enum) {
    fd: i32,
    errno: u16,
};

const IoResult = struct {
    count: usize = 0,
    errno: ?u16 = null,
};

const LinuxDirent = struct {
    inode: u64,
    next_offset: i64,
    record_len: usize,
    kind: u8,
    name: []const u8,
};

const LinuxStatfs = extern struct {
    kind: i64,
    block_size: i64,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    fsid: [2]i32,
    name_len: i64,
    fragment_size: i64,
    flags: i64,
    spare: [4]i64,
};

const StatfsResult = struct {
    stat: uapi.Kstatfs = std.mem.zeroes(uapi.Kstatfs),
    errno: ?u16 = null,
};

pub const NameDecision = enum {
    allowed,
    hidden,
    forbidden,
    invalid,
};

pub fn decideLookupName(name: []const u8) NameDecision {
    if (!isValidComponent(name)) return .invalid;
    if (profile.isWorkspaceSecretPath(name)) return .hidden;
    return .allowed;
}

pub fn decideMutationName(name: []const u8) NameDecision {
    if (!isValidComponent(name)) return .invalid;
    if (profile.isWorkspaceSecretPath(name)) return .forbidden;
    return .allowed;
}

fn isValidComponent(name: []const u8) bool {
    if (name.len == 0 or name.len > uapi.max_name_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    return std.mem.indexOfScalar(u8, name, 0) == null;
}

pub const XattrDecision = enum {
    allowed,
    forbidden,
    invalid,
};

pub fn decideXattrMutation(name: []const u8) XattrDecision {
    if (name.len == 0 or
        name.len > uapi.max_name_len or
        std.mem.indexOfScalar(u8, name, 0) != null)
    {
        return .invalid;
    }
    if (std.mem.startsWith(u8, name, "user.")) return .allowed;
    return .forbidden;
}

pub const UnsupportedDecision = enum {
    supported,
    unknown,
    not_supported,
    not_tty,
};

pub fn unsupportedDecision(opcode: ?uapi.Opcode) UnsupportedDecision {
    const op = opcode orelse return .unknown;
    return switch (op) {
        .ioctl => .not_tty,
        .poll,
        .bmap,
        .setupmapping,
        .removemapping,
        .getlk,
        .setlk,
        .setlkw,
        => .not_supported,
        else => .supported,
    };
}

pub const Limits = struct {
    max_nodes: usize = 262_144,
    max_file_handles: usize = 65_536,
    max_dir_handles: usize = 8_192,
    max_tainted_identities: usize = 262_144,
    max_request_bytes: usize = 132 * 1024,
    max_scan_entries: usize = 1_000_000,
    max_scan_depth: usize = 256,
};

pub const Identity = struct {
    device: u64,
    inode: u64,
};

pub const NodeKind = enum {
    file,
    directory,
    symlink,
    other,
};

pub const HandleKind = enum {
    file,
    directory,
};

const NodeRecord = struct {
    id: u64,
    identity: Identity,
    fd: i32,
    kind: NodeKind,
    lookup_count: u64,
    open_count: u32,
    active: bool,
};

const HandleRecord = struct {
    id: u64,
    node_id: u64,
    fd: i32,
    kind: HandleKind,
    active: bool,
};

pub const ReleasedHandle = struct {
    fd: i32,
    unpinned_node_fd: ?i32,
};

/// Bounded bookkeeping with no syscall side effects. `DaemonState` is responsible
/// for closing every descriptor returned by a removal and all active descriptors
/// at shutdown.
pub const StateTables = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    nodes: std.ArrayList(NodeRecord),
    handles: std.ArrayList(HandleRecord),
    tainted: std.ArrayList(Identity),
    safe_hardlinks: std.ArrayList(Identity),
    next_node_id: u64,
    next_handle_id: u64,
    active_nodes: usize,
    active_file_handles: usize,
    active_dir_handles: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
        root_identity: Identity,
        root_fd: i32,
    ) !StateTables {
        if (limits.max_nodes == 0 or
            limits.max_file_handles == 0 or
            limits.max_dir_handles == 0 or
            limits.max_tainted_identities == 0 or
            limits.max_scan_entries == 0 or
            limits.max_scan_depth == 0 or
            limits.max_request_bytes < uapi.min_read_buffer)
        {
            return error.InvalidLimits;
        }

        var nodes: std.ArrayList(NodeRecord) = .empty;
        errdefer nodes.deinit(allocator);
        try nodes.append(allocator, .{
            .id = uapi.root_id,
            .identity = root_identity,
            .fd = root_fd,
            .kind = .directory,
            .lookup_count = 1,
            .open_count = 0,
            .active = true,
        });

        return .{
            .allocator = allocator,
            .limits = limits,
            .nodes = nodes,
            .handles = .empty,
            .tainted = .empty,
            .safe_hardlinks = .empty,
            .next_node_id = uapi.root_id + 1,
            .next_handle_id = 1,
            .active_nodes = 1,
            .active_file_handles = 0,
            .active_dir_handles = 0,
        };
    }

    pub fn deinit(self: *StateTables) void {
        self.nodes.deinit(self.allocator);
        self.handles.deinit(self.allocator);
        self.tainted.deinit(self.allocator);
        self.safe_hardlinks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn node(self: *StateTables, node_id: u64) ?*NodeRecord {
        for (self.nodes.items) |*record| {
            if (record.active and record.id == node_id) return record;
        }
        return null;
    }

    pub fn findNodeByIdentity(self: *StateTables, identity: Identity) ?*NodeRecord {
        for (self.nodes.items) |*record| {
            if (record.active and identitiesEqual(record.identity, identity)) return record;
        }
        return null;
    }

    pub fn retainNode(self: *StateTables, node_id: u64) !u64 {
        const record = self.node(node_id) orelse return error.UnknownNode;
        record.lookup_count = std.math.add(u64, record.lookup_count, 1) catch
            return error.LookupCountOverflow;
        return record.id;
    }

    pub fn acquireNode(
        self: *StateTables,
        identity: Identity,
        fd: i32,
        kind: NodeKind,
    ) !u64 {
        if (self.isTainted(identity)) return error.TaintedIdentity;
        if (self.findNodeByIdentity(identity) != null) return error.IdentityExists;
        if (self.active_nodes >= self.limits.max_nodes) return error.NodeCapacity;
        if (self.next_node_id == 0) return error.NodeIdExhausted;

        const node_id = self.next_node_id;
        self.next_node_id +%= 1;
        const record: NodeRecord = .{
            .id = node_id,
            .identity = identity,
            .fd = fd,
            .kind = kind,
            .lookup_count = 1,
            .open_count = 0,
            .active = true,
        };
        for (self.nodes.items) |*slot| {
            if (!slot.active) {
                slot.* = record;
                self.active_nodes += 1;
                return node_id;
            }
        }
        try self.nodes.append(self.allocator, record);
        self.active_nodes += 1;
        return node_id;
    }

    pub fn forgetNode(self: *StateTables, node_id: u64, count: u64) !?i32 {
        if (node_id == uapi.root_id) return null;
        const record = self.node(node_id) orelse return null;
        record.lookup_count -|= count;
        return self.maybeUnpinNode(record);
    }

    pub fn addHandle(
        self: *StateTables,
        node_id: u64,
        fd: i32,
        kind: HandleKind,
    ) !u64 {
        const node_record = self.node(node_id) orelse return error.UnknownNode;
        if (kind == .file and self.active_file_handles >= self.limits.max_file_handles) {
            return error.FileHandleCapacity;
        }
        if (kind == .directory and self.active_dir_handles >= self.limits.max_dir_handles) {
            return error.DirHandleCapacity;
        }
        if (self.next_handle_id == 0) return error.HandleIdExhausted;
        node_record.open_count = std.math.add(u32, node_record.open_count, 1) catch
            return error.OpenCountOverflow;

        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;
        const record: HandleRecord = .{
            .id = handle_id,
            .node_id = node_id,
            .fd = fd,
            .kind = kind,
            .active = true,
        };
        for (self.handles.items) |*slot| {
            if (!slot.active) {
                slot.* = record;
                self.incrementHandleCount(kind);
                return handle_id;
            }
        }
        self.handles.append(self.allocator, record) catch |err| {
            node_record.open_count -= 1;
            return err;
        };
        self.incrementHandleCount(kind);
        return handle_id;
    }

    pub fn handle(self: *StateTables, handle_id: u64, kind: HandleKind) ?*HandleRecord {
        for (self.handles.items) |*record| {
            if (record.active and record.id == handle_id and record.kind == kind) return record;
        }
        return null;
    }

    pub fn releaseHandle(
        self: *StateTables,
        handle_id: u64,
        kind: HandleKind,
    ) !ReleasedHandle {
        const record = self.handle(handle_id, kind) orelse return error.UnknownHandle;
        const fd = record.fd;
        const node_id = record.node_id;
        const node_record = self.node(node_id) orelse return error.UnknownNode;
        if (node_record.open_count == 0) return error.OpenCountUnderflow;

        record.active = false;
        self.decrementHandleCount(kind);
        node_record.open_count -= 1;
        return .{
            .fd = fd,
            .unpinned_node_fd = self.maybeUnpinNode(node_record),
        };
    }

    pub fn markTainted(self: *StateTables, identity: Identity) !void {
        if (self.isTainted(identity)) return;
        if (self.tainted.items.len >= self.limits.max_tainted_identities) {
            return error.TaintedCapacity;
        }
        try self.tainted.append(self.allocator, identity);
    }

    pub fn isTainted(self: *const StateTables, identity: Identity) bool {
        for (self.tainted.items) |candidate| {
            if (identitiesEqual(candidate, identity)) return true;
        }
        return false;
    }

    pub fn markSafeHardlink(self: *StateTables, identity: Identity) !void {
        if (self.isSafeHardlink(identity)) return;
        if (self.safe_hardlinks.items.len >= self.limits.max_tainted_identities) {
            return error.TaintedCapacity;
        }
        try self.safe_hardlinks.append(self.allocator, identity);
    }

    pub fn isSafeHardlink(self: *const StateTables, identity: Identity) bool {
        for (self.safe_hardlinks.items) |candidate| {
            if (identitiesEqual(candidate, identity)) return true;
        }
        return false;
    }

    fn maybeUnpinNode(self: *StateTables, record: *NodeRecord) ?i32 {
        if (record.id == uapi.root_id or record.lookup_count != 0 or record.open_count != 0) {
            return null;
        }
        record.active = false;
        self.active_nodes -= 1;
        return record.fd;
    }

    fn incrementHandleCount(self: *StateTables, kind: HandleKind) void {
        switch (kind) {
            .file => self.active_file_handles += 1,
            .directory => self.active_dir_handles += 1,
        }
    }

    fn decrementHandleCount(self: *StateTables, kind: HandleKind) void {
        switch (kind) {
            .file => self.active_file_handles -= 1,
            .directory => self.active_dir_handles -= 1,
        }
    }
};

fn identitiesEqual(a: Identity, b: Identity) bool {
    return a.device == b.device and a.inode == b.inode;
}

/// Returns an errno when a request can be rejected without touching backing
/// storage. Malformed wire fields fail closed with `EINVAL`.
pub fn preflightErrno(request: protocol.Request) !?u16 {
    switch (unsupportedDecision(request.opcode)) {
        .unknown => return uapi.errno_nosys,
        .not_tty => return errno_notty,
        .not_supported => return errno_opnotsupp,
        .supported => {},
    }

    const opcode = request.opcode.?;
    return switch (opcode) {
        .lookup => lookupNameErrno(parseSingleName(request.body, 0)),
        .unlink, .rmdir => mutationNameErrno(parseSingleName(request.body, 0)),
        .mkdir => mutationNameErrno(parseSingleName(request.body, @sizeOf(uapi.MkdirIn))),
        .mknod => mutationNameErrno(parseSingleName(request.body, @sizeOf(uapi.MknodIn))),
        .create => mutationNameErrno(parseSingleName(request.body, @sizeOf(uapi.CreateIn))),
        .link => mutationNameErrno(parseSingleName(request.body, @sizeOf(uapi.LinkIn))),
        .symlink => mutationNameErrno(if (parseSymlinkFields(request.body)) |fields| fields.name else null),
        .rename => mutationPairErrno(parseNamePair(request.body, @sizeOf(uapi.RenameIn)), true),
        .rename2 => mutationPairErrno(parseNamePair(request.body, @sizeOf(uapi.Rename2In)), true),
        .setxattr => xattrMutationErrno(parseXattrName(request.body, @sizeOf(uapi.SetxattrIn))),
        .removexattr => xattrMutationErrno(parseSingleName(request.body, 0)),
        else => null,
    };
}

fn parseSingleName(body: []const u8, prefix_len: usize) ?[]const u8 {
    return protocol.singleName(body, prefix_len) catch null;
}

fn parseNamePair(body: []const u8, prefix_len: usize) ?protocol.NamePair {
    return protocol.twoNames(body, prefix_len) catch null;
}

const SymlinkFields = struct {
    target: []const u8,
    name: []const u8,
};

fn parseSymlinkFields(body: []const u8) ?SymlinkFields {
    const target = protocol.nulTerminated(body, 0) catch return null;
    if (target.value.len == 0 or target.value.len >= std.os.linux.PATH_MAX) return null;
    const name = protocol.nulTerminated(body, target.next_offset) catch return null;
    if (name.next_offset != body.len or !isValidComponent(name.value)) return null;
    return .{ .target = target.value, .name = name.value };
}

fn parseXattrName(body: []const u8, prefix_len: usize) ?[]const u8 {
    const field = protocol.nulTerminated(body, prefix_len) catch return null;
    if (!isValidXattrName(field.value)) return null;
    return field.value;
}

fn lookupNameErrno(name: ?[]const u8) ?u16 {
    const value = name orelse return uapi.errno_inval;
    return switch (decideLookupName(value)) {
        .allowed => null,
        .hidden => uapi.errno_noent,
        .forbidden => uapi.errno_perm,
        .invalid => uapi.errno_inval,
    };
}

fn mutationNameErrno(name: ?[]const u8) ?u16 {
    const value = name orelse return uapi.errno_inval;
    return switch (decideMutationName(value)) {
        .allowed => null,
        .hidden, .forbidden => uapi.errno_perm,
        .invalid => uapi.errno_inval,
    };
}

fn mutationPairErrno(pair: ?protocol.NamePair, check_first: bool) ?u16 {
    const names = pair orelse return uapi.errno_inval;
    if (check_first) {
        if (mutationNameErrno(names.first)) |errno| return errno;
    }
    return mutationNameErrno(names.second);
}

fn xattrMutationErrno(name: ?[]const u8) ?u16 {
    const value = name orelse return uapi.errno_inval;
    return switch (decideXattrMutation(value)) {
        .allowed => null,
        .forbidden => uapi.errno_perm,
        .invalid => uapi.errno_inval,
    };
}

fn isValidXattrName(name: []const u8) bool {
    return name.len != 0 and
        name.len <= uapi.max_name_len and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

pub const DispatchResult = union(enum) {
    reply: []const u8,
    no_reply,
    stop,
};

pub const DaemonState = struct {
    tables: StateTables,
    fuse_fd: i32,
    initialized: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        fuse_fd: i32,
        backing_root_fd: i32,
        limits: Limits,
    ) !DaemonState {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        if (fuse_fd < 0 or backing_root_fd < 0) return error.InvalidDescriptor;

        const root_stat = linuxStatFd(backing_root_fd) orelse return error.InvalidBackingRoot;
        if (nodeKind(root_stat.mode) != .directory) return error.InvalidBackingRoot;
        return .{
            .tables = try StateTables.init(
                allocator,
                limits,
                identityFromStat(root_stat),
                backing_root_fd,
            ),
            .fuse_fd = fuse_fd,
            .initialized = false,
        };
    }

    pub fn deinit(self: *DaemonState) void {
        if (builtin.os.tag == .linux) {
            for (self.tables.handles.items) |record| {
                if (record.active) linuxClose(record.fd);
            }
            for (self.tables.nodes.items) |record| {
                if (record.active) linuxClose(record.fd);
            }
            linuxClose(self.fuse_fd);
        }
        self.tables.deinit();
        self.* = undefined;
    }

    pub fn dispatch(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError!DispatchResult {
        if (builtin.os.tag == .linux and
            !self.initialized and
            request.opcode != .init and
            request.opcode != .destroy)
        {
            return .{ .reply = try protocol.encodeError(output, request.header.unique, errno_proto) };
        }
        if (try preflightErrno(request)) |errno| {
            return .{ .reply = try protocol.encodeError(output, request.header.unique, errno) };
        }
        if (builtin.os.tag != .linux) {
            return .{ .reply = try protocol.encodeError(output, request.header.unique, uapi.errno_nosys) };
        }
        return self.dispatchLinux(request, output);
    }

    fn dispatchLinux(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError!DispatchResult {
        const opcode = request.opcode.?;
        return switch (opcode) {
            .init => .{ .reply = try self.handleInit(request, output) },
            .destroy => .stop,
            .forget => self.handleForget(request),
            .batch_forget => self.handleBatchForget(request),
            .interrupt => self.handleInterrupt(request),
            .lookup => .{ .reply = try self.handleLookup(request, output) },
            .getattr => .{ .reply = try self.handleGetattr(request, output) },
            .setattr => .{ .reply = try self.handleSetattr(request, output) },
            .access => .{ .reply = try self.handleAccess(request, output) },
            .open => .{ .reply = try self.handleOpen(request, output) },
            .create => .{ .reply = try self.handleCreate(request, output) },
            .read => .{ .reply = try self.handleRead(request, output) },
            .write => .{ .reply = try self.handleWrite(request, output) },
            .flush => .{ .reply = try self.handleFlush(request, output) },
            .release => .{ .reply = try self.handleRelease(request, output, .file) },
            .fsync => .{ .reply = try self.handleFsync(request, output, .file) },
            .opendir => .{ .reply = try self.handleOpendir(request, output) },
            .readdir => .{ .reply = try self.handleReaddir(request, output) },
            .releasedir => .{ .reply = try self.handleRelease(request, output, .directory) },
            .fsyncdir => .{ .reply = try self.handleFsync(request, output, .directory) },
            .mkdir, .mknod => .{ .reply = try self.handleCreateNode(request, output) },
            .unlink, .rmdir => .{ .reply = try self.handleUnlink(request, output) },
            .rename, .rename2 => .{ .reply = try self.handleRename(request, output) },
            .link => .{ .reply = try self.handleLink(request, output) },
            .symlink => .{ .reply = try self.handleSymlink(request, output) },
            .readlink => .{ .reply = try self.handleReadlink(request, output) },
            .statfs => .{ .reply = try self.handleStatfs(request, output) },
            .setxattr, .getxattr, .listxattr, .removexattr => .{
                .reply = try self.handleXattr(request, output),
            },
            .fallocate, .lseek, .copy_file_range, .readdirplus => .{
                .reply = try replyError(output, request, errno_opnotsupp),
            },
            else => .{ .reply = try replyError(output, request, uapi.errno_nosys) },
        };
    }

    fn handleInit(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        if (self.initialized) return replyError(output, request, uapi.errno_inval);
        const input = request.bodyAs(uapi.InitIn) catch
            return replyError(output, request, uapi.errno_inval);
        // Linux extended fuse_init_in from 16 to 64 bytes when flags2 landed.
        // We negotiate only the original flag word and protocol minor <= 31.
        if (request.body.len != @sizeOf(uapi.InitIn) and request.body.len != 64) {
            return replyError(output, request, uapi.errno_inval);
        }
        const max_io: u32 = @intCast(@min(
            self.tables.limits.max_request_bytes - 4096,
            128 * 1024,
        ));
        const negotiation = protocol.negotiateInit(input, .{
            .max_readahead = max_io,
            .max_write = max_io,
            .max_background = 32,
            .congestion_threshold = 24,
            .max_pages = 32,
        }) catch return replyError(output, request, errno_proto);

        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        switch (negotiation) {
            .retry_with_major => |version| {
                try writer.appendValue(uapi.InitVersionOut{
                    .major = version.major,
                    .minor = version.minor,
                });
            },
            .ready => |negotiated| {
                var ready = negotiated;
                ready.flags &= ~uapi.init_parallel_dirops;
                try writer.appendValue(ready);
                self.initialized = true;
            },
        }
        return writer.finish();
    }

    fn handleForget(self: *DaemonState, request: protocol.Request) DispatchResult {
        const input = request.bodyAs(uapi.ForgetIn) catch return .stop;
        if (request.body.len != @sizeOf(uapi.ForgetIn)) return .stop;
        if (self.tables.forgetNode(request.header.nodeid, input.nlookup) catch null) |fd| {
            linuxClose(fd);
        }
        return .no_reply;
    }

    fn handleBatchForget(self: *DaemonState, request: protocol.Request) DispatchResult {
        const header = request.bodyAs(uapi.BatchForgetIn) catch return .stop;
        const count: usize = header.count;
        const entries_len = std.math.mul(usize, count, @sizeOf(uapi.ForgetOne)) catch return .stop;
        const expected = std.math.add(usize, @sizeOf(uapi.BatchForgetIn), entries_len) catch return .stop;
        if (request.body.len != expected) return .stop;

        var offset: usize = @sizeOf(uapi.BatchForgetIn);
        while (offset < request.body.len) : (offset += @sizeOf(uapi.ForgetOne)) {
            const entry = decodeNative(
                uapi.ForgetOne,
                request.body[offset .. offset + @sizeOf(uapi.ForgetOne)],
            );
            if (self.tables.forgetNode(entry.nodeid, entry.nlookup) catch null) |fd| {
                linuxClose(fd);
            }
        }
        return .no_reply;
    }

    fn handleInterrupt(self: *DaemonState, request: protocol.Request) DispatchResult {
        _ = self;
        if (request.body.len != @sizeOf(uapi.InterruptIn)) return .stop;
        _ = request.bodyAs(uapi.InterruptIn) catch return .stop;
        return .no_reply;
    }

    fn handleLookup(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const name = protocol.singleName(request.body, 0) catch
            return replyError(output, request, uapi.errno_inval);
        const parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (parent.kind != .directory) return replyError(output, request, uapi.errno_notdir);

        const child_fd = linuxOpenPinnedChild(parent.fd, name) catch |err| {
            return replyError(output, request, linuxErrorErrno(err));
        };
        var keep_child_fd = false;
        defer if (!keep_child_fd) linuxClose(child_fd);

        const stat = linuxStatFd(child_fd) orelse
            return replyError(output, request, uapi.errno_io);
        const identity = identityFromStat(stat);
        if (self.shouldHideIdentity(identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }

        const node_id = if (self.tables.findNodeByIdentity(identity)) |existing|
            self.tables.retainNode(existing.id) catch
                return replyError(output, request, uapi.errno_io)
        else blk: {
            const id = self.tables.acquireNode(identity, child_fd, nodeKind(stat.mode)) catch |err| {
                return replyError(output, request, tableErrorErrno(err));
            };
            keep_child_fd = true;
            break :blk id;
        };
        return encodeEntry(output, request.header.unique, node_id, stat);
    }

    fn handleGetattr(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        const stat = linuxStatFd(node.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (self.shouldHideIdentity(node.identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        try writer.appendValue(uapi.AttrOut{
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = fuseAttr(stat, node.id),
        });
        return writer.finish();
    }

    fn shouldHideIdentity(
        self: *DaemonState,
        identity: Identity,
        stat: std.os.linux.Statx,
    ) !bool {
        if (self.tables.isTainted(identity)) return true;
        if (nodeKind(stat.mode) == .file and
            stat.nlink > 1 and
            !self.tables.isSafeHardlink(identity))
        {
            try self.tables.markTainted(identity);
            return true;
        }
        return false;
    }

    fn existingChildTainted(self: *DaemonState, parent_fd: i32, name: []const u8) !bool {
        const child_fd = linuxOpenPinnedChild(parent_fd, name) catch |err| switch (err) {
            error.NotFound => return false,
            else => return err,
        };
        defer linuxClose(child_fd);
        const stat = linuxStatFd(child_fd) orelse return error.Io;
        return self.shouldHideIdentity(identityFromStat(stat), stat);
    }

    fn handleSetattr(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.SetattrIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.SetattrIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind != .file and node.kind != .directory) {
            return replyError(output, request, uapi.errno_access);
        }
        const stat = linuxStatFd(node.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (!identitiesEqual(node.identity, identityFromStat(stat))) {
            return replyError(output, request, uapi.errno_io);
        }
        if (self.shouldHideIdentity(node.identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        if (linuxApplySetattr(node.fd, input)) |errno| {
            return replyError(output, request, errno);
        }
        return self.handleGetattr(request, output);
    }

    fn handleAccess(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.AccessIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.AccessIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        if (input.mask & ~@as(u32, 7) != 0) return replyError(output, request, uapi.errno_inval);
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind != .file and node.kind != .directory) {
            return replyError(output, request, uapi.errno_access);
        }
        const stat = linuxStatFd(node.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (!identitiesEqual(node.identity, identityFromStat(stat))) {
            return replyError(output, request, uapi.errno_io);
        }
        if (self.shouldHideIdentity(node.identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        if (linuxAccessFd(node.fd, node.identity, node.kind, input.mask)) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleOpen(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.OpenIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.OpenIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind == .directory) return replyError(output, request, uapi.errno_isdir);
        if (node.kind != .file) return replyError(output, request, uapi.errno_access);
        const stat = linuxStatFd(node.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (self.shouldHideIdentity(node.identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }

        const data_fd = switch (linuxOpenDataNode(node.fd, input.flags, node.identity)) {
            .fd => |fd| fd,
            .errno => |errno| return replyError(output, request, errno),
        };
        var keep_fd = false;
        defer if (!keep_fd) linuxClose(data_fd);
        const handle_id = self.tables.addHandle(node.id, data_fd, .file) catch |err| {
            return replyError(output, request, tableErrorErrno(err));
        };
        keep_fd = true;
        return encodeOpen(output, request.header.unique, handle_id);
    }

    fn handleCreate(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.CreateIn) catch
            return replyError(output, request, uapi.errno_inval);
        const name = protocol.singleName(request.body, @sizeOf(uapi.CreateIn)) catch
            return replyError(output, request, uapi.errno_inval);
        const parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (parent.kind != .directory) return replyError(output, request, uapi.errno_notdir);

        var pinned_fd: i32 = undefined;
        var data_fd: i32 = undefined;
        const existing_fd = linuxOpenPinnedChild(parent.fd, name) catch |err| switch (err) {
            error.NotFound => null,
            else => return replyError(output, request, linuxErrorErrno(err)),
        };
        if (existing_fd) |fd| {
            pinned_fd = fd;
            const existing_stat = linuxStatFd(pinned_fd) orelse {
                linuxClose(pinned_fd);
                return replyError(output, request, uapi.errno_io);
            };
            const existing_identity = identityFromStat(existing_stat);
            if (self.shouldHideIdentity(existing_identity, existing_stat) catch {
                linuxClose(pinned_fd);
                return replyError(output, request, uapi.errno_io);
            }) {
                linuxClose(pinned_fd);
                return replyError(output, request, uapi.errno_noent);
            }
            if (nodeKind(existing_stat.mode) != .file) {
                linuxClose(pinned_fd);
                return replyError(output, request, uapi.errno_access);
            }
            if (input.flags & o_exclusive != 0) {
                linuxClose(pinned_fd);
                return replyError(output, request, uapi.errno_exist);
            }
            data_fd = switch (linuxOpenDataNode(
                pinned_fd,
                input.flags & ~(o_create | o_exclusive),
                existing_identity,
            )) {
                .fd => |opened| opened,
                .errno => |errno| {
                    linuxClose(pinned_fd);
                    return replyError(output, request, errno);
                },
            };
        } else {
            // O_EXCL converts a hostile host-side replacement race into EEXIST;
            // never truncate a name that appeared after the safe absence check.
            data_fd = switch (linuxCreateChild(
                parent.fd,
                name,
                input.flags | o_exclusive,
                input.mode & ~input.umask,
            )) {
                .fd => |opened| opened,
                .errno => |errno| return replyError(output, request, errno),
            };
            pinned_fd = linuxDup(data_fd) catch |err| {
                linuxClose(data_fd);
                return replyError(output, request, linuxErrorErrno(err));
            };
        }
        var keep_data_fd = false;
        defer if (!keep_data_fd) linuxClose(data_fd);
        var keep_pinned_fd = false;
        defer if (!keep_pinned_fd) linuxClose(pinned_fd);

        const stat = linuxStatFd(data_fd) orelse
            return replyError(output, request, uapi.errno_io);
        const identity = identityFromStat(stat);
        if (self.shouldHideIdentity(identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_perm);
        }

        const node_id = if (self.tables.findNodeByIdentity(identity)) |existing|
            self.tables.retainNode(existing.id) catch
                return replyError(output, request, uapi.errno_io)
        else blk: {
            const id = self.tables.acquireNode(identity, pinned_fd, nodeKind(stat.mode)) catch |err| {
                return replyError(output, request, tableErrorErrno(err));
            };
            keep_pinned_fd = true;
            break :blk id;
        };

        const handle_id = self.tables.addHandle(node_id, data_fd, .file) catch |err| {
            if (self.tables.forgetNode(node_id, 1) catch null) |fd| linuxClose(fd);
            return replyError(output, request, tableErrorErrno(err));
        };
        keep_data_fd = true;
        return encodeCreate(output, request.header.unique, node_id, stat, handle_id);
    }

    fn handleRead(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.ReadIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.ReadIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const handle = self.tables.handle(input.fh, .file) orelse
            return replyError(output, request, uapi.errno_inval);
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        const count = @min(@as(usize, input.size), output.len - writer.cursor);
        const read_result = linuxPread(
            handle.fd,
            output[writer.cursor .. writer.cursor + count],
            input.offset,
        );
        if (read_result.errno) |errno| return replyError(output, request, errno);
        writer.cursor += read_result.count;
        return writer.finish();
    }

    fn handleWrite(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.WriteIn) catch
            return replyError(output, request, uapi.errno_inval);
        const data_offset = @sizeOf(uapi.WriteIn);
        const data_len: usize = input.size;
        if (request.body.len != data_offset + data_len) {
            return replyError(output, request, uapi.errno_inval);
        }
        const handle = self.tables.handle(input.fh, .file) orelse
            return replyError(output, request, uapi.errno_inval);
        const result = linuxPwrite(handle.fd, request.body[data_offset..], input.offset);
        if (result.errno) |errno| return replyError(output, request, errno);
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        try writer.appendValue(uapi.WriteOut{
            .size = @intCast(result.count),
            .padding = 0,
        });
        return writer.finish();
    }

    fn handleFlush(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.FlushIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.FlushIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const handle = self.tables.handle(input.fh, .file) orelse
            return replyError(output, request, uapi.errno_inval);
        const duplicate = linuxDup(handle.fd) catch |err| {
            return replyError(output, request, linuxErrorErrno(err));
        };
        if (linuxCloseChecked(duplicate)) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleRelease(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
        kind: HandleKind,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.ReleaseIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.ReleaseIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const released = self.tables.releaseHandle(input.fh, kind) catch
            return replyError(output, request, uapi.errno_inval);
        linuxClose(released.fd);
        if (released.unpinned_node_fd) |fd| linuxClose(fd);
        return encodeEmpty(output, request.header.unique);
    }

    fn handleFsync(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
        kind: HandleKind,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.FsyncIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.FsyncIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const handle = self.tables.handle(input.fh, kind) orelse
            return replyError(output, request, uapi.errno_inval);
        if (linuxFsync(handle.fd, input.fsync_flags & 1 != 0)) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleOpendir(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.OpenIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.OpenIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind != .directory) return replyError(output, request, uapi.errno_notdir);
        const dir_fd = switch (linuxOpenDataNode(node.fd, input.flags | o_directory, node.identity)) {
            .fd => |fd| fd,
            .errno => |errno| return replyError(output, request, errno),
        };
        var keep_fd = false;
        defer if (!keep_fd) linuxClose(dir_fd);
        const handle_id = self.tables.addHandle(node.id, dir_fd, .directory) catch |err| {
            return replyError(output, request, tableErrorErrno(err));
        };
        keep_fd = true;
        return encodeOpen(output, request.header.unique, handle_id);
    }

    fn handleReaddir(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.ReadIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.ReadIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        const handle = self.tables.handle(input.fh, .directory) orelse
            return replyError(output, request, uapi.errno_inval);
        if (input.offset > std.math.maxInt(i64)) {
            return replyError(output, request, uapi.errno_inval);
        }
        if (linuxSeek(handle.fd, @intCast(input.offset))) |errno| {
            return replyError(output, request, errno);
        }

        var writer = try protocol.ReplyWriter.init(
            output[0..@min(output.len, @sizeOf(uapi.OutHeader) + @as(usize, input.size))],
            request.header.unique,
        );
        var raw_entries: [32 * 1024]u8 = undefined;
        while (true) {
            const read_result = linuxGetdents(handle.fd, &raw_entries);
            if (read_result.errno) |errno| return replyError(output, request, errno);
            if (read_result.count == 0) return writer.finish();

            var emitted = false;
            var cursor: usize = 0;
            while (cursor < read_result.count) {
                const entry = parseLinuxDirent(raw_entries[0..read_result.count], cursor) orelse
                    return replyError(output, request, errno_proto);
                cursor += entry.record_len;

                if (!std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
                    if (decideLookupName(entry.name) != .allowed) continue;
                    const hidden = blk: {
                        const child_fd = linuxOpenPinnedChild(handle.fd, entry.name) catch break :blk true;
                        defer linuxClose(child_fd);
                        const stat = linuxStatFd(child_fd) orelse break :blk true;
                        break :blk self.shouldHideIdentity(identityFromStat(stat), stat) catch
                            return replyError(output, request, uapi.errno_io);
                    };
                    if (hidden) continue;
                }
                writer.appendDirent(
                    entry.inode,
                    @bitCast(entry.next_offset),
                    direntKind(entry.kind),
                    entry.name,
                ) catch |err| switch (err) {
                    error.NoSpace => return writer.finish(),
                    else => return err,
                };
                emitted = true;
            }
            if (emitted) return writer.finish();
        }
    }

    fn handleCreateNode(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (parent.kind != .directory) return replyError(output, request, uapi.errno_notdir);

        const name: []const u8 = switch (request.opcode.?) {
            .mkdir => protocol.singleName(request.body, @sizeOf(uapi.MkdirIn)) catch
                return replyError(output, request, uapi.errno_inval),
            .mknod => protocol.singleName(request.body, @sizeOf(uapi.MknodIn)) catch
                return replyError(output, request, uapi.errno_inval),
            else => unreachable,
        };
        const errno: ?u16 = switch (request.opcode.?) {
            .mkdir => blk: {
                const input = request.bodyAs(uapi.MkdirIn) catch
                    return replyError(output, request, uapi.errno_inval);
                break :blk linuxMkdirChild(parent.fd, name, input.mode & ~input.umask);
            },
            .mknod => blk: {
                const input = request.bodyAs(uapi.MknodIn) catch
                    return replyError(output, request, uapi.errno_inval);
                const kind = input.mode & mode_type_mask;
                if (kind != mode_regular) {
                    return replyError(
                        output,
                        request,
                        if (kind == mode_char or kind == mode_block) uapi.errno_perm else errno_opnotsupp,
                    );
                }
                break :blk linuxMknodChild(parent.fd, name, input.mode & ~input.umask, input.rdev);
            },
            else => unreachable,
        };
        if (errno) |value| return replyError(output, request, value);
        return self.encodeChildEntry(parent.fd, name, request, output);
    }

    fn encodeChildEntry(
        self: *DaemonState,
        parent_fd: i32,
        name: []const u8,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const child_fd = linuxOpenPinnedChild(parent_fd, name) catch |err| {
            return replyError(output, request, linuxErrorErrno(err));
        };
        var keep_fd = false;
        defer if (!keep_fd) linuxClose(child_fd);
        const stat = linuxStatFd(child_fd) orelse
            return replyError(output, request, uapi.errno_io);
        const identity = identityFromStat(stat);
        if (self.shouldHideIdentity(identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_perm);
        }
        const node_id = if (self.tables.findNodeByIdentity(identity)) |existing|
            self.tables.retainNode(existing.id) catch
                return replyError(output, request, uapi.errno_io)
        else blk: {
            const id = self.tables.acquireNode(identity, child_fd, nodeKind(stat.mode)) catch |err| {
                return replyError(output, request, tableErrorErrno(err));
            };
            keep_fd = true;
            break :blk id;
        };
        return encodeEntry(output, request.header.unique, node_id, stat);
    }

    fn handleUnlink(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const name = protocol.singleName(request.body, 0) catch
            return replyError(output, request, uapi.errno_inval);
        const parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (parent.kind != .directory) return replyError(output, request, uapi.errno_notdir);
        if (self.existingChildTainted(parent.fd, name) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        if (linuxUnlinkChild(parent.fd, name, request.opcode.? == .rmdir)) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleRename(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const source_parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        var destination_node_id: u64 = undefined;
        var flags: u32 = 0;
        var prefix_len: usize = undefined;
        switch (request.opcode.?) {
            .rename => {
                const input = request.bodyAs(uapi.RenameIn) catch
                    return replyError(output, request, uapi.errno_inval);
                destination_node_id = input.newdir;
                prefix_len = @sizeOf(uapi.RenameIn);
            },
            .rename2 => {
                const input = request.bodyAs(uapi.Rename2In) catch
                    return replyError(output, request, uapi.errno_inval);
                destination_node_id = input.newdir;
                flags = input.flags;
                prefix_len = @sizeOf(uapi.Rename2In);
                if (flags & ~(rename_noreplace | rename_exchange) != 0 or
                    flags & rename_noreplace != 0 and flags & rename_exchange != 0)
                {
                    return replyError(output, request, uapi.errno_inval);
                }
            },
            else => unreachable,
        }
        const destination_parent = self.tables.node(destination_node_id) orelse
            return replyError(output, request, uapi.errno_noent);
        if (source_parent.kind != .directory or destination_parent.kind != .directory) {
            return replyError(output, request, uapi.errno_notdir);
        }
        const names = protocol.twoNames(request.body, prefix_len) catch
            return replyError(output, request, uapi.errno_inval);
        if (self.existingChildTainted(source_parent.fd, names.first) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        if (self.existingChildTainted(destination_parent.fd, names.second) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        if (linuxRenameChild(
            source_parent.fd,
            names.first,
            destination_parent.fd,
            names.second,
            flags,
        )) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleLink(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const input = request.bodyAs(uapi.LinkIn) catch
            return replyError(output, request, uapi.errno_inval);
        const name = protocol.singleName(request.body, @sizeOf(uapi.LinkIn)) catch
            return replyError(output, request, uapi.errno_inval);
        const source = self.tables.node(input.oldnodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        const destination = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (source.kind != .file or destination.kind != .directory) {
            return replyError(output, request, uapi.errno_perm);
        }
        if (self.tables.isTainted(source.identity)) {
            return replyError(output, request, uapi.errno_noent);
        }
        const source_stat = linuxStatFd(source.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (source_stat.nlink > 1 and !self.tables.isSafeHardlink(source.identity)) {
            self.tables.markTainted(source.identity) catch
                return replyError(output, request, uapi.errno_io);
            return replyError(output, request, uapi.errno_noent);
        }
        if (linuxLinkChild(source.fd, destination.fd, name)) |errno| {
            return replyError(output, request, errno);
        }
        self.tables.markSafeHardlink(source.identity) catch
            return replyError(output, request, uapi.errno_io);
        return self.encodeChildEntry(destination.fd, name, request, output);
    }

    fn handleSymlink(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const fields = parseSymlinkFields(request.body) orelse
            return replyError(output, request, uapi.errno_inval);
        const parent = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (parent.kind != .directory) return replyError(output, request, uapi.errno_notdir);
        if (linuxSymlinkChild(parent.fd, fields.target, fields.name)) |errno| {
            return replyError(output, request, errno);
        }
        return self.encodeChildEntry(parent.fd, fields.name, request, output);
    }

    fn handleReadlink(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        if (request.body.len != 0) return replyError(output, request, uapi.errno_inval);
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind != .symlink) return replyError(output, request, uapi.errno_inval);
        if (output.len < @sizeOf(uapi.OutHeader)) return error.NoSpace;
        const result = linuxReadlinkFd(node.fd, output[@sizeOf(uapi.OutHeader)..]);
        if (result.errno) |errno| return replyError(output, request, errno);
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        writer.cursor += result.count;
        return writer.finish();
    }

    fn handleStatfs(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        if (request.body.len != 0) return replyError(output, request, uapi.errno_inval);
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        const result = linuxStatfs(node.fd);
        if (result.errno) |errno| return replyError(output, request, errno);
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        try writer.appendValue(uapi.StatfsOut{ .st = result.stat });
        return writer.finish();
    }

    fn handleXattr(
        self: *DaemonState,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        const node = self.tables.node(request.header.nodeid) orelse
            return replyError(output, request, uapi.errno_noent);
        if (node.kind != .file and node.kind != .directory) {
            return replyError(output, request, uapi.errno_access);
        }
        const stat = linuxStatFd(node.fd) orelse
            return replyError(output, request, uapi.errno_io);
        if (!identitiesEqual(node.identity, identityFromStat(stat))) {
            return replyError(output, request, uapi.errno_io);
        }
        if (self.shouldHideIdentity(node.identity, stat) catch
            return replyError(output, request, uapi.errno_io))
        {
            return replyError(output, request, uapi.errno_noent);
        }
        const data_fd = switch (linuxOpenDataNode(node.fd, o_readonly, node.identity)) {
            .fd => |fd| fd,
            .errno => |errno| return replyError(output, request, errno),
        };
        defer linuxClose(data_fd);

        return switch (request.opcode.?) {
            .setxattr => self.handleSetxattr(data_fd, request, output),
            .getxattr => self.handleGetxattr(data_fd, request, output),
            .listxattr => self.handleListxattr(data_fd, request, output),
            .removexattr => self.handleRemovexattr(data_fd, request, output),
            else => unreachable,
        };
    }

    fn handleSetxattr(
        self: *DaemonState,
        fd: i32,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        _ = self;
        const input = request.bodyAs(uapi.SetxattrIn) catch
            return replyError(output, request, uapi.errno_inval);
        const field = protocol.nulTerminated(request.body, @sizeOf(uapi.SetxattrIn)) catch
            return replyError(output, request, uapi.errno_inval);
        const value_len: usize = input.size;
        if (field.next_offset + value_len != request.body.len) {
            return replyError(output, request, uapi.errno_inval);
        }
        if (linuxSetxattr(fd, field.value, request.body[field.next_offset..], input.flags)) |errno| {
            return replyError(output, request, errno);
        }
        return encodeEmpty(output, request.header.unique);
    }

    fn handleGetxattr(
        self: *DaemonState,
        fd: i32,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        _ = self;
        const input = request.bodyAs(uapi.GetxattrIn) catch
            return replyError(output, request, uapi.errno_inval);
        const name = protocol.singleName(request.body, @sizeOf(uapi.GetxattrIn)) catch
            return replyError(output, request, uapi.errno_inval);
        return encodeXattrRead(fd, name, input.size, request, output, false);
    }

    fn handleListxattr(
        self: *DaemonState,
        fd: i32,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        _ = self;
        const input = request.bodyAs(uapi.GetxattrIn) catch
            return replyError(output, request, uapi.errno_inval);
        if (request.body.len != @sizeOf(uapi.GetxattrIn)) {
            return replyError(output, request, uapi.errno_inval);
        }
        return encodeXattrRead(fd, "", input.size, request, output, true);
    }

    fn handleRemovexattr(
        self: *DaemonState,
        fd: i32,
        request: protocol.Request,
        output: []u8,
    ) protocol.EncodeError![]const u8 {
        _ = self;
        const name = protocol.singleName(request.body, 0) catch
            return replyError(output, request, uapi.errno_inval);
        if (linuxRemovexattr(fd, name)) |errno| return replyError(output, request, errno);
        return encodeEmpty(output, request.header.unique);
    }

    fn scanTaintedTree(self: *DaemonState) !void {
        const root = self.tables.node(uapi.root_id) orelse return error.InvalidBackingRoot;
        try scanDirectoryForTaints(self, root.fd);
    }
};

/// Runs one raw-FUSE daemon until `DESTROY`, EOF, or a fatal protocol/I/O error.
/// Takes ownership of `fuse_fd` and `backing_root_fd`.
pub fn serve(
    allocator: std.mem.Allocator,
    fuse_fd: i32,
    backing_root_fd: i32,
    ready_fd: i32,
    limits: Limits,
) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    var state = DaemonState.init(allocator, fuse_fd, backing_root_fd, limits) catch |err| {
        linuxClose(fuse_fd);
        linuxClose(backing_root_fd);
        return err;
    };
    defer state.deinit();
    try state.scanTaintedTree();

    const request_buffer = try allocator.alloc(u8, limits.max_request_bytes);
    defer allocator.free(request_buffer);
    const response_buffer = try allocator.alloc(u8, limits.max_request_bytes);
    defer allocator.free(response_buffer);

    var ready_sent = false;
    while (true) {
        const frame_len = try linuxReadFrame(fuse_fd, request_buffer);
        if (frame_len == 0) return;
        const request = try protocol.decodeRequest(request_buffer[0..frame_len], limits.max_request_bytes);
        const result = try state.dispatch(request, response_buffer);
        switch (result) {
            .reply => |reply| {
                try linuxWriteAll(fuse_fd, reply);
                if (request.opcode == .init and state.initialized and !ready_sent) {
                    try linuxWriteAll(ready_fd, &.{1});
                    ready_sent = true;
                }
            },
            .no_reply => {},
            .stop => return,
        }
    }
}

fn replyError(
    output: []u8,
    request: protocol.Request,
    errno: u16,
) protocol.EncodeError![]const u8 {
    return protocol.encodeError(output, request.header.unique, errno);
}

fn encodeEmpty(output: []u8, unique: u64) protocol.EncodeError![]const u8 {
    var writer = try protocol.ReplyWriter.init(output, unique);
    return writer.finish();
}

fn encodeOpen(
    output: []u8,
    unique: u64,
    handle_id: u64,
) protocol.EncodeError![]const u8 {
    var writer = try protocol.ReplyWriter.init(output, unique);
    try writer.appendValue(uapi.OpenOut{
        .fh = handle_id,
        .open_flags = 0,
        .padding = 0,
    });
    return writer.finish();
}

fn encodeEntry(
    output: []u8,
    unique: u64,
    node_id: u64,
    stat: std.os.linux.Statx,
) protocol.EncodeError![]const u8 {
    var writer = try protocol.ReplyWriter.init(output, unique);
    try writer.appendValue(uapi.EntryOut{
        .nodeid = node_id,
        .generation = 0,
        .entry_valid = 0,
        .attr_valid = 0,
        .entry_valid_nsec = 0,
        .attr_valid_nsec = 0,
        .attr = fuseAttr(stat, node_id),
    });
    return writer.finish();
}

fn encodeCreate(
    output: []u8,
    unique: u64,
    node_id: u64,
    stat: std.os.linux.Statx,
    handle_id: u64,
) protocol.EncodeError![]const u8 {
    var writer = try protocol.ReplyWriter.init(output, unique);
    try writer.appendValue(uapi.EntryOut{
        .nodeid = node_id,
        .generation = 0,
        .entry_valid = 0,
        .attr_valid = 0,
        .entry_valid_nsec = 0,
        .attr_valid_nsec = 0,
        .attr = fuseAttr(stat, node_id),
    });
    try writer.appendValue(uapi.OpenOut{
        .fh = handle_id,
        .open_flags = 0,
        .padding = 0,
    });
    return writer.finish();
}

fn fuseAttr(stat: std.os.linux.Statx, node_id: u64) uapi.Attr {
    return .{
        .ino = node_id,
        .size = stat.size,
        .blocks = stat.blocks,
        .atime = @bitCast(stat.atime.sec),
        .mtime = @bitCast(stat.mtime.sec),
        .ctime = @bitCast(stat.ctime.sec),
        .atimensec = stat.atime.nsec,
        .mtimensec = stat.mtime.nsec,
        .ctimensec = stat.ctime.nsec,
        .mode = stat.mode,
        .nlink = stat.nlink,
        .uid = stat.uid,
        .gid = stat.gid,
        .rdev = 0,
        .blksize = stat.blksize,
        .padding = 0,
    };
}

fn nodeKind(mode: u16) NodeKind {
    return switch (@as(u32, mode) & mode_type_mask) {
        mode_regular => .file,
        mode_directory => .directory,
        mode_symlink => .symlink,
        else => .other,
    };
}

fn identityFromStat(stat: std.os.linux.Statx) Identity {
    return .{
        .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
        .inode = stat.ino,
    };
}

fn tableErrorErrno(err: anyerror) u16 {
    return switch (err) {
        error.NodeCapacity,
        error.FileHandleCapacity,
        error.DirHandleCapacity,
        error.TaintedCapacity,
        => errno_mfile,
        error.TaintedIdentity => uapi.errno_noent,
        else => uapi.errno_io,
    };
}

fn linuxErrorErrno(err: LinuxOpenError) u16 {
    return switch (err) {
        error.AccessDenied => uapi.errno_access,
        error.NotFound => uapi.errno_noent,
        error.AlreadyExists => uapi.errno_exist,
        error.NotDirectory => uapi.errno_notdir,
        error.IsDirectory => uapi.errno_isdir,
        error.Invalid => uapi.errno_inval,
        error.TooManyFiles => errno_mfile,
        error.Unsupported => errno_opnotsupp,
        error.SymlinkLoop, error.CrossDevice => uapi.errno_access,
        error.Io => uapi.errno_io,
    };
}

fn errnoFromResult(result: usize) ?u16 {
    const errno = std.os.linux.errno(result);
    if (errno == .SUCCESS) return null;
    return @intCast(@intFromEnum(errno));
}

fn openErrorFromErrno(errno: u16) LinuxOpenError {
    return switch (errno) {
        1, 13 => error.AccessDenied,
        2 => error.NotFound,
        17 => error.AlreadyExists,
        18 => error.CrossDevice,
        20 => error.NotDirectory,
        21 => error.IsDirectory,
        22 => error.Invalid,
        24 => error.TooManyFiles,
        38, 95 => error.Unsupported,
        40 => error.SymlinkLoop,
        else => error.Io,
    };
}

fn copyZ(input: []const u8, buffer: *[uapi.max_name_len + 1:0]u8) ?[:0]const u8 {
    if (input.len == 0 or input.len > uapi.max_name_len) return null;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return null;
    @memcpy(buffer[0..input.len], input);
    buffer[input.len] = 0;
    return buffer[0..input.len :0];
}

fn linuxOpenAt2(
    dir_fd: i32,
    name: []const u8,
    flags: u64,
    mode: u64,
    resolve: u64,
) LinuxOpenError!i32 {
    var name_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &name_buffer) orelse return error.Invalid;
    const how: OpenHow = .{
        .flags = flags,
        .mode = mode,
        .resolve = resolve,
    };
    const result = std.os.linux.syscall4(
        .openat2,
        @bitCast(@as(isize, dir_fd)),
        @intFromPtr(name_z.ptr),
        @intFromPtr(&how),
        @sizeOf(OpenHow),
    );
    if (errnoFromResult(result)) |errno| return openErrorFromErrno(errno);
    if (result > std.math.maxInt(i32)) return error.Io;
    return @intCast(result);
}

fn linuxOpenPinnedChild(parent_fd: i32, name: []const u8) LinuxOpenError!i32 {
    return linuxOpenAt2(
        parent_fd,
        name,
        o_path | o_nofollow | o_cloexec,
        0,
        safe_resolve,
    ) catch |err| switch (err) {
        // Some otherwise supported Linux environments (including LinuxKit)
        // omit openat2. A single validated component opened relative to a
        // pinned directory with O_PATH|O_NOFOLLOW is still race-safe; matching
        // device identities supplies the RESOLVE_NO_XDEV property.
        error.Unsupported => linuxOpenPinnedChildFallback(parent_fd, name),
        else => err,
    };
}

fn linuxOpenPinnedChildFallback(parent_fd: i32, name: []const u8) LinuxOpenError!i32 {
    var name_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &name_buffer) orelse return error.Invalid;
    const result = std.os.linux.syscall4(
        .openat,
        @bitCast(@as(isize, parent_fd)),
        @intFromPtr(name_z.ptr),
        o_path | o_nofollow | o_cloexec,
        0,
    );
    if (errnoFromResult(result)) |errno| return openErrorFromErrno(errno);
    if (result > std.math.maxInt(i32)) return error.Io;
    const fd: i32 = @intCast(result);
    errdefer linuxClose(fd);
    const parent_stat = linuxStatFd(parent_fd) orelse return error.Io;
    const child_stat = linuxStatFd(fd) orelse return error.Io;
    if (!parent_stat.mask.MNT_ID or !child_stat.mask.MNT_ID) return error.Unsupported;
    if (parent_stat.mnt_id != child_stat.mnt_id) {
        return error.CrossDevice;
    }
    return fd;
}

fn linuxOpenDataNode(pinned_fd: i32, requested_flags: u32, identity: Identity) FdResult {
    if (requested_flags & (o_path | o_tmpfile_bit | o_create | o_exclusive) != 0) {
        return .{ .errno = uapi.errno_inval };
    }
    // `/proc/self/fd/N` is the daemon-controlled reopen path for a pinned node;
    // following that one procfs link is required. Identity is revalidated before
    // the descriptor is returned to any handler.
    const flags = requested_flags | o_cloexec;
    var path_buffer: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/self/fd/{d}", .{pinned_fd}) catch
        return .{ .errno = uapi.errno_io };
    const result = std.os.linux.open(path.ptr, @bitCast(flags), 0);
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    if (result > std.math.maxInt(i32)) return .{ .errno = uapi.errno_io };
    const fd: i32 = @intCast(result);
    const stat = linuxStatFd(fd) orelse {
        linuxClose(fd);
        return .{ .errno = uapi.errno_io };
    };
    if (!identitiesEqual(identity, identityFromStat(stat))) {
        linuxClose(fd);
        return .{ .errno = uapi.errno_access };
    }
    return .{ .fd = fd };
}

fn linuxCreateChild(parent_fd: i32, name: []const u8, requested_flags: u32, mode: u32) FdResult {
    if (requested_flags & (o_path | o_tmpfile_bit) != 0) return .{ .errno = uapi.errno_inval };
    const flags = requested_flags | o_create | o_nofollow | o_cloexec;
    const fd = linuxOpenAt2(parent_fd, name, flags, mode & 0o7777, safe_resolve) catch |err| {
        return .{ .errno = linuxErrorErrno(err) };
    };
    return .{ .fd = fd };
}

fn linuxStatFd(fd: i32) ?std.os.linux.Statx {
    var stat = std.mem.zeroes(std.os.linux.Statx);
    var mask = std.os.linux.STATX.BASIC_STATS;
    mask.MNT_ID = true;
    const result = std.os.linux.statx(
        fd,
        "",
        std.os.linux.AT.EMPTY_PATH | std.os.linux.AT.STATX_FORCE_SYNC,
        mask,
        &stat,
    );
    if (errnoFromResult(result) != null) return null;
    return stat;
}

fn linuxClose(fd: i32) void {
    if (fd >= 0) _ = std.os.linux.close(fd);
}

fn linuxCloseChecked(fd: i32) ?u16 {
    if (fd < 0) return uapi.errno_inval;
    return errnoFromResult(std.os.linux.close(fd));
}

fn linuxDup(fd: i32) LinuxOpenError!i32 {
    const result = std.os.linux.dup(fd);
    if (errnoFromResult(result)) |errno| return openErrorFromErrno(errno);
    if (result > std.math.maxInt(i32)) return error.Io;
    return @intCast(result);
}

fn linuxPread(fd: i32, output: []u8, offset: u64) IoResult {
    if (offset > std.math.maxInt(i64)) return .{ .errno = uapi.errno_inval };
    const result = std.os.linux.pread(fd, output.ptr, output.len, @intCast(offset));
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    return .{ .count = result };
}

fn linuxPwrite(fd: i32, input: []const u8, offset: u64) IoResult {
    if (offset > std.math.maxInt(i64)) return .{ .errno = uapi.errno_inval };
    const result = std.os.linux.pwrite(fd, input.ptr, input.len, @intCast(offset));
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    return .{ .count = result };
}

fn linuxFsync(fd: i32, data_only: bool) ?u16 {
    const result = if (data_only) std.os.linux.fdatasync(fd) else std.os.linux.fsync(fd);
    return errnoFromResult(result);
}

fn linuxSeek(fd: i32, offset: i64) ?u16 {
    return errnoFromResult(std.os.linux.lseek(fd, offset, 0));
}

fn linuxGetdents(fd: i32, output: []u8) IoResult {
    const result = std.os.linux.getdents64(fd, output.ptr, output.len);
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    return .{ .count = result };
}

fn parseLinuxDirent(bytes: []const u8, offset: usize) ?LinuxDirent {
    if (offset > bytes.len or bytes.len - offset < 19) return null;
    const endian = builtin.cpu.arch.endian();
    const record_len: usize = std.mem.readInt(u16, bytes[offset + 16 ..][0..2], endian);
    if (record_len < 20 or record_len > bytes.len - offset) return null;
    const name_bytes = bytes[offset + 19 .. offset + record_len];
    const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse return null;
    if (name_len == 0) return null;
    return .{
        .inode = std.mem.readInt(u64, bytes[offset..][0..8], endian),
        .next_offset = @bitCast(std.mem.readInt(u64, bytes[offset + 8 ..][0..8], endian)),
        .record_len = record_len,
        .kind = bytes[offset + 18],
        .name = name_bytes[0..name_len],
    };
}

fn direntKind(kind: u8) u32 {
    return switch (kind) {
        1 => uapi.dirent_fifo,
        2 => uapi.dirent_char,
        4 => uapi.dirent_dir,
        6 => uapi.dirent_block,
        8 => uapi.dirent_file,
        10 => uapi.dirent_symlink,
        12 => uapi.dirent_socket,
        else => uapi.dirent_unknown,
    };
}

fn decodeNative(comptime T: type, bytes: []const u8) T {
    std.debug.assert(bytes.len == @sizeOf(T));
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    return value;
}

fn linuxApplySetattr(pinned_fd: i32, input: uapi.SetattrIn) ?u16 {
    if (input.valid & ~setattr_supported != 0) return uapi.errno_inval;
    const before = linuxStatFd(pinned_fd) orelse return uapi.errno_io;
    const identity = identityFromStat(before);
    const requested_access: u32 = if (input.valid & setattr_size != 0) o_readwrite else o_readonly;
    const data_fd = switch (linuxOpenDataNode(pinned_fd, requested_access, identity)) {
        .fd => |fd| fd,
        .errno => |errno| return errno,
    };
    defer linuxClose(data_fd);

    if (input.valid & setattr_size != 0) {
        if (input.size > std.math.maxInt(i64)) return uapi.errno_inval;
        if (errnoFromResult(std.os.linux.ftruncate(data_fd, @intCast(input.size)))) |errno| return errno;
    }
    if (input.valid & setattr_mode != 0) {
        if (errnoFromResult(std.os.linux.fchmod(data_fd, input.mode & 0o7777))) |errno| return errno;
    } else if (input.valid & setattr_kill_suidgid != 0) {
        if (errnoFromResult(std.os.linux.fchmod(data_fd, @as(u32, before.mode) & 0o1777))) |errno| {
            return errno;
        }
    }
    if (input.valid & (setattr_uid | setattr_gid) != 0) {
        const uid = if (input.valid & setattr_uid != 0) input.uid else before.uid;
        const gid = if (input.valid & setattr_gid != 0) input.gid else before.gid;
        if (errnoFromResult(std.os.linux.fchown(data_fd, uid, gid))) |errno| return errno;
    }
    if (input.valid & (setattr_atime | setattr_mtime | setattr_atime_now | setattr_mtime_now) != 0) {
        const omit_nsec: isize = 0x3ffffffe;
        const now_nsec: isize = 0x3fffffff;
        var times = [2]std.os.linux.timespec{
            .{ .sec = 0, .nsec = omit_nsec },
            .{ .sec = 0, .nsec = omit_nsec },
        };
        if (input.valid & setattr_atime_now != 0) {
            times[0].nsec = now_nsec;
        } else if (input.valid & setattr_atime != 0) {
            times[0] = .{ .sec = @bitCast(input.atime), .nsec = input.atimensec };
        }
        if (input.valid & setattr_mtime_now != 0) {
            times[1].nsec = now_nsec;
        } else if (input.valid & setattr_mtime != 0) {
            times[1] = .{ .sec = @bitCast(input.mtime), .nsec = input.mtimensec };
        }
        if (errnoFromResult(std.os.linux.futimens(data_fd, &times))) |errno| return errno;
    }
    return null;
}

fn linuxAccessFd(fd: i32, identity: Identity, kind: NodeKind, mask: u32) ?u16 {
    const data_fd = switch (linuxOpenDataNode(
        fd,
        o_readonly | if (kind == .directory) o_directory else 0,
        identity,
    )) {
        .fd => |opened| opened,
        .errno => |errno| return errno,
    };
    defer linuxClose(data_fd);
    var path_buffer: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/self/fd/{d}", .{data_fd}) catch
        return uapi.errno_io;
    return errnoFromResult(std.os.linux.access(path.ptr, mask));
}

fn linuxMkdirChild(parent_fd: i32, name: []const u8, mode: u32) ?u16 {
    var buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.mkdirat(parent_fd, name_z.ptr, mode & 0o7777));
}

fn linuxMknodChild(parent_fd: i32, name: []const u8, mode: u32, device: u32) ?u16 {
    var buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.mknodat(parent_fd, name_z.ptr, mode, device));
}

fn linuxUnlinkChild(parent_fd: i32, name: []const u8, directory: bool) ?u16 {
    var buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.unlinkat(
        parent_fd,
        name_z.ptr,
        if (directory) std.os.linux.AT.REMOVEDIR else 0,
    ));
}

fn linuxRenameChild(
    old_parent_fd: i32,
    old_name: []const u8,
    new_parent_fd: i32,
    new_name: []const u8,
    flags: u32,
) ?u16 {
    var old_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    var new_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const old_z = copyZ(old_name, &old_buffer) orelse return uapi.errno_inval;
    const new_z = copyZ(new_name, &new_buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.renameat2(
        old_parent_fd,
        old_z.ptr,
        new_parent_fd,
        new_z.ptr,
        @bitCast(flags),
    ));
}

fn linuxLinkChild(source_fd: i32, destination_parent_fd: i32, name: []const u8) ?u16 {
    var source_buffer: [64:0]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_buffer, "/proc/self/fd/{d}", .{source_fd}) catch
        return uapi.errno_io;
    var name_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &name_buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.linkat(
        std.os.linux.AT.FDCWD,
        source.ptr,
        destination_parent_fd,
        name_z.ptr,
        std.os.linux.AT.SYMLINK_FOLLOW,
    ));
}

fn linuxSymlinkChild(parent_fd: i32, target: []const u8, name: []const u8) ?u16 {
    if (target.len == 0 or target.len >= std.os.linux.PATH_MAX) return uapi.errno_inval;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return uapi.errno_inval;
    var target_buffer: [std.os.linux.PATH_MAX:0]u8 = undefined;
    @memcpy(target_buffer[0..target.len], target);
    target_buffer[target.len] = 0;
    const target_z = target_buffer[0..target.len :0];
    var name_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &name_buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.symlinkat(target_z.ptr, parent_fd, name_z.ptr));
}

fn linuxReadlinkFd(fd: i32, output: []u8) IoResult {
    const result = std.os.linux.readlinkat(fd, "", output.ptr, output.len);
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    return .{ .count = result };
}

fn linuxStatfs(fd: i32) StatfsResult {
    if (@sizeOf(usize) != 8) return .{ .errno = errno_opnotsupp };
    var raw = std.mem.zeroes(LinuxStatfs);
    const result = std.os.linux.syscall2(
        .fstatfs,
        @bitCast(@as(isize, fd)),
        @intFromPtr(&raw),
    );
    if (errnoFromResult(result)) |errno| return .{ .errno = errno };
    return .{ .stat = .{
        .blocks = raw.blocks,
        .bfree = raw.blocks_free,
        .bavail = raw.blocks_available,
        .files = raw.files,
        .ffree = raw.files_free,
        .bsize = if (raw.block_size > 0 and raw.block_size <= std.math.maxInt(u32))
            @intCast(raw.block_size)
        else
            4096,
        .namelen = if (raw.name_len > 0 and raw.name_len <= std.math.maxInt(u32))
            @intCast(raw.name_len)
        else
            uapi.max_name_len,
        .frsize = if (raw.fragment_size > 0 and raw.fragment_size <= std.math.maxInt(u32))
            @intCast(raw.fragment_size)
        else
            4096,
        .padding = 0,
        .spare = .{0} ** 6,
    } };
}

fn linuxSetxattr(fd: i32, name: []const u8, value: []const u8, flags: u32) ?u16 {
    var buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.fsetxattr(
        fd,
        name_z.ptr,
        value.ptr,
        value.len,
        flags,
    ));
}

fn linuxRemovexattr(fd: i32, name: []const u8) ?u16 {
    var buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = copyZ(name, &buffer) orelse return uapi.errno_inval;
    return errnoFromResult(std.os.linux.fremovexattr(@intCast(fd), name_z.ptr));
}

fn encodeXattrRead(
    fd: i32,
    name: []const u8,
    requested_size: u32,
    request: protocol.Request,
    output: []u8,
    list: bool,
) protocol.EncodeError![]const u8 {
    var name_buffer: [uapi.max_name_len + 1:0]u8 = undefined;
    const name_z = if (list) null else copyZ(name, &name_buffer) orelse
        return replyError(output, request, uapi.errno_inval);
    var dummy: [1]u8 = undefined;
    if (requested_size == 0) {
        const result = if (list)
            std.os.linux.flistxattr(fd, &dummy, 0)
        else
            std.os.linux.fgetxattr(fd, name_z.?.ptr, &dummy, 0);
        if (errnoFromResult(result)) |errno| return replyError(output, request, errno);
        if (result > std.math.maxInt(u32)) return replyError(output, request, errno_range);
        var writer = try protocol.ReplyWriter.init(output, request.header.unique);
        try writer.appendValue(uapi.GetxattrOut{
            .size = @intCast(result),
            .padding = 0,
        });
        return writer.finish();
    }

    if (output.len < @sizeOf(uapi.OutHeader) or
        requested_size > output.len - @sizeOf(uapi.OutHeader))
    {
        return replyError(output, request, errno_range);
    }
    const value = output[@sizeOf(uapi.OutHeader) .. @sizeOf(uapi.OutHeader) + requested_size];
    const result = if (list)
        std.os.linux.flistxattr(fd, value.ptr, value.len)
    else
        std.os.linux.fgetxattr(fd, name_z.?.ptr, value.ptr, value.len);
    if (errnoFromResult(result)) |errno| return replyError(output, request, errno);
    var writer = try protocol.ReplyWriter.init(output, request.header.unique);
    writer.cursor += result;
    return writer.finish();
}

const ScanError = error{
    OutOfMemory,
    ScanDepthExceeded,
    ScanFailed,
    ScanCapacity,
    TaintedCapacity,
};

fn scanDirectoryForTaints(state: *DaemonState, root_fd: i32) ScanError!void {
    const ScanWork = struct {
        fd: i32,
        depth: usize,
        taint_all: bool,
        owned: bool,
        resume_offset: i64,
    };
    var pending: std.ArrayList(ScanWork) = .empty;
    defer {
        for (pending.items) |item| {
            if (item.owned) linuxClose(item.fd);
        }
        pending.deinit(state.tables.allocator);
    }
    try pending.append(state.tables.allocator, .{
        .fd = root_fd,
        .depth = 0,
        .taint_all = false,
        .owned = false,
        .resume_offset = 0,
    });

    var scanned: usize = 0;
    var buffer: [32 * 1024]u8 = undefined;
    while (pending.pop()) |work| {
        const retained = scanDirectoryWork(state, work, &pending, &buffer, &scanned) catch |err| {
            if (work.owned) linuxClose(work.fd);
            return err;
        };
        if (work.owned and !retained) linuxClose(work.fd);
    }
}

fn scanDirectoryWork(
    state: *DaemonState,
    work: anytype,
    pending: anytype,
    buffer: *[32 * 1024]u8,
    scanned: *usize,
) ScanError!bool {
    if (work.depth >= state.tables.limits.max_scan_depth) return error.ScanDepthExceeded;
    const stat = linuxStatFd(work.fd) orelse return error.ScanFailed;
    const data_fd = switch (linuxOpenDataNode(
        work.fd,
        o_readonly | o_directory,
        identityFromStat(stat),
    )) {
        .fd => |fd| fd,
        .errno => return error.ScanFailed,
    };
    defer linuxClose(data_fd);
    if (work.resume_offset != 0 and linuxSeek(data_fd, work.resume_offset) != null) {
        return error.ScanFailed;
    }

    while (true) {
        const result = linuxGetdents(data_fd, buffer);
        if (result.errno != null) return error.ScanFailed;
        if (result.count == 0) return false;
        var cursor: usize = 0;
        while (cursor < result.count) {
            const entry = parseLinuxDirent(buffer[0..result.count], cursor) orelse
                return error.ScanFailed;
            cursor += entry.record_len;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            if (!isValidComponent(entry.name)) return error.ScanFailed;
            scanned.* = std.math.add(usize, scanned.*, 1) catch return error.ScanCapacity;
            if (scanned.* > state.tables.limits.max_scan_entries) return error.ScanCapacity;
            const child_fd = linuxOpenPinnedChild(data_fd, entry.name) catch |err| switch (err) {
                error.NotFound, error.CrossDevice => continue,
                else => return error.ScanFailed,
            };
            var keep_child = false;
            defer if (!keep_child) linuxClose(child_fd);
            const child_stat = linuxStatFd(child_fd) orelse return error.ScanFailed;
            const identity = identityFromStat(child_stat);
            const protected = work.taint_all or profile.isWorkspaceSecretPath(entry.name);

            if (protected or nodeKind(child_stat.mode) == .file and child_stat.nlink > 1) {
                try state.tables.markTainted(identity);
            }
            if (nodeKind(child_stat.mode) == .directory) {
                if (work.depth + 1 >= state.tables.limits.max_scan_depth) {
                    return error.ScanDepthExceeded;
                }
                try pending.append(state.tables.allocator, .{
                    .fd = work.fd,
                    .depth = work.depth,
                    .taint_all = work.taint_all,
                    .owned = work.owned,
                    .resume_offset = entry.next_offset,
                });
                pending.append(state.tables.allocator, .{
                    .fd = child_fd,
                    .depth = work.depth + 1,
                    .taint_all = protected,
                    .owned = true,
                    .resume_offset = 0,
                }) catch |err| {
                    _ = pending.pop();
                    return err;
                };
                keep_child = true;
                return true;
            }
        }
    }
}

fn linuxReadFrame(fd: i32, output: []u8) !usize {
    while (true) {
        const result = std.os.linux.read(fd, output.ptr, output.len);
        if (errnoFromResult(result)) |errno| {
            if (errno == 4) continue;
            return error.FuseReadFailed;
        }
        return result;
    }
}

fn linuxWriteAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = std.os.linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (errnoFromResult(result)) |errno| {
            if (errno == 4) continue;
            return error.FuseWriteFailed;
        }
        if (result == 0) return error.FuseWriteFailed;
        offset += result;
    }
}

test "workspace view denies dynamic secret names and only exempts exact templates" {
    const denied = [_][]const u8{
        ".env",
        ".env.local",
        ".env.production",
        ".env.example.local",
    };
    for (denied) |name| {
        try std.testing.expectEqual(NameDecision.hidden, decideLookupName(name));
        try std.testing.expectEqual(NameDecision.forbidden, decideMutationName(name));
    }

    const allowed = [_][]const u8{
        ".env.example",
        ".env.sample",
        ".env.template",
        ".envrc",
        "service.env",
        "source.zig",
    };
    for (allowed) |name| {
        try std.testing.expectEqual(NameDecision.allowed, decideLookupName(name));
        try std.testing.expectEqual(NameDecision.allowed, decideMutationName(name));
    }
}

test "workspace view rejects malformed components before backing lookup" {
    const malformed = [_][]const u8{
        "",
        ".",
        "..",
        "nested/name",
        "nul\x00smuggle",
    };
    for (malformed) |name| {
        try std.testing.expectEqual(NameDecision.invalid, decideLookupName(name));
        try std.testing.expectEqual(NameDecision.invalid, decideMutationName(name));
    }
}

test "workspace view xattr policy permits only user namespace mutation" {
    try std.testing.expectEqual(XattrDecision.allowed, decideXattrMutation("user.note"));
    try std.testing.expectEqual(XattrDecision.forbidden, decideXattrMutation("security.capability"));
    try std.testing.expectEqual(XattrDecision.forbidden, decideXattrMutation("trusted.overlay.opaque"));
    try std.testing.expectEqual(XattrDecision.forbidden, decideXattrMutation("system.posix_acl_access"));
    try std.testing.expectEqual(XattrDecision.invalid, decideXattrMutation(""));
    try std.testing.expectEqual(XattrDecision.invalid, decideXattrMutation("user.bad\x00name"));
}

test "workspace view unknown and unsupported operations fail closed" {
    try std.testing.expectEqual(
        UnsupportedDecision.unknown,
        unsupportedDecision(null),
    );
    try std.testing.expectEqual(
        UnsupportedDecision.not_tty,
        unsupportedDecision(.ioctl),
    );
    try std.testing.expectEqual(
        UnsupportedDecision.not_supported,
        unsupportedDecision(.poll),
    );
    try std.testing.expectEqual(
        UnsupportedDecision.supported,
        unsupportedDecision(.lookup),
    );
}

test "workspace view request preflight maps hidden forbidden and unsupported operations" {
    const lookup_secret: protocol.Request = .{
        .header = testRequestHeader(.lookup, 1),
        .opcode = .lookup,
        .body = ".env\x00",
    };
    try std.testing.expectEqual(@as(?u16, uapi.errno_noent), try preflightErrno(lookup_secret));

    const unlink_secret: protocol.Request = .{
        .header = testRequestHeader(.unlink, 1),
        .opcode = .unlink,
        .body = ".env.local\x00",
    };
    try std.testing.expectEqual(@as(?u16, uapi.errno_perm), try preflightErrno(unlink_secret));

    const ioctl_request: protocol.Request = .{
        .header = testRequestHeader(.ioctl, 1),
        .opcode = .ioctl,
        .body = "",
    };
    try std.testing.expectEqual(@as(?u16, errno_notty), try preflightErrno(ioctl_request));

    const unknown: protocol.Request = .{
        .header = .{
            .len = @sizeOf(uapi.InHeader),
            .opcode = 0xffff,
            .unique = 4,
            .nodeid = 1,
            .uid = 0,
            .gid = 0,
            .pid = 1,
            .padding = 0,
        },
        .opcode = null,
        .body = "",
    };
    try std.testing.expectEqual(@as(?u16, uapi.errno_nosys), try preflightErrno(unknown));

    const safe_symlink: protocol.Request = .{
        .header = testRequestHeader(.symlink, 1),
        .opcode = .symlink,
        .body = "../nested/target\x00link-name\x00",
    };
    try std.testing.expectEqual(@as(?u16, null), try preflightErrno(safe_symlink));

    const denied_symlink: protocol.Request = .{
        .header = testRequestHeader(.symlink, 1),
        .opcode = .symlink,
        .body = "target\x00.env.production\x00",
    };
    try std.testing.expectEqual(@as(?u16, uapi.errno_perm), try preflightErrno(denied_symlink));
}

fn testRequestHeader(opcode: uapi.Opcode, node_id: u64) uapi.InHeader {
    return .{
        .len = @sizeOf(uapi.InHeader),
        .opcode = @intFromEnum(opcode),
        .unique = 7,
        .nodeid = node_id,
        .uid = 501,
        .gid = 20,
        .pid = 42,
        .padding = 0,
    };
}

fn testReplyErr(result: DispatchResult) !i32 {
    return switch (result) {
        .reply => |reply| std.mem.bytesToValue(uapi.OutHeader, reply).err,
        else => error.UnexpectedDispatchResult,
    };
}

fn testBodyWithNames(value: anytype, names: []const u8, output: []u8) []const u8 {
    const prefix = std.mem.asBytes(&value);
    std.debug.assert(prefix.len + names.len <= output.len);
    @memcpy(output[0..prefix.len], prefix);
    @memcpy(output[prefix.len..][0..names.len], names);
    return output[0 .. prefix.len + names.len];
}

fn testFindDirent(reply: []const u8, wanted: []const u8) !?u64 {
    var cursor: usize = @sizeOf(uapi.OutHeader);
    while (cursor < reply.len) {
        if (reply.len - cursor < @sizeOf(uapi.Dirent)) return error.InvalidDirentReply;
        const dirent = std.mem.bytesToValue(uapi.Dirent, reply[cursor..]);
        const name_start = cursor + @sizeOf(uapi.Dirent);
        const name_end = std.math.add(usize, name_start, dirent.namelen) catch
            return error.InvalidDirentReply;
        if (name_end > reply.len) return error.InvalidDirentReply;
        if (std.mem.eql(u8, reply[name_start..name_end], wanted)) return dirent.off;
        const raw_len = std.math.add(usize, @sizeOf(uapi.Dirent), dirent.namelen) catch
            return error.InvalidDirentReply;
        cursor = std.mem.alignForward(usize, cursor + raw_len, 8);
    }
    if (cursor != reply.len) return error.InvalidDirentReply;
    return null;
}

test "workspace view state bounds nodes and never returns tainted identities" {
    var tables = try StateTables.init(std.testing.allocator, .{
        .max_nodes = 2,
        .max_file_handles = 1,
        .max_dir_handles = 1,
    }, .{ .device = 7, .inode = 11 }, 91);
    defer tables.deinit();

    try tables.markTainted(.{ .device = 7, .inode = 99 });
    try std.testing.expect(tables.isTainted(.{ .device = 7, .inode = 99 }));
    try std.testing.expectError(
        error.TaintedIdentity,
        tables.acquireNode(.{ .device = 7, .inode = 99 }, 92, .file),
    );

    const child = try tables.acquireNode(.{ .device = 7, .inode = 12 }, 93, .file);
    try std.testing.expectEqual(@as(u64, 2), child);
    try std.testing.expectError(
        error.NodeCapacity,
        tables.acquireNode(.{ .device = 7, .inode = 13 }, 94, .file),
    );
}

test "workspace view lookup forget and release preserve pinned node ownership" {
    var tables = try StateTables.init(std.testing.allocator, .{}, .{ .device = 2, .inode = 3 }, 10);
    defer tables.deinit();

    const node_id = try tables.acquireNode(.{ .device = 2, .inode = 4 }, 11, .file);
    try std.testing.expectEqual(node_id, try tables.retainNode(node_id));
    try std.testing.expectEqual(@as(u64, 2), tables.node(node_id).?.lookup_count);

    const handle_id = try tables.addHandle(node_id, 20, .file);
    try std.testing.expectEqual(@as(u64, 1), tables.node(node_id).?.open_count);
    try std.testing.expectEqual(@as(?i32, null), try tables.forgetNode(node_id, 2));
    try std.testing.expect(tables.node(node_id) != null);

    const released = try tables.releaseHandle(handle_id, .file);
    try std.testing.expectEqual(@as(i32, 20), released.fd);
    try std.testing.expectEqual(@as(i32, 11), released.unpinned_node_fd.?);
    try std.testing.expect(tables.node(node_id) == null);
    try std.testing.expectError(error.UnknownHandle, tables.releaseHandle(handle_id, .file));
}

test "workspace view enforces independent file and directory handle caps" {
    var tables = try StateTables.init(std.testing.allocator, .{
        .max_nodes = 3,
        .max_file_handles = 1,
        .max_dir_handles = 1,
    }, .{ .device = 1, .inode = 1 }, 5);
    defer tables.deinit();

    const file_node = try tables.acquireNode(.{ .device = 1, .inode = 2 }, 6, .file);
    const dir_node = try tables.acquireNode(.{ .device = 1, .inode = 3 }, 7, .directory);
    _ = try tables.addHandle(file_node, 8, .file);
    _ = try tables.addHandle(dir_node, 9, .directory);

    try std.testing.expectError(error.FileHandleCapacity, tables.addHandle(file_node, 10, .file));
    try std.testing.expectError(error.DirHandleCapacity, tables.addHandle(dir_node, 11, .directory));
}

test "workspace view distinguishes startup-tainted aliases from daemon-created hardlinks" {
    var tables = try StateTables.init(std.testing.allocator, .{}, .{ .device = 1, .inode = 1 }, 5);
    defer tables.deinit();
    const identity: Identity = .{ .device = 1, .inode = 9 };

    try tables.markSafeHardlink(identity);
    try std.testing.expect(tables.isSafeHardlink(identity));
    try std.testing.expect(!tables.isTainted(identity));
    try tables.markTainted(identity);
    try std.testing.expect(tables.isTainted(identity));
}

fn stateAllocationFailureProbe(allocator: std.mem.Allocator) !void {
    var tables = try StateTables.init(allocator, .{
        .max_nodes = 3,
        .max_file_handles = 2,
        .max_dir_handles = 2,
        .max_tainted_identities = 3,
    }, .{ .device = 1, .inode = 1 }, 5);
    defer tables.deinit();
    try tables.markTainted(.{ .device = 1, .inode = 99 });
    try tables.markSafeHardlink(.{ .device = 1, .inode = 2 });
    const node_id = try tables.acquireNode(.{ .device = 1, .inode = 2 }, 6, .file);
    _ = try tables.addHandle(node_id, 7, .file);
}

test "workspace view state cleans every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        stateAllocationFailureProbe,
        .{},
    );
}

test "workspace view entry replies advertise zero cache TTL" {
    var stat = std.mem.zeroes(std.os.linux.Statx);
    stat.mode = @intCast(mode_regular | 0o600);
    stat.ino = 41;
    stat.nlink = 1;
    var output: [256]u8 = undefined;
    const reply = try encodeEntry(&output, 7, 9, stat);
    const entry = std.mem.bytesToValue(uapi.EntryOut, reply[@sizeOf(uapi.OutHeader)..]);

    try std.testing.expectEqual(@as(u64, 0), entry.entry_valid);
    try std.testing.expectEqual(@as(u64, 0), entry.attr_valid);
    try std.testing.expectEqual(@as(u32, 0), entry.entry_valid_nsec);
    try std.testing.expectEqual(@as(u32, 0), entry.attr_valid_nsec);
}

test "Linux daemon dispatch surface compiles through the real handler table" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.getpid() == -1) {
        try serve(std.testing.allocator, -1, -1, -1, .{});
    }
    try std.testing.expectError(
        error.InvalidDescriptor,
        DaemonState.init(std.testing.allocator, -1, -1, .{}),
    );

    const tables = try StateTables.init(std.testing.allocator, .{}, .{ .device = 1, .inode = 1 }, -1);
    var state: DaemonState = .{
        .tables = tables,
        .fuse_fd = -1,
        .initialized = true,
    };
    const request: protocol.Request = .{
        .header = testRequestHeader(.lookup, 1),
        .opcode = .lookup,
        .body = ".env\x00",
    };
    var output: [64]u8 = undefined;
    const result = try state.dispatch(request, &output);
    try std.testing.expectEqual(@as(i32, -@as(i32, uapi.errno_noent)), switch (result) {
        .reply => |reply| std.mem.bytesToValue(uapi.OutHeader, reply).err,
        else => return error.UnexpectedDispatchResult,
    });
    state.tables.deinit();
}

test "Linux backing dispatcher reads safe files and hides secret hardlink aliases" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "safe.txt", .data = "safe-data" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SYNTHETIC_SECRET_CANARY" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env.example", .data = "template-data" });
    const link_result = std.os.linux.linkat(tmp.dir.handle, ".env", tmp.dir.handle, "secret-alias", 0);
    try std.testing.expectEqual(@as(?u16, null), errnoFromResult(link_result));
    try std.testing.expectEqual(
        @as(?u16, null),
        linuxSymlinkChild(tmp.dir.handle, "/etc/passwd", "external-link"),
    );
    try std.testing.expectEqual(
        @as(?u16, null),
        linuxMknodChild(tmp.dir.handle, "preexisting-fifo", mode_fifo | 0o600, 0),
    );

    const root_dup = try linuxDup(tmp.dir.handle);
    errdefer linuxClose(root_dup);
    const fuse_dup = try linuxDup(tmp.dir.handle);
    var state = try DaemonState.init(std.testing.allocator, fuse_dup, root_dup, .{
        .max_nodes = 16,
        .max_file_handles = 8,
        .max_dir_handles = 4,
        .max_tainted_identities = 16,
        .max_scan_entries = 32,
    });
    defer state.deinit();
    try state.scanTaintedTree();
    state.initialized = true;

    var output: [1024]u8 = undefined;
    const safe_lookup = try state.dispatch(.{
        .header = testRequestHeader(.lookup, uapi.root_id),
        .opcode = .lookup,
        .body = "safe.txt\x00",
    }, &output);
    const safe_reply = switch (safe_lookup) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    const entry = std.mem.bytesToValue(uapi.EntryOut, safe_reply[@sizeOf(uapi.OutHeader)..]);

    var open_input: uapi.OpenIn = .{ .flags = o_readonly, .unused = 0 };
    const open_result = try state.dispatch(.{
        .header = testRequestHeader(.open, entry.nodeid),
        .opcode = .open,
        .body = std.mem.asBytes(&open_input),
    }, &output);
    const open_reply = switch (open_result) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    const opened = std.mem.bytesToValue(uapi.OpenOut, open_reply[@sizeOf(uapi.OutHeader)..]);

    var read_input: uapi.ReadIn = .{
        .fh = opened.fh,
        .offset = 0,
        .size = 64,
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };
    const read_result = try state.dispatch(.{
        .header = testRequestHeader(.read, entry.nodeid),
        .opcode = .read,
        .body = std.mem.asBytes(&read_input),
    }, &output);
    const read_reply = switch (read_result) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    try std.testing.expectEqualStrings("safe-data", read_reply[@sizeOf(uapi.OutHeader)..]);

    var release_input: uapi.ReleaseIn = .{
        .fh = opened.fh,
        .flags = 0,
        .release_flags = 0,
        .lock_owner = 0,
    };
    _ = try state.dispatch(.{
        .header = testRequestHeader(.release, entry.nodeid),
        .opcode = .release,
        .body = std.mem.asBytes(&release_input),
    }, &output);

    for ([_][]const u8{ ".env\x00", "secret-alias\x00" }) |body| {
        const hidden = try state.dispatch(.{
            .header = testRequestHeader(.lookup, uapi.root_id),
            .opcode = .lookup,
            .body = body,
        }, &output);
        const reply = switch (hidden) {
            .reply => |reply| reply,
            else => return error.UnexpectedDispatchResult,
        };
        try std.testing.expectEqual(
            -@as(i32, uapi.errno_noent),
            std.mem.bytesToValue(uapi.OutHeader, reply).err,
        );
    }

    var request_body: [128]u8 = undefined;
    const create_input: uapi.CreateIn = .{
        .flags = o_create | o_truncate | o_readwrite,
        .mode = mode_regular | 0o600,
        .umask = 0,
        .padding = 0,
    };
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_noent),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.create, uapi.root_id),
            .opcode = .create,
            .body = testBodyWithNames(create_input, "secret-alias\x00", &request_body),
        }, &output)),
    );
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_noent),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.unlink, uapi.root_id),
            .opcode = .unlink,
            .body = "secret-alias\x00",
        }, &output)),
    );
    const rename_input: uapi.RenameIn = .{ .newdir = uapi.root_id };
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_noent),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.rename, uapi.root_id),
            .opcode = .rename,
            .body = testBodyWithNames(
                rename_input,
                "secret-alias\x00renamed-alias\x00",
                &request_body,
            ),
        }, &output)),
    );
    const secret_after_mutations = try tmp.dir.readFileAlloc(
        io,
        ".env",
        std.testing.allocator,
        .limited(128),
    );
    defer std.testing.allocator.free(secret_after_mutations);
    try std.testing.expectEqualStrings("SYNTHETIC_SECRET_CANARY", secret_after_mutations);

    const symlink_lookup = try state.dispatch(.{
        .header = testRequestHeader(.lookup, uapi.root_id),
        .opcode = .lookup,
        .body = "external-link\x00",
    }, &output);
    const symlink_reply = switch (symlink_lookup) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    const symlink_entry = std.mem.bytesToValue(uapi.EntryOut, symlink_reply[@sizeOf(uapi.OutHeader)..]);
    var access_input: uapi.AccessIn = .{ .mask = 4, .padding = 0 };
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_access),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.access, symlink_entry.nodeid),
            .opcode = .access,
            .body = std.mem.asBytes(&access_input),
        }, &output)),
    );
    const setattr_input = std.mem.zeroes(uapi.SetattrIn);
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_access),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.setattr, symlink_entry.nodeid),
            .opcode = .setattr,
            .body = std.mem.asBytes(&setattr_input),
        }, &output)),
    );
    const getxattr_input: uapi.GetxattrIn = .{ .size = 0, .padding = 0 };
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_access),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.getxattr, symlink_entry.nodeid),
            .opcode = .getxattr,
            .body = testBodyWithNames(getxattr_input, "user.test\x00", &request_body),
        }, &output)),
    );

    const fifo_lookup = try state.dispatch(.{
        .header = testRequestHeader(.lookup, uapi.root_id),
        .opcode = .lookup,
        .body = "preexisting-fifo\x00",
    }, &output);
    const fifo_reply = switch (fifo_lookup) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    const fifo_entry = std.mem.bytesToValue(uapi.EntryOut, fifo_reply[@sizeOf(uapi.OutHeader)..]);
    try std.testing.expectEqual(
        -@as(i32, uapi.errno_access),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.open, fifo_entry.nodeid),
            .opcode = .open,
            .body = std.mem.asBytes(&open_input),
        }, &output)),
    );
    const mknod_input: uapi.MknodIn = .{
        .mode = mode_fifo | 0o600,
        .rdev = 0,
        .umask = 0,
        .padding = 0,
    };
    try std.testing.expectEqual(
        -@as(i32, errno_opnotsupp),
        try testReplyErr(try state.dispatch(.{
            .header = testRequestHeader(.mknod, uapi.root_id),
            .opcode = .mknod,
            .body = testBodyWithNames(mknod_input, "new-fifo\x00", &request_body),
        }, &output)),
    );

    const template = try state.dispatch(.{
        .header = testRequestHeader(.lookup, uapi.root_id),
        .opcode = .lookup,
        .body = ".env.example\x00",
    }, &output);
    try std.testing.expectEqual(@as(i32, 0), switch (template) {
        .reply => |reply| std.mem.bytesToValue(uapi.OutHeader, reply).err,
        else => return error.UnexpectedDispatchResult,
    });
}

test "Linux startup scan rejects excessive depth without recursive stack growth" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b/c");

    const root_dup = try linuxDup(tmp.dir.handle);
    errdefer linuxClose(root_dup);
    const fuse_dup = try linuxDup(tmp.dir.handle);
    var state = try DaemonState.init(std.testing.allocator, fuse_dup, root_dup, .{
        .max_nodes = 8,
        .max_file_handles = 4,
        .max_dir_handles = 4,
        .max_tainted_identities = 8,
        .max_scan_entries = 16,
        .max_scan_depth = 3,
    });
    defer state.deinit();
    try std.testing.expectError(error.ScanDepthExceeded, state.scanTaintedTree());
}

test "Linux readdir crosses fully filtered backing batches before reporting EOF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SYNTHETIC_SECRET_CANARY" });

    var name_buffer: [64:0]u8 = undefined;
    for (0..1400) |index| {
        const name = try std.fmt.bufPrintZ(&name_buffer, "hidden-alias-{d:0>4}", .{index});
        const result = std.os.linux.linkat(tmp.dir.handle, ".env", tmp.dir.handle, name.ptr, 0);
        try std.testing.expectEqual(@as(?u16, null), errnoFromResult(result));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "zz-visible", .data = "visible" });

    const root_dup = try linuxDup(tmp.dir.handle);
    errdefer linuxClose(root_dup);
    const fuse_dup = try linuxDup(tmp.dir.handle);
    var state = try DaemonState.init(std.testing.allocator, fuse_dup, root_dup, .{
        .max_nodes = 16,
        .max_file_handles = 4,
        .max_dir_handles = 4,
        .max_tainted_identities = 8,
        .max_scan_entries = 2000,
        .max_scan_depth = 8,
    });
    defer state.deinit();
    try state.scanTaintedTree();
    state.initialized = true;

    var output: [4096]u8 = undefined;
    var open_input: uapi.OpenIn = .{ .flags = o_readonly, .unused = 0 };
    const open_result = try state.dispatch(.{
        .header = testRequestHeader(.opendir, uapi.root_id),
        .opcode = .opendir,
        .body = std.mem.asBytes(&open_input),
    }, &output);
    const open_reply = switch (open_result) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    const opened = std.mem.bytesToValue(uapi.OpenOut, open_reply[@sizeOf(uapi.OutHeader)..]);

    var read_input: uapi.ReadIn = .{
        .fh = opened.fh,
        .offset = 0,
        .size = output.len - @sizeOf(uapi.OutHeader),
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };
    const first_result = try state.dispatch(.{
        .header = testRequestHeader(.readdir, uapi.root_id),
        .opcode = .readdir,
        .body = std.mem.asBytes(&read_input),
    }, &output);
    const first_reply = switch (first_result) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    read_input.offset = (try testFindDirent(first_reply, "..")) orelse
        return error.MissingParentDirent;

    const second_result = try state.dispatch(.{
        .header = testRequestHeader(.readdir, uapi.root_id),
        .opcode = .readdir,
        .body = std.mem.asBytes(&read_input),
    }, &output);
    const second_reply = switch (second_result) {
        .reply => |reply| reply,
        else => return error.UnexpectedDispatchResult,
    };
    try std.testing.expect((try testFindDirent(second_reply, "zz-visible")) != null);
}
