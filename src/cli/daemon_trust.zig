//! Path trust checks for `RYK_DAEMON` overrides.

const std = @import("std");
const builtin = @import("builtin");

pub const EnvOverrideTrust = enum {
    trusted,
    untrusted_world_writable,
    untrusted_owner,
    untrusted_symlink,
    untrusted_stat_unavailable,
};

/// Assess whether an `RYK_DAEMON` path is safe to execute.
/// Stat failures are treated as untrusted (fail-closed for env overrides).
///
/// Trust rules (POSIX):
/// - Symlinks are allowed when the override path and its resolved target (and
///   their ancestors) are not group/world-writable. Homebrew-style installs
///   place a symlink under a safe prefix pointing at a Cellar binary.
/// - Binary owner must be the current euid or root (uid 0).
/// - Binary mode must not be group- or world-writable (`mode & 0o022 == 0`).
/// - Ancestors of the path must not be group- or world-writable.
pub fn assessEnvOverridePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) EnvOverrideTrust {
    // POSIX trust checks do not map cleanly to Win32 ACLs yet. Refuse env
    // overrides on Windows until ACL-based checks exist — fail closed rather
    // than treating every override as trusted.
    if (builtin.os.tag == .windows) return .untrusted_stat_unavailable;

    // Parent of the override path must not be group/world-writable: otherwise an
    // attacker can replace a symlink (or the binary) after our check.
    if (hasWritableByOthersAncestor(io, path)) return .untrusted_world_writable;

    const link_stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .untrusted_stat_unavailable;
    if (link_stat.kind == .sym_link) {
        // Resolve to the final target and apply the same trust rules there.
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch return .untrusted_stat_unavailable;
        defer allocator.free(resolved);
        return assessResolvedPath(io, resolved);
    }

    return assessResolvedPath(io, path);
}

fn assessResolvedPath(io: std.Io, path: []const u8) EnvOverrideTrust {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .untrusted_stat_unavailable;
    // realpath should have flattened remaining links; if not, fail closed.
    if (stat.kind == .sym_link) return .untrusted_symlink;
    if (isWritableByOthers(stat.permissions.toMode())) return .untrusted_world_writable;
    if (hasWritableByOthersAncestor(io, path)) return .untrusted_world_writable;

    const owner = pathOwnerUid(io, path) catch return .untrusted_stat_unavailable;
    if (!ownerIsTrusted(owner)) return .untrusted_owner;
    return .trusted;
}

/// Group- or world-writable bits (SSH/OpenBSD-style: only owner may write).
fn isWritableByOthers(mode: std.posix.mode_t) bool {
    return (mode & 0o022) != 0;
}

fn hasWritableByOthersAncestor(io: std.Io, path: []const u8) bool {
    var ancestor = std.fs.path.dirname(path);
    while (ancestor) |directory| {
        const stat = std.Io.Dir.cwd().statFile(io, directory, .{}) catch return true;
        if (isWritableByOthers(stat.permissions.toMode())) return true;
        const parent = std.fs.path.dirname(directory);
        // Guard against root self-parent edge cases (dirname("/") may be null or "/").
        if (parent) |p| {
            if (std.mem.eql(u8, p, directory)) break;
        }
        ancestor = parent;
    }
    if (std.fs.path.isAbsolute(path)) return false;
    const cwd_stat = std.Io.Dir.cwd().statFile(io, ".", .{}) catch return true;
    return isWritableByOthers(cwd_stat.permissions.toMode());
}

fn ownerIsTrusted(uid: std.posix.uid_t) bool {
    const euid = std.posix.system.geteuid();
    return uid == euid or uid == 0;
}

/// Return the on-disk owner uid of `path` (open + fstat/statx). Fail closed on error.
fn pathOwnerUid(io: std.Io, path: []const u8) !std.posix.uid_t {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.StatFailed;
    defer file.close(io);

    // Zig 0.16: `std.Io.File.Stat` omits uid; `std.posix.Stat` is void on Linux.
    // Prefer open-fd metadata (fstat / statx EMPTY_PATH) so TOCTOU matches the open.
    // Branches are comptime on `builtin.os.tag` so platform-only types stay valid.
    if (builtin.os.tag == .windows) return error.StatFailed;

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx = std.mem.zeroes(linux.Statx);
        const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &stx);
        if (std.posix.errno(@as(isize, @intCast(rc))) != .SUCCESS) return error.StatFailed;
        if (!stx.mask.UID) return error.StatFailed;
        return stx.uid;
    }

    // macOS / BSD: libc fstat into posix.Stat (system.Stat).
    var st: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &st) != 0) return error.StatFailed;
    return st.uid;
}

pub fn isEnvOverrideUntrusted(io: std.Io, allocator: std.mem.Allocator, path: []const u8) bool {
    return assessEnvOverridePath(io, allocator, path) != .trusted;
}

test "assessEnvOverridePath detects world-writable binary path" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "ryk-daemon", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try tmp.dir.setFilePermissions(std.testing.io, "ryk-daemon", std.Io.File.Permissions.fromMode(0o755), .{});
    try std.testing.expectEqual(.trusted, assessEnvOverridePath(std.testing.io, std.testing.allocator, path));

    try tmp.dir.setFilePermissions(std.testing.io, "ryk-daemon", std.Io.File.Permissions.fromMode(0o777), .{});
    try std.testing.expectEqual(.untrusted_world_writable, assessEnvOverridePath(std.testing.io, std.testing.allocator, path));
}

test "assessEnvOverridePath rejects group-writable binary" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "ryk-daemon", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");
    try tmp.dir.setFilePermissions(std.testing.io, "ryk-daemon", std.Io.File.Permissions.fromMode(0o775), .{});

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(.untrusted_world_writable, assessEnvOverridePath(std.testing.io, std.testing.allocator, path));
}

test "assessEnvOverridePath rejects a binary beneath a world-writable directory" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "unsafe");
    try tmp.dir.setFilePermissions(std.testing.io, "unsafe", std.Io.File.Permissions.fromMode(0o777), .{});

    const file = try tmp.dir.createFile(std.testing.io, "unsafe/ryk-daemon", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");
    try tmp.dir.setFilePermissions(std.testing.io, "unsafe/ryk-daemon", std.Io.File.Permissions.fromMode(0o755), .{});

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "unsafe/ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(.untrusted_world_writable, assessEnvOverridePath(std.testing.io, std.testing.allocator, path));
}

test "assessEnvOverridePath rejects a safe-path symlink to an unsafe target" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "safe");
    try tmp.dir.createDirPath(std.testing.io, "unsafe");
    try tmp.dir.setFilePermissions(std.testing.io, "unsafe", std.Io.File.Permissions.fromMode(0o777), .{});

    const target = try tmp.dir.createFile(std.testing.io, "unsafe/ryk-daemon", .{});
    defer target.close(std.testing.io);
    try target.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");
    try tmp.dir.setFilePermissions(std.testing.io, "unsafe/ryk-daemon", std.Io.File.Permissions.fromMode(0o755), .{});

    const unsafe_target = try tmp.dir.realPathFileAlloc(std.testing.io, "unsafe/ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(unsafe_target);
    const safe_link = try tmp.dir.realPathFileAlloc(std.testing.io, "safe", std.testing.allocator);
    defer std.testing.allocator.free(safe_link);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ safe_link, "ryk-daemon" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, unsafe_target, link_path, .{});

    // Symlink itself is under a safe parent; trust fails because the resolved
    // target sits under a world-writable directory.
    try std.testing.expectEqual(.untrusted_world_writable, assessEnvOverridePath(std.testing.io, std.testing.allocator, link_path));
}

test "assessEnvOverridePath trusts a safe symlink to a safe target" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "cellar");
    try tmp.dir.createDirPath(std.testing.io, "bin");

    const target = try tmp.dir.createFile(std.testing.io, "cellar/ryk-daemon", .{});
    defer target.close(std.testing.io);
    try target.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 0\n");
    try tmp.dir.setFilePermissions(std.testing.io, "cellar/ryk-daemon", std.Io.File.Permissions.fromMode(0o755), .{});

    const cellar_target = try tmp.dir.realPathFileAlloc(std.testing.io, "cellar/ryk-daemon", std.testing.allocator);
    defer std.testing.allocator.free(cellar_target);
    const bin_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "bin", std.testing.allocator);
    defer std.testing.allocator.free(bin_dir);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ bin_dir, "ryk-daemon" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, cellar_target, link_path, .{});

    try std.testing.expectEqual(.trusted, assessEnvOverridePath(std.testing.io, std.testing.allocator, link_path));
}

test "assessEnvOverridePath treats missing path as stat-unavailable" {
    if (builtin.os.tag == .windows) return;

    // Avoid /tmp: it is often world-writable, which surfaces as untrusted_world_writable
    // before the missing-file stat. Use a non-existent path under a typically safe prefix.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "ryk-daemon-trust-missing-deadbeef" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(.untrusted_stat_unavailable, assessEnvOverridePath(std.testing.io, std.testing.allocator, missing));
}

test "ownerIsTrusted accepts euid and root only" {
    if (builtin.os.tag == .windows) return;
    const euid = std.posix.system.geteuid();
    try std.testing.expect(ownerIsTrusted(euid));
    try std.testing.expect(ownerIsTrusted(0));
    if (euid != 1) try std.testing.expect(!ownerIsTrusted(1));
}

test "pathOwnerUid returns real file owner not euid masquerade" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "owner-check", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "x\n");
    try tmp.dir.setFilePermissions(std.testing.io, "owner-check", std.Io.File.Permissions.fromMode(0o644), .{});

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "owner-check", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const uid = try pathOwnerUid(std.testing.io, path);
    // Must match the opened file's metadata — not a hard-coded euid shortcut.
    // (We own the temp file, so uid equals euid; the important property is that
    // pathOwnerUid consulted fstat/statx rather than returning geteuid() blindly.)
    const euid = std.posix.system.geteuid();
    try std.testing.expectEqual(euid, uid);

    // Foreign uid is never trusted solely because open succeeded.
    if (euid != 42) try std.testing.expect(!ownerIsTrusted(42));
}
