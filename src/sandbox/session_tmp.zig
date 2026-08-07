//! Workspace session temp helpers for OS-FS attach.
//!
//! Preferred TMPDIR under attach is `{workspace}/.ryk-tmp` (covered by workspace RW).
//! Landlock parent expand and apply attach both need this path pre-created before
//! plan enumeration / child restrict. Kept free of apply / apply_posix imports so
//! those modules do not form a cycle over session-tmp alone.

const std = @import("std");

/// Relative session temp directory under the workspace (always covered by workspace RW).
/// Pre-created on the attach path so Landlock child-expand can PATH_BENEATH it.
pub const workspace_session_tmp_name = ".ryk-tmp";

/// Classic system temp path literal (`/tmp`).
///
/// **Not** an attach rewrite target under production defaults: `include_tmp` is false
/// so bare classic temp is not agent-writable. When `{workspace}/.ryk-tmp` cannot be
/// prepared, apply fails closed with `session_tmp_prepare_failed` rather than pointing
/// TMPDIR here (M-8 honesty). Kept as a named constant for grant comparisons / docs.
pub const classic_tmp_fallback = "/tmp";

/// Absolute path for the preferred attach TMPDIR under `workspace_root`.
/// Caller owns the returned slice.
pub fn workspaceSessionTmpPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_root, workspace_session_tmp_name });
}

/// Best-effort create `{workspace}/.ryk-tmp` so Landlock control-expand can
/// PATH_BENEATH a RW child even when the workspace only has control roots.
/// Must run **before** `buildChildLandlockPlan` / child attach enumeration.
/// Returns true when the preferred session path exists after the attempt.
pub fn ensureWorkspaceSessionTmp(workspace_root: []const u8) bool {
    if (workspace_root.len == 0) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const needed = workspace_root.len + 1 + workspace_session_tmp_name.len;
    if (needed > path_buf.len) return false;
    @memcpy(path_buf[0..workspace_root.len], workspace_root);
    path_buf[workspace_root.len] = '/';
    @memcpy(
        path_buf[workspace_root.len + 1 ..][0..workspace_session_tmp_name.len],
        workspace_session_tmp_name,
    );
    const preferred = path_buf[0..needed];

    var io_rt: std.Io.Threaded = .init_single_threaded;
    const io = io_rt.io();
    std.Io.Dir.cwd().createDirPath(io, preferred) catch {};
    if (std.Io.Dir.openDirAbsolute(io, preferred, .{ .follow_symlinks = false })) |dir_opened| {
        var dir = dir_opened;
        dir.close(io);
        return true;
    } else |_| {
        return false;
    }
}

test "ensureWorkspaceSessionTmp rejects a planted final symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.symLink(io, "outside", workspace_session_tmp_name, .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expect(!ensureWorkspaceSessionTmp(root));
}
