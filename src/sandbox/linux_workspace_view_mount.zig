//! Linux-only private workspace-view mount lifecycle.
//!
//! The production bootstrap opens the backing workspace before calling
//! `enterUserNamespace` and `enterPrivateMountNamespace`, mounts the ryk-owned
//! FUSE view over the original workspace path, then applies Landlock to the
//! overmounted view. The agent never receives either the backing-root or
//! `/dev/fuse` descriptor.

const std = @import("std");
const builtin = @import("builtin");

const fuse_source: [:0]const u8 = "ryk";
const fuse_filesystem_type: [:0]const u8 = "fuse.ryk";

pub const FailureReason = enum {
    openat2_unavailable,
    user_namespace_unavailable,
    mount_namespace_unavailable,
    private_mount_unavailable,
    fuse_unavailable,
    mount_failed,
    fuse_init_failed,
    landlock_attach_failed,
    bootstrap_protocol_failed,
    unmount_failed,
};

pub const LifecycleError = error{
    Unsupported,
    Openat2Unavailable,
    UserNamespaceUnavailable,
    MountNamespaceUnavailable,
    PrivateMountUnavailable,
    FuseUnavailable,
    MountFailed,
    FuseInitFailed,
    LandlockAttachFailed,
    BootstrapProtocolFailed,
    UnmountFailed,
};

pub fn reasonCode(reason: FailureReason) []const u8 {
    return switch (reason) {
        .openat2_unavailable => "workspace_view_openat2_unavailable",
        .user_namespace_unavailable => "workspace_view_userns_unavailable",
        .mount_namespace_unavailable => "workspace_view_mountns_unavailable",
        .private_mount_unavailable => "workspace_view_private_mount_unavailable",
        .fuse_unavailable => "workspace_view_fuse_unavailable",
        .mount_failed => "workspace_view_mount_failed",
        .fuse_init_failed => "workspace_view_fuse_init_failed",
        .landlock_attach_failed => "workspace_view_landlock_attach_failed",
        .bootstrap_protocol_failed => "workspace_view_bootstrap_protocol_failed",
        .unmount_failed => "workspace_view_unmount_failed",
    };
}

pub const MountOptions = struct {
    fuse_fd: i32,
    root_mode: u32,
    owner_uid: u32,
    owner_gid: u32,
};

pub fn formatMountOptions(
    buffer: []u8,
    options: MountOptions,
) error{ InvalidFuseFd, InvalidRootMode, NoSpaceLeft }![]const u8 {
    if (options.fuse_fd < 0) return error.InvalidFuseFd;
    if (options.root_mode & 0o170000 != 0o040000) return error.InvalidRootMode;
    return std.fmt.bufPrint(
        buffer,
        "fd={d},rootmode={o},user_id={d},group_id={d},default_permissions",
        .{ options.fuse_fd, options.root_mode, options.owner_uid, options.owner_gid },
    ) catch return error.NoSpaceLeft;
}

pub fn failureReason(err: LifecycleError) FailureReason {
    return switch (err) {
        error.Unsupported, error.Openat2Unavailable => .openat2_unavailable,
        error.UserNamespaceUnavailable => .user_namespace_unavailable,
        error.MountNamespaceUnavailable => .mount_namespace_unavailable,
        error.PrivateMountUnavailable => .private_mount_unavailable,
        error.FuseUnavailable => .fuse_unavailable,
        error.MountFailed => .mount_failed,
        error.FuseInitFailed => .fuse_init_failed,
        error.LandlockAttachFailed => .landlock_attach_failed,
        error.BootstrapProtocolFailed => .bootstrap_protocol_failed,
        error.UnmountFailed => .unmount_failed,
    };
}

pub const ReadyProof = struct {
    cookie: [32]u8,
    profile_hash: [32]u8,
    daemon_pid: i32,
    fuse_init_complete: bool,
    landlock_attached: bool,
};

pub fn validateReadyProof(
    proof: ReadyProof,
    expected_cookie: [32]u8,
    expected_profile_hash: [32]u8,
) bool {
    return proof.daemon_pid > 0 and
        proof.fuse_init_complete and
        proof.landlock_attached and
        std.crypto.timing_safe.eql([32]u8, proof.cookie, expected_cookie) and
        std.crypto.timing_safe.eql([32]u8, proof.profile_hash, expected_profile_hash);
}

pub const MountedView = struct {
    backing_root_fd: i32,
    fuse_fd: i32,

    /// Close both owned descriptors. The mounted view, if any, is unaffected.
    pub fn closeDescriptors(self: *MountedView) void {
        if (builtin.os.tag == .linux) {
            closeLinux(self.fuse_fd);
            closeLinux(self.backing_root_fd);
        }
        self.* = .{
            .backing_root_fd = -1,
            .fuse_fd = -1,
        };
    }
};

/// Complete the mount preparation sequence.
///
/// This mutates the current process's user and mount namespaces and therefore
/// must only run in a disposable bootstrap child. On any error after namespace
/// entry, the caller must exit rather than continue normal launcher logic.
pub fn prepareWorkspaceView(
    workspace_path: []const u8,
    root_mode: u32,
    outer_uid: u32,
    outer_gid: u32,
) LifecycleError!MountedView {
    if (builtin.os.tag != .linux) return error.Unsupported;
    return prepareWith(LinuxOps{}, workspace_path, root_mode, outer_uid, outer_gid);
}

/// Open the backing workspace before it is hidden by the FUSE overmount.
/// Caller owns the returned descriptor.
pub fn openBackingRoot(workspace_path: []const u8) LifecycleError!i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    return openBackingRootLinux(workspace_path);
}

/// Enter a user namespace and map namespace UID/GID 0 to the caller's IDs.
pub fn enterUserNamespace(outer_uid: u32, outer_gid: u32) LifecycleError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const ops = LinuxOps{};
    try ops.unshareUser();
    try ops.writeSetgroupsDeny();
    try ops.writeUidMap(outer_uid);
    try ops.writeGidMap(outer_gid);
}

/// Enter a mount namespace and recursively make every mount private.
pub fn enterPrivateMountNamespace() LifecycleError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const ops = LinuxOps{};
    try ops.unshareMount();
    try ops.makeRootPrivate();
}

/// Open `/dev/fuse`; caller owns the returned descriptor.
pub fn openFuseDevice() LifecycleError!i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    return openFuseLinux();
}

/// Mount the FUSE view over `workspace_path`.
pub fn mountWorkspaceView(
    workspace_path: []const u8,
    options: MountOptions,
) LifecycleError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    try mountViewLinux(workspace_path, options);
}

/// Lazily detach a workspace view without following a final symlink.
pub fn lazyUnmountWorkspaceView(workspace_path: []const u8) LifecycleError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    try lazyUnmountLinux(workspace_path);
}

fn prepareWith(
    ops: anytype,
    workspace_path: []const u8,
    root_mode: u32,
    owner_uid: u32,
    owner_gid: u32,
) LifecycleError!MountedView {
    const backing_root_fd = try ops.openBackingRoot(workspace_path);
    errdefer ops.close(backing_root_fd);

    try ops.unshareUser();
    try ops.writeSetgroupsDeny();
    try ops.writeUidMap(owner_uid);
    try ops.writeGidMap(owner_gid);
    try ops.unshareMount();
    try ops.makeRootPrivate();

    const fuse_fd = try ops.openFuse();
    errdefer ops.close(fuse_fd);
    try ops.mountView(workspace_path, .{
        .fuse_fd = fuse_fd,
        .root_mode = root_mode,
        // The single-ID maps make the caller namespace-local root.
        .owner_uid = 0,
        .owner_gid = 0,
    });

    return .{
        .backing_root_fd = backing_root_fd,
        .fuse_fd = fuse_fd,
    };
}

const LinuxOps = struct {
    fn openBackingRoot(_: LinuxOps, path: []const u8) LifecycleError!i32 {
        return openBackingRootLinux(path);
    }

    fn unshareUser(_: LinuxOps) LifecycleError!void {
        const linux = std.os.linux;
        const rc = linux.unshare(linux.CLONE.NEWUSER);
        if (linux.errno(rc) != .SUCCESS) return error.UserNamespaceUnavailable;
    }

    fn writeSetgroupsDeny(_: LinuxOps) LifecycleError!void {
        writeProcFileLinux("/proc/self/setgroups", "deny\n") catch return error.UserNamespaceUnavailable;
    }

    fn writeUidMap(_: LinuxOps, outer_uid: u32) LifecycleError!void {
        var buffer: [64]u8 = undefined;
        const mapping = std.fmt.bufPrint(&buffer, "0 {d} 1\n", .{outer_uid}) catch
            return error.UserNamespaceUnavailable;
        writeProcFileLinux("/proc/self/uid_map", mapping) catch return error.UserNamespaceUnavailable;
    }

    fn writeGidMap(_: LinuxOps, outer_gid: u32) LifecycleError!void {
        var buffer: [64]u8 = undefined;
        const mapping = std.fmt.bufPrint(&buffer, "0 {d} 1\n", .{outer_gid}) catch
            return error.UserNamespaceUnavailable;
        writeProcFileLinux("/proc/self/gid_map", mapping) catch return error.UserNamespaceUnavailable;
    }

    fn unshareMount(_: LinuxOps) LifecycleError!void {
        const linux = std.os.linux;
        const rc = linux.unshare(linux.CLONE.NEWNS);
        if (linux.errno(rc) != .SUCCESS) return error.MountNamespaceUnavailable;
    }

    fn makeRootPrivate(_: LinuxOps) LifecycleError!void {
        const linux = std.os.linux;
        const rc = linux.mount(null, "/", null, privateMountFlags(), 0);
        if (linux.errno(rc) != .SUCCESS) return error.PrivateMountUnavailable;
    }

    fn openFuse(_: LinuxOps) LifecycleError!i32 {
        return openFuseLinux();
    }

    fn mountView(_: LinuxOps, path: []const u8, options: MountOptions) LifecycleError!void {
        try mountViewLinux(path, options);
    }

    fn close(_: LinuxOps, fd: i32) void {
        closeLinux(fd);
    }
};

fn openBackingRootLinux(workspace_path: []const u8) LifecycleError!i32 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathZ(workspace_path, &path_buffer) orelse return error.Openat2Unavailable;
    const linux = std.os.linux;
    while (true) {
        const rc = linux.open(path.ptr, backingOpenFlags(), 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.Openat2Unavailable,
        }
    }
}

fn openFuseLinux() LifecycleError!i32 {
    const linux = std.os.linux;
    while (true) {
        const rc = linux.open("/dev/fuse", fuseOpenFlags(), 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.FuseUnavailable,
        }
    }
}

fn mountViewLinux(workspace_path: []const u8, options: MountOptions) LifecycleError!void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathZ(workspace_path, &path_buffer) orelse return error.MountFailed;

    var options_buffer: [256]u8 = undefined;
    const text = formatMountOptions(options_buffer[0 .. options_buffer.len - 1], options) catch
        return error.MountFailed;
    options_buffer[text.len] = 0;
    const options_z: [*:0]const u8 = options_buffer[0..text.len :0].ptr;

    const linux = std.os.linux;
    const rc = linux.mount(
        fuse_source.ptr,
        path.ptr,
        fuse_filesystem_type.ptr,
        fuseMountFlags(),
        @intFromPtr(options_z),
    );
    if (linux.errno(rc) != .SUCCESS) return error.MountFailed;
}

fn lazyUnmountLinux(workspace_path: []const u8) LifecycleError!void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathZ(workspace_path, &path_buffer) orelse return error.UnmountFailed;
    const linux = std.os.linux;
    const rc = linux.umount2(path.ptr, lazyUnmountFlags());
    if (linux.errno(rc) != .SUCCESS) return error.UnmountFailed;
}

const ProcWriteError = error{ OpenFailed, WriteFailed };

fn writeProcFileLinux(path: [*:0]const u8, contents: []const u8) ProcWriteError!void {
    const linux = std.os.linux;
    var fd: i32 = undefined;
    while (true) {
        const rc = linux.open(path, procWriteFlags(), 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                fd = @intCast(rc);
                break;
            },
            .INTR => continue,
            else => return error.OpenFailed,
        }
    }
    defer closeLinux(fd);

    var written: usize = 0;
    while (written < contents.len) {
        const rc = linux.write(fd, contents[written..].ptr, contents.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                if (rc > contents.len - written) return error.WriteFailed;
                written += rc;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn pathZ(path: []const u8, buffer: *[std.fs.max_path_bytes]u8) ?[:0]const u8 {
    if (path.len == 0 or path.len >= buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

fn backingOpenFlags() std.os.linux.O {
    return .{
        .PATH = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
}

fn fuseOpenFlags() std.os.linux.O {
    return .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    };
}

fn procWriteFlags() std.os.linux.O {
    return .{
        .ACCMODE = .WRONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
}

fn privateMountFlags() u32 {
    return std.os.linux.MS.REC | std.os.linux.MS.PRIVATE;
}

fn fuseMountFlags() u32 {
    return std.os.linux.MS.NODEV | std.os.linux.MS.NOSUID;
}

fn lazyUnmountFlags() u32 {
    return std.os.linux.MNT.DETACH | std.os.linux.UMOUNT_NOFOLLOW;
}

fn closeLinux(fd: i32) void {
    if (fd < 0) return;
    _ = std.os.linux.close(fd);
}

const TestEvent = enum {
    open_backing,
    unshare_user,
    setgroups_deny,
    write_uid_map,
    write_gid_map,
    unshare_mount,
    make_root_private,
    open_fuse,
    mount_view,
    close_backing,
    close_fuse,
};

const TestRecorder = struct {
    events: [16]TestEvent = undefined,
    len: usize = 0,
    fail_at: ?TestEvent = null,

    fn append(self: *TestRecorder, event: TestEvent) bool {
        self.events[self.len] = event;
        self.len += 1;
        return self.fail_at == event;
    }

    fn slice(self: *const TestRecorder) []const TestEvent {
        return self.events[0..self.len];
    }
};

const TestOps = struct {
    recorder: *TestRecorder,

    fn openBackingRoot(self: TestOps, path: []const u8) LifecycleError!i32 {
        if (!std.mem.eql(u8, "/workspace", path)) return error.BootstrapProtocolFailed;
        if (self.recorder.append(.open_backing)) return error.Openat2Unavailable;
        return 31;
    }

    fn unshareUser(self: TestOps) LifecycleError!void {
        if (self.recorder.append(.unshare_user)) return error.UserNamespaceUnavailable;
    }

    fn writeSetgroupsDeny(self: TestOps) LifecycleError!void {
        if (self.recorder.append(.setgroups_deny)) return error.UserNamespaceUnavailable;
    }

    fn writeUidMap(self: TestOps, uid: u32) LifecycleError!void {
        if (uid != 1001) return error.BootstrapProtocolFailed;
        if (self.recorder.append(.write_uid_map)) return error.UserNamespaceUnavailable;
    }

    fn writeGidMap(self: TestOps, gid: u32) LifecycleError!void {
        if (gid != 1002) return error.BootstrapProtocolFailed;
        if (self.recorder.append(.write_gid_map)) return error.UserNamespaceUnavailable;
    }

    fn unshareMount(self: TestOps) LifecycleError!void {
        if (self.recorder.append(.unshare_mount)) return error.MountNamespaceUnavailable;
    }

    fn makeRootPrivate(self: TestOps) LifecycleError!void {
        if (self.recorder.append(.make_root_private)) return error.PrivateMountUnavailable;
    }

    fn openFuse(self: TestOps) LifecycleError!i32 {
        if (self.recorder.append(.open_fuse)) return error.FuseUnavailable;
        return 41;
    }

    fn mountView(self: TestOps, path: []const u8, options: MountOptions) LifecycleError!void {
        if (!std.mem.eql(u8, "/workspace", path) or
            options.fuse_fd != 41 or
            options.root_mode != 0o40750 or
            options.owner_uid != 0 or
            options.owner_gid != 0)
        {
            return error.BootstrapProtocolFailed;
        }
        if (self.recorder.append(.mount_view)) return error.MountFailed;
    }

    fn close(self: TestOps, fd: i32) void {
        _ = self.recorder.append(if (fd == 31) .close_backing else .close_fuse);
    }
};

test "workspace view reason codes are stable and non-secret" {
    try std.testing.expectEqualStrings(
        "workspace_view_userns_unavailable",
        reasonCode(.user_namespace_unavailable),
    );
    try std.testing.expectEqualStrings(
        "workspace_view_fuse_init_failed",
        reasonCode(.fuse_init_failed),
    );
    try std.testing.expectEqualStrings(
        "workspace_view_unmount_failed",
        reasonCode(.unmount_failed),
    );
    try std.testing.expectEqual(FailureReason.unmount_failed, failureReason(error.UnmountFailed));
}

test "FUSE mount options are bounded and omit unsafe cache and bypass flags" {
    var buffer: [256]u8 = undefined;
    const options = try formatMountOptions(&buffer, .{
        .fuse_fd = 17,
        .root_mode = 0o40750,
        .owner_uid = 501,
        .owner_gid = 20,
    });

    try std.testing.expectEqualStrings(
        "fd=17,rootmode=40750,user_id=501,group_id=20,default_permissions",
        options,
    );
    try std.testing.expect(std.mem.indexOf(u8, options, "allow_other") == null);
    try std.testing.expect(std.mem.indexOf(u8, options, "writeback") == null);
    try std.testing.expect(std.mem.indexOf(u8, options, "passthrough") == null);
    try std.testing.expectError(error.InvalidFuseFd, formatMountOptions(&buffer, .{
        .fuse_fd = -1,
        .root_mode = 0o40750,
        .owner_uid = 501,
        .owner_gid = 20,
    }));
    try std.testing.expectError(error.InvalidRootMode, formatMountOptions(&buffer, .{
        .fuse_fd = 17,
        .root_mode = 0o100750,
        .owner_uid = 501,
        .owner_gid = 20,
    }));
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, formatMountOptions(&tiny, .{
        .fuse_fd = 17,
        .root_mode = 0o40750,
        .owner_uid = 501,
        .owner_gid = 20,
    }));
}

test "workspace view proof requires cookie hash init landlock and positive daemon pid" {
    const cookie = [_]u8{0xA5} ** 32;
    const profile_hash = [_]u8{0x5A} ** 32;

    try std.testing.expect(validateReadyProof(.{
        .cookie = cookie,
        .profile_hash = profile_hash,
        .daemon_pid = 42,
        .fuse_init_complete = true,
        .landlock_attached = true,
    }, cookie, profile_hash));

    var wrong_cookie = cookie;
    wrong_cookie[0] ^= 1;
    try std.testing.expect(!validateReadyProof(.{
        .cookie = wrong_cookie,
        .profile_hash = profile_hash,
        .daemon_pid = 42,
        .fuse_init_complete = true,
        .landlock_attached = true,
    }, cookie, profile_hash));
    try std.testing.expect(!validateReadyProof(.{
        .cookie = cookie,
        .profile_hash = profile_hash,
        .daemon_pid = 42,
        .fuse_init_complete = false,
        .landlock_attached = true,
    }, cookie, profile_hash));
    try std.testing.expect(!validateReadyProof(.{
        .cookie = cookie,
        .profile_hash = profile_hash,
        .daemon_pid = 0,
        .fuse_init_complete = true,
        .landlock_attached = true,
    }, cookie, profile_hash));
}

test "workspace view setup sequence opens backing before namespaces and mounts last" {
    var recorder: TestRecorder = .{};
    const view = try prepareWith(TestOps{ .recorder = &recorder }, "/workspace", 0o40750, 1001, 1002);

    try std.testing.expectEqual(@as(i32, 31), view.backing_root_fd);
    try std.testing.expectEqual(@as(i32, 41), view.fuse_fd);
    try std.testing.expectEqualSlices(TestEvent, &.{
        .open_backing,
        .unshare_user,
        .setgroups_deny,
        .write_uid_map,
        .write_gid_map,
        .unshare_mount,
        .make_root_private,
        .open_fuse,
        .mount_view,
    }, recorder.slice());
}

test "workspace view setup fails closed and closes acquired descriptors" {
    var userns_failure: TestRecorder = .{ .fail_at = .write_gid_map };
    try std.testing.expectError(
        error.UserNamespaceUnavailable,
        prepareWith(TestOps{ .recorder = &userns_failure }, "/workspace", 0o40750, 1001, 1002),
    );
    try std.testing.expectEqualSlices(TestEvent, &.{
        .open_backing,
        .unshare_user,
        .setgroups_deny,
        .write_uid_map,
        .write_gid_map,
        .close_backing,
    }, userns_failure.slice());

    var mount_failure: TestRecorder = .{ .fail_at = .mount_view };
    try std.testing.expectError(
        error.MountFailed,
        prepareWith(TestOps{ .recorder = &mount_failure }, "/workspace", 0o40750, 1001, 1002),
    );
    try std.testing.expectEqualSlices(TestEvent, &.{
        .open_backing,
        .unshare_user,
        .setgroups_deny,
        .write_uid_map,
        .write_gid_map,
        .unshare_mount,
        .make_root_private,
        .open_fuse,
        .mount_view,
        .close_fuse,
        .close_backing,
    }, mount_failure.slice());
}

test "workspace view setup maps every lifecycle failure without continuing" {
    const cases = [_]struct {
        event: TestEvent,
        expected: LifecycleError,
        closes_fuse: bool,
    }{
        .{ .event = .open_backing, .expected = error.Openat2Unavailable, .closes_fuse = false },
        .{ .event = .unshare_user, .expected = error.UserNamespaceUnavailable, .closes_fuse = false },
        .{ .event = .setgroups_deny, .expected = error.UserNamespaceUnavailable, .closes_fuse = false },
        .{ .event = .write_uid_map, .expected = error.UserNamespaceUnavailable, .closes_fuse = false },
        .{ .event = .write_gid_map, .expected = error.UserNamespaceUnavailable, .closes_fuse = false },
        .{ .event = .unshare_mount, .expected = error.MountNamespaceUnavailable, .closes_fuse = false },
        .{ .event = .make_root_private, .expected = error.PrivateMountUnavailable, .closes_fuse = false },
        .{ .event = .open_fuse, .expected = error.FuseUnavailable, .closes_fuse = false },
        .{ .event = .mount_view, .expected = error.MountFailed, .closes_fuse = true },
    };

    for (cases) |case| {
        var recorder: TestRecorder = .{ .fail_at = case.event };
        const result = prepareWith(TestOps{ .recorder = &recorder }, "/workspace", 0o40750, 1001, 1002);
        try std.testing.expectError(case.expected, result);

        if (case.event == .open_backing) {
            try std.testing.expectEqualSlices(TestEvent, &.{.open_backing}, recorder.slice());
            continue;
        }
        try std.testing.expectEqual(TestEvent.close_backing, recorder.slice()[recorder.len - 1]);
        if (case.closes_fuse) {
            try std.testing.expectEqual(TestEvent.close_fuse, recorder.slice()[recorder.len - 2]);
        }
    }
}

test "workspace view Linux flags are exact and omit privilege bypasses" {
    try std.testing.expectEqualStrings("ryk", fuse_source);
    try std.testing.expectEqualStrings("fuse.ryk", fuse_filesystem_type);

    const backing = backingOpenFlags();
    try std.testing.expect(backing.PATH);
    try std.testing.expect(backing.DIRECTORY);
    try std.testing.expect(backing.NOFOLLOW);
    try std.testing.expect(backing.CLOEXEC);
    try std.testing.expectEqual(std.posix.ACCMODE.RDONLY, backing.ACCMODE);

    const fuse = fuseOpenFlags();
    try std.testing.expectEqual(std.posix.ACCMODE.RDWR, fuse.ACCMODE);
    try std.testing.expect(fuse.CLOEXEC);
    try std.testing.expect(!fuse.PATH);

    try std.testing.expectEqual(
        @as(u32, std.os.linux.MS.REC | std.os.linux.MS.PRIVATE),
        privateMountFlags(),
    );
    try std.testing.expectEqual(
        @as(u32, std.os.linux.MS.NODEV | std.os.linux.MS.NOSUID),
        fuseMountFlags(),
    );
    try std.testing.expectEqual(
        @as(u32, std.os.linux.MNT.DETACH | std.os.linux.UMOUNT_NOFOLLOW),
        lazyUnmountFlags(),
    );
}

test "workspace view production helpers are compile referenced and target gated" {
    std.testing.refAllDecls(@This());
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(error.Unsupported, openBackingRoot("/workspace"));
        try std.testing.expectError(error.Unsupported, enterUserNamespace(501, 20));
        try std.testing.expectError(error.Unsupported, enterPrivateMountNamespace());
        try std.testing.expectError(error.Unsupported, openFuseDevice());
        try std.testing.expectError(error.Unsupported, mountWorkspaceView("/workspace", .{
            .fuse_fd = 1,
            .root_mode = 0o40750,
            .owner_uid = 0,
            .owner_gid = 0,
        }));
        try std.testing.expectError(error.Unsupported, lazyUnmountWorkspaceView("/workspace"));
    }
}
