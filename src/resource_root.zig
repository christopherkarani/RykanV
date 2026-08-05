const std = @import("std");
const env_util = @import("env_util.zig");

pub const ResolveOptions = struct {
    workspace_root: []const u8,
    resource_root_override: ?[]const u8 = null,
};

pub fn resolveResourcePath(io: std.Io, allocator: std.mem.Allocator, options: ResolveOptions, relative_path: []const u8) ![]u8 {
    const workspace_candidate = try std.fs.path.join(allocator, &.{ options.workspace_root, relative_path });
    if (pathExists(io, workspace_candidate)) return workspace_candidate;
    allocator.free(workspace_candidate);

    if (options.resource_root_override) |resource_root| {
        const candidate = try std.fs.path.join(allocator, &.{ resource_root, relative_path });
        if (pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
    } else {
        var env_map = env_util.createProcessMap(allocator) catch return error.ResourceNotFound;
        defer env_map.deinit();
        // RYK_RESOURCE_ROOT only (hard-cut).
        if (try env_util.getOwnedBrand(&env_map, allocator, "RESOURCE_ROOT")) |resource_root| {
            defer allocator.free(resource_root);
            const candidate = try std.fs.path.join(allocator, &.{ resource_root, relative_path });
            if (pathExists(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    const exe_path = std.process.executablePathAlloc(io, allocator) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.ResourceNotFound,
        else => return err,
    };
    defer allocator.free(exe_path);
    if (std.fs.path.dirname(exe_path)) |exe_dir| {
        const candidate = try std.fs.path.join(allocator, &.{ exe_dir, "..", relative_path });
        if (pathExists(io, candidate)) return candidate;
        allocator.free(candidate);

        const source_build_candidate = try std.fs.path.join(allocator, &.{ exe_dir, "..", "..", relative_path });
        if (pathExists(io, source_build_candidate)) return source_build_candidate;
        allocator.free(source_build_candidate);

        // Strong improvement for non-interactive / container / CI usage:
        // The standard layout produced by our curl|sh installer (and recommended
        // by doctor/Homebrew) places the binary at $PREFIX/bin/ryk and assets at
        // $PREFIX/share/ryk/current. Auto-discover this when no explicit
        // RYK_RESOURCE_ROOT is set. This makes `sh -c 'ryk redteam --ci'` work
        // out of the box after a fresh install in many environments.
        if (std.fs.path.dirname(exe_dir)) |prefix_dir| {
            const packaged = try std.fs.path.join(allocator, &.{ prefix_dir, "share", "ryk", "current", relative_path });
            if (pathExists(io, packaged)) return packaged;
            allocator.free(packaged);
        }
    }

    return error.ResourceNotFound;
}

pub fn resourcePathExists(io: std.Io, allocator: std.mem.Allocator, options: ResolveOptions, relative_path: []const u8) bool {
    const resolved = resolveResourcePath(io, allocator, options, relative_path) catch return false;
    allocator.free(resolved);
    return true;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "resource resolver falls back to explicit resource root" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "resources/fixtures");

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace_root);
    const resource_root = try tmp.dir.realPathFileAlloc(std.testing.io, "resources", std.testing.allocator);
    defer std.testing.allocator.free(resource_root);

    const resolved = try resolveResourcePath(io, std.testing.allocator, .{
        .workspace_root = workspace_root,
        .resource_root_override = resource_root,
    }, "fixtures");
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.endsWith(u8, resolved, "resources/fixtures"));
}

test "resource resolver prefers workspace resources" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace/fixtures");
    try tmp.dir.createDirPath(std.testing.io, "resources/fixtures");

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace_root);
    const resource_root = try tmp.dir.realPathFileAlloc(std.testing.io, "resources", std.testing.allocator);
    defer std.testing.allocator.free(resource_root);

    const resolved = try resolveResourcePath(io, std.testing.allocator, .{
        .workspace_root = workspace_root,
        .resource_root_override = resource_root,
    }, "fixtures");
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.indexOf(u8, resolved, "workspace") != null);
}

// Test for the packaged ~/.local layout recommendation (Tier-0 DX).
// Simulates RYK_RESOURCE_ROOT or the auto-discovered $PREFIX/share/ryk/current
// that install.sh, doctor, and Homebrew all converge on. This path must resolve
// fixtures/integrations for non-interactive `sh -c 'ryk redteam --ci'` flows.
test "resource resolver supports packaged share/ryk/current layout via override" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Simulate $PREFIX/share/ryk/current/fixtures (the exact layout from improved install.sh)
    try tmp.dir.createDirPath(std.testing.io, "share/ryk/current/fixtures/redteam");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "share/ryk/current/fixtures/redteam/sample.txt", .data = "test" });

    const packaged_root = try tmp.dir.realPathFileAlloc(std.testing.io, "share/ryk/current", std.testing.allocator);
    defer std.testing.allocator.free(packaged_root);

    // No workspace, no explicit override in options (simulates clean env after install)
    // but we use override here to stand in for the auto-discovered sibling from exe_dir
    const resolved = try resolveResourcePath(io, std.testing.allocator, .{
        .workspace_root = "/nonexistent/workspace",
        .resource_root_override = packaged_root,
    }, "fixtures/redteam/sample.txt");
    defer std.testing.allocator.free(resolved);

    try std.testing.expect(std.mem.indexOf(u8, resolved, "share/ryk/current") != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "sample.txt"));
}
