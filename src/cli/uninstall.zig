const std = @import("std");
const builtin = @import("builtin");

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const plugin = @import("plugin.zig");
const disable = @import("disable.zig");
const danger_confirmation = @import("danger_confirmation.zig");
const suggestions = @import("suggestions.zig");

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var yes = false;
    var plugins_only = false;
    var keep_config = false;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "uninstall");
            return exit_codes.success;
        }
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plugins-only")) {
            plugins_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-config")) {
            keep_config = true;
            continue;
        }
        try suggestions.writeUnknownOption(stderr, "ryk uninstall", arg, &.{ "--plugins-only", "--keep-config", "--yes", "--help" }, "uninstall");
        return exit_codes.usage;
    }

    if (!yes) {
        const stdin = std.Io.File.stdin();
        const prompt = if (plugins_only)
            "Remove all ryk plugins from host agents?"
        else if (keep_config)
            "Uninstall ryk (keep config files)? This removes plugins and the binary."
        else
            "Fully uninstall ryk (plugins, binary, and config)?";
        const decision = danger_confirmation.decide(io, stdout, prompt, false, try stdin.isTty(io), null) catch |err| {
            try stderr.print("ryk uninstall: confirmation failed: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        };
        switch (decision) {
            .proceed => {},
            .cancelled => {
                try stdout.writeAll("canceled\n");
                return exit_codes.success;
            },
            .requires_yes => {
                try stderr.writeAll("ryk uninstall: requires --yes or run interactively.\n");
                return exit_codes.usage;
            },
        }
    }

    try stdout.writeAll("ryk Uninstall\n\n");

    // 1. Disable / remove all plugins
    try stdout.writeAll("→ Step 1 of 3: Removing plugins...\n");
    try stdout.writeAll("(OpenClaw and Hermes use host CLIs with 10s timeout + direct fallback)\n");
    const all_disabled = try disablePlugins(io, allocator, stdout);
    try stdout.writeAll("  ✓ Step 1 done\n");

    if (plugins_only) {
        try stdout.writeAll("\n✅ Plugins removed. ryk binary and config remain in place.\n");
        try stdout.writeAll("To fully uninstall later, run: ryk uninstall --yes\n");
        return exit_codes.success;
    }

    // 2. Remove installed binaries and runtime assets
    try stdout.writeAll("\n→ Step 2 of 3: Removing ryk installation...\n");
    const binary_removed = try removeBinary(io, allocator, stdout);
    _ = try removeInstallerRuntimes(io, allocator, stdout);
    _ = try removeInstallerProfileEntries(io, allocator, stdout);
    try stdout.writeAll("  ✓ Step 2 done\n");

    // 3. Remove config and data directories
    if (!keep_config) {
        try stdout.writeAll("\n→ Step 3 of 3: Removing config and data...\n");
        try removeConfigAndData(io, allocator, stdout);
        try stdout.writeAll("  ✓ Step 3 done\n");
    } else {
        try stdout.writeAll("\n→ Step 3 of 3: Skipping config removal (--keep-config)\n");
        try stdout.writeAll("  ✓ Step 3 done\n");
    }

    try stdout.writeAll("\n✅ Uninstall complete.\n");
    if (!keep_config) {
        try stdout.writeAll("User config removed: ~/.config/orca/\n");
    }

    if (!all_disabled and !binary_removed) {
        try stdout.writeAll("\nNote: no ryk plugins or binary were found.\n");
    }

    try stdout.writeAll(
        \\
        \\Manual cleanup may still be needed:
        \\  - Remove ~/.local/bin/orca from your PATH if it was added by the installer.
        \\  - Review and remove any local .orca/ directories in project workspaces.
        \\
    );
    return exit_codes.success;
}

// ---------------------------------------------------------------------------
// Plugin removal (delegates to disable.zig)
// ---------------------------------------------------------------------------

fn disablePlugins(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    var any_action = false;

    any_action = try disable.disableOpenCode(io, allocator, stdout) or any_action;
    any_action = try disable.disableOpenClaw(io, allocator, stdout) or any_action;
    any_action = try disable.disableHermes(io, allocator, stdout) or any_action;
    any_action = try disable.disableCodex(io, allocator, stdout) or any_action;
    any_action = try disable.disableClaude(io, allocator, stdout) or any_action;

    return any_action;
}

// ---------------------------------------------------------------------------
// Binary removal — only known safe locations, no PATH traversal
// ---------------------------------------------------------------------------

fn removeBinary(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    const self_exe = std.process.executablePathAlloc(io, allocator) catch |err| {
        try stdout.print("  could not determine self path: {s}\n", .{@errorName(err)});
        return false;
    };
    defer allocator.free(self_exe);

    const removed_any = try removeInstalledBinariesAt(io, allocator, self_exe, stdout);

    if (!removed_any) {
        try stdout.writeAll("  no ryk binary found in known locations\n");
    }
    return removed_any;
}

fn removeInstalledBinariesAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    cli_path: []const u8,
    stdout: anytype,
) !bool {
    if (!plugin.fileExistsAbsolute(io, cli_path)) return false;
    const bin_dir = std.fs.path.dirname(cli_path) orelse return false;
    const daemon_name = daemonBinaryName(builtin.os.tag);
    const daemon_path = try std.fs.path.join(allocator, &.{ bin_dir, daemon_name });
    defer allocator.free(daemon_path);

    var removed_any = false;
    for ([_][]const u8{ cli_path, daemon_path }) |path| {
        if (!plugin.fileExistsAbsolute(io, path)) continue;
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            try stdout.print("  binary: failed to remove {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        try stdout.print("  removed: {s}\n", .{path});
        removed_any = true;
    }
    return removed_any;
}

fn daemonBinaryName(os: std.Target.Os.Tag) []const u8 {
    return if (os == .windows) "orca-daemon.exe" else "orca-daemon";
}

fn removeInstallerRuntimes(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    var removed_any = false;

    {
        const env_util = @import("../env_util.zig");
        if (env_util.getenvBrand("RESOURCE_ROOT")) |resource_root| {
            removed_any = try removeInstallerRuntimeAt(io, allocator, std.mem.span(resource_root), stdout) or removed_any;
        }
    }

    if (std.c.getenv("HOME")) |home| {
        const current = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".local", "share", "orca", "current" });
        defer allocator.free(current);
        removed_any = try removeInstallerRuntimeAt(io, allocator, current, stdout) or removed_any;
    }

    return removed_any;
}

fn removeInstallerRuntimeAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    current_path: []const u8,
    stdout: anytype,
) !bool {
    if (!std.fs.path.isAbsolute(current_path) or !std.mem.eql(u8, std.fs.path.basename(current_path), "current")) return false;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(io, current_path, &link_buf) catch return false;

    const share_dir = std.fs.path.dirname(current_path) orelse return false;
    const canonical_share_dir = std.Io.Dir.cwd().realPathFileAlloc(io, share_dir, allocator) catch return false;
    defer allocator.free(canonical_share_dir);
    const target = std.Io.Dir.cwd().realPathFileAlloc(io, current_path, allocator) catch return false;
    defer allocator.free(target);

    const target_parent = std.fs.path.dirname(target) orelse return false;
    if (!std.mem.eql(u8, target_parent, canonical_share_dir) or std.mem.eql(u8, target, current_path)) {
        try stdout.print("  runtime: refusing to remove target outside {s}: {s}\n", .{ canonical_share_dir, target });
        return false;
    }
    if (!runtimeLooksInstallerOwned(io, allocator, target)) {
        try stdout.print("  runtime: refusing to remove unrecognized payload: {s}\n", .{target});
        return false;
    }

    std.Io.Dir.cwd().deleteTree(io, target) catch |err| {
        try stdout.print("  runtime: failed to remove {s}: {s}\n", .{ target, @errorName(err) });
        return false;
    };
    std.Io.Dir.cwd().deleteFile(io, current_path) catch |err| {
        try stdout.print("  runtime: failed to remove link {s}: {s}\n", .{ current_path, @errorName(err) });
        return false;
    };
    try stdout.print("  removed runtime: {s}\n", .{target});
    try stdout.print("  removed runtime link: {s}\n", .{current_path});
    return true;
}

fn runtimeLooksInstallerOwned(io: std.Io, allocator: std.mem.Allocator, target: []const u8) bool {
    const version = std.fs.path.basename(target);
    if (version.len == 0 or !std.ascii.isDigit(version[0])) return false;
    for (version) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '+') return false;
    }

    const marker = std.fs.path.join(allocator, &.{ target, ".orca-installation" }) catch return false;
    defer allocator.free(marker);
    const marker_text = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(128)) catch return false;
    defer allocator.free(marker_text);
    if (!std.mem.startsWith(u8, marker_text, "orca-runtime-v1\nversion=")) return false;

    for ([_][]const u8{ "integrations", "fixtures", "schemas", "policies" }) |name| {
        const path = std.fs.path.join(allocator, &.{ target, name }) catch return false;
        defer allocator.free(path);
        if (!plugin.dirExists(path)) return false;
    }
    return true;
}

fn removeInstallerProfileEntries(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    const home_z = std.c.getenv("HOME") orelse return false;
    const home = std.mem.span(home_z);
    var removed_any = false;

    const home_profiles = [_][]const u8{ ".zshrc", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish" };
    for (home_profiles) |relative| {
        const path = try std.fs.path.join(allocator, &.{ home, relative });
        defer allocator.free(path);
        removed_any = try removeInstallerProfileEntriesAt(io, allocator, path, stdout) or removed_any;
    }

    return removed_any;
}

fn removeInstallerProfileEntriesAt(
    io: std.Io,
    allocator: std.mem.Allocator,
    profile_path: []const u8,
    stdout: anytype,
) !bool {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, profile_path, &link_buf)) |_| return false else |_| {}

    const content = std.Io.Dir.cwd().readFileAlloc(io, profile_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);

    var updated: std.Io.Writer.Allocating = .init(allocator);
    defer updated.deinit();
    var changed = false;
    var pos: usize = 0;

    while (pos < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const after_line = if (line_end < content.len) line_end + 1 else line_end;
        const line = std.mem.trimEnd(u8, content[pos..line_end], "\r");
        const installer_marker = std.mem.eql(u8, line, "# Added by Orca installer");
        const runtime_marker = std.mem.eql(u8, line, "# Orca runtime assets");
        if (installer_marker or runtime_marker) {
            if (after_line < content.len) {
                const next_end = std.mem.indexOfScalarPos(u8, content, after_line, '\n') orelse content.len;
                const after_next = if (next_end < content.len) next_end + 1 else next_end;
                const next_line = std.mem.trimEnd(u8, content[after_line..next_end], "\r");
                const managed_line = if (installer_marker)
                    std.mem.startsWith(u8, next_line, "export PATH=") or std.mem.startsWith(u8, next_line, "fish_add_path -- ")
                else
                    std.mem.startsWith(u8, next_line, "export ORCA_RESOURCE_ROOT=") or std.mem.startsWith(u8, next_line, "set -gx ORCA_RESOURCE_ROOT ");
                if (managed_line) {
                    pos = after_next;
                    changed = true;
                    continue;
                }
            }
        }

        try updated.writer.writeAll(content[pos..after_line]);
        pos = after_line;
    }

    if (!changed) return false;
    const bytes = try updated.toOwnedSlice();
    defer allocator.free(bytes);
    const nonce = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.orca-uninstall-{d}", .{ profile_path, nonce });
    defer allocator.free(temp_path);
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .exclusive = true });
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    file.close(io);
    try std.Io.Dir.renameAbsolute(temp_path, profile_path, io);
    try stdout.print("  removed installer activation from: {s}\n", .{profile_path});
    return true;
}

// ---------------------------------------------------------------------------
// Config and data removal
// ---------------------------------------------------------------------------

fn removeConfigAndData(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !void {
    // User config dir: ~/.config/orca/ or $XDG_CONFIG_HOME/orca/
    const config_dir = blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
            break :blk std.fs.path.join(allocator, &.{ std.mem.span(xdg), "orca" }) catch null;
        }
        const home = std.c.getenv("HOME") orelse break :blk null;
        break :blk std.fs.path.join(allocator, &.{ std.mem.span(home), ".config", "orca" }) catch null;
    };
    defer if (config_dir) |p| allocator.free(p);

    if (config_dir) |cd| {
        if (plugin.dirExists(cd)) {
            blk: {
                std.Io.Dir.cwd().deleteTree(io, cd) catch |err| {
                    try stdout.print("  failed to remove config dir {s}: {s}\n", .{ cd, @errorName(err) });
                    break :blk;
                };
                try stdout.print("  removed: {s}\n", .{cd});
            }
        }
    }

    // Legacy user data dir ~/.orca
    const legacy_dir = blk: {
        const home = std.c.getenv("HOME") orelse break :blk null;
        break :blk std.fs.path.join(allocator, &.{ std.mem.span(home), ".orca" }) catch null;
    };
    defer if (legacy_dir) |p| allocator.free(p);

    if (legacy_dir) |ld| {
        if (plugin.dirExists(ld)) {
            blk: {
                std.Io.Dir.cwd().deleteTree(io, ld) catch |err| {
                    try stdout.print("  failed to remove legacy dir {s}: {s}\n", .{ ld, @errorName(err) });
                    break :blk;
                };
                try stdout.print("  removed: {s}\n", .{ld});
            }
        }
    }

    try stdout.writeAll("\nNote: local workspace .orca/ directories were not removed.\n");
    try stdout.writeAll("      Run 'find . -type d -name .orca' to locate and remove them manually.\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uninstall command help and invalid args" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const help_code = try command(std.testing.io, &.{"--help"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "uninstall") != null);

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const bad_code = try command(std.testing.io, &.{"--plugins-onl"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, bad_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "unknown option") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "Did you mean '--plugins-only'?") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help uninstall") != null);
}

test "uninstall without --yes in non-TTY returns usage" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--yes") != null);
}

test "uninstall --plugins-only requires --yes in non-TTY" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{"--plugins-only"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--yes") != null);
}

test "uninstall removes the installed CLI and adjacent daemon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "custom/bin");
    const cli = try tmp.dir.createFile(std.testing.io, "custom/bin/orca", .{});
    cli.close(std.testing.io);
    const daemon = try tmp.dir.createFile(std.testing.io, "custom/bin/orca-daemon", .{});
    daemon.close(std.testing.io);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const cli_path = try std.fs.path.join(std.testing.allocator, &.{ root, "custom", "bin", "orca" });
    defer std.testing.allocator.free(cli_path);

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    try std.testing.expect(try removeInstalledBinariesAt(std.testing.io, std.testing.allocator, cli_path, &stdout_writer));

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "custom/bin/orca", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "custom/bin/orca-daemon", .{}));
}

test "uninstall removes only the runtime selected by the installer current link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "integrations", "fixtures", "schemas", "policies" }) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "share/orca/1.2.0/{s}", .{name});
        defer std.testing.allocator.free(path);
        try tmp.dir.createDirPath(std.testing.io, path);
    }
    const marker = try tmp.dir.createFile(std.testing.io, "share/orca/1.2.0/.orca-installation", .{});
    try marker.writeStreamingAll(std.testing.io, "orca-runtime-v1\nversion=1.2.0\n");
    marker.close(std.testing.io);
    try tmp.dir.createDirPath(std.testing.io, "workspace/.orca");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const version_root = try std.fs.path.join(std.testing.allocator, &.{ root, "share", "orca", "1.2.0" });
    defer std.testing.allocator.free(version_root);
    const current = try std.fs.path.join(std.testing.allocator, &.{ root, "share", "orca", "current" });
    defer std.testing.allocator.free(current);
    try std.Io.Dir.cwd().symLink(std.testing.io, version_root, current, .{});

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    try std.testing.expect(try removeInstallerRuntimeAt(std.testing.io, std.testing.allocator, current, &stdout_writer));

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, current, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, version_root, .{}));
    try tmp.dir.access(std.testing.io, "workspace/.orca", .{});
}

test "uninstall refuses an unmarked sibling runtime target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "share/orca/valuable-data");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target = try std.fs.path.join(std.testing.allocator, &.{ root, "share", "orca", "valuable-data" });
    defer std.testing.allocator.free(target);
    const current = try std.fs.path.join(std.testing.allocator, &.{ root, "share", "orca", "current" });
    defer std.testing.allocator.free(current);
    try std.Io.Dir.cwd().symLink(std.testing.io, target, current, .{});
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    try std.testing.expect(!try removeInstallerRuntimeAt(std.testing.io, std.testing.allocator, current, &stdout_writer));
    try std.Io.Dir.cwd().access(std.testing.io, target, .{});
}

test "uninstall uses the Windows daemon executable suffix" {
    try std.testing.expectEqualStrings("orca-daemon.exe", daemonBinaryName(.windows));
    try std.testing.expectEqualStrings("orca-daemon", daemonBinaryName(.linux));
}

test "uninstall removes installer profile blocks and preserves unrelated lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try tmp.dir.createFile(std.testing.io, ".profile", .{});
    try profile.writeStreamingAll(std.testing.io,
        \\export KEEP_ME=1
        \\# Added by Orca installer
        \\export PATH="/custom/bin:$PATH"
        \\alias still_here='echo yes'
        \\# Orca runtime assets
        \\export ORCA_RESOURCE_ROOT="/custom/share/orca/current"
        \\# Added by Orca installer
        \\fish_add_path -- '/custom/bin'
        \\# Orca runtime assets
        \\set -gx ORCA_RESOURCE_ROOT '/custom/share/orca/current'
        \\export ALSO_KEEP_ME=1
        \\
    );
    profile.close(std.testing.io);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const profile_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".profile" });
    defer std.testing.allocator.free(profile_path);
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    try std.testing.expect(try removeInstallerProfileEntriesAt(
        std.testing.io,
        std.testing.allocator,
        profile_path,
        &stdout_writer,
    ));

    const updated = try tmp.dir.readFileAlloc(std.testing.io, ".profile", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings(
        \\export KEEP_ME=1
        \\alias still_here='echo yes'
        \\export ALSO_KEEP_ME=1
        \\
    , updated);
}

test "uninstall refuses to rewrite a symlinked shell profile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmp.dir.createFile(std.testing.io, "target", .{});
    try target.writeStreamingAll(std.testing.io, "# Added by Orca installer\nexport PATH='/orca':\"$PATH\"\n");
    target.close(std.testing.io);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root, "target" });
    defer std.testing.allocator.free(target_path);
    const profile_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".profile" });
    defer std.testing.allocator.free(profile_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, target_path, profile_path, .{});
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    try std.testing.expect(!try removeInstallerProfileEntriesAt(std.testing.io, std.testing.allocator, profile_path, &stdout_writer));
    const content = try tmp.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "Added by Orca") != null);
}
