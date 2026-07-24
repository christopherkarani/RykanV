const std = @import("std");

const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const plugin = @import("plugin.zig");
const danger_confirmation = @import("danger_confirmation.zig");
const suggestions = @import("suggestions.zig");

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

const DisableTarget = enum { codex, claude, cursor, opencode, openclaw, hermes, all };

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var target: DisableTarget = .all;
    var yes = false;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "stop");
            return exit_codes.success;
        }
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "codex")) {
            target = .codex;
            continue;
        }
        if (std.mem.eql(u8, arg, "claude")) {
            target = .claude;
            continue;
        }
        if (std.mem.eql(u8, arg, "cursor")) {
            target = .cursor;
            continue;
        }
        if (std.mem.eql(u8, arg, "opencode")) {
            target = .opencode;
            continue;
        }
        if (std.mem.eql(u8, arg, "openclaw")) {
            target = .openclaw;
            continue;
        }
        if (std.mem.eql(u8, arg, "hermes") or std.mem.eql(u8, arg, "hermess")) {
            target = .hermes;
            continue;
        }
        if (std.mem.eql(u8, arg, "all") or std.mem.eql(u8, arg, "-all")) {
            target = .all;
            continue;
        }
        try suggestions.writeUnknownOption(
            stderr,
            "ryk stop",
            arg,
            &.{ "codex", "claude", "cursor", "opencode", "openclaw", "hermes", "all", "--yes", "--help" },
            "stop",
        );
        return exit_codes.usage;
    }

    if (!yes) {
        const stdin = std.Io.File.stdin();
        const host_label = if (target == .all) "all" else @tagName(target);
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Stop Orca for {s}? This removes plugin registrations from host agents.", .{host_label}) catch "Stop Orca?";
        const decision = danger_confirmation.decide(io, stdout, prompt, false, try stdin.isTty(io), null) catch |err| {
            try stderr.print("ryk stop: confirmation failed: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        };
        switch (decision) {
            .proceed => {},
            .cancelled => {
                try stdout.writeAll("canceled\n");
                return exit_codes.success;
            },
            .requires_yes => {
                try stderr.writeAll("ryk stop: requires --yes or run interactively.\n");
                return exit_codes.usage;
            },
        }
    }

    try stdout.writeAll("Orca Stop\n\n");

    const targets = switch (target) {
        .codex => &[_]DisableTarget{.codex},
        .claude => &[_]DisableTarget{.claude},
        .cursor => &[_]DisableTarget{.cursor},
        .opencode => &[_]DisableTarget{.opencode},
        .openclaw => &[_]DisableTarget{.openclaw},
        .hermes => &[_]DisableTarget{.hermes},
        .all => &[_]DisableTarget{ .codex, .claude, .cursor, .opencode, .openclaw, .hermes },
    };

    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (targets) |t| {
        try stdout.print("→ Disabling {s}...\n", .{@tagName(t)});
        const did_disable = switch (t) {
            .opencode => try disableOpenCode(io, allocator, stdout),
            .cursor => try disableCursor(io, allocator, stdout),
            .openclaw => try disableOpenClaw(io, allocator, stdout),
            .hermes => try disableHermes(io, allocator, stdout),
            .codex => try disableCodex(io, allocator, stdout),
            .claude => try disableClaude(io, allocator, stdout),
            .all => unreachable,
        };
        if (did_disable) {
            try stdout.print("  ✓ {s} disabled\n", .{@tagName(t)});
            success_count += 1;
        } else {
            try stdout.print("  ✗ {s} not found or failed\n", .{@tagName(t)});
            fail_count += 1;
        }
    }

    try stdout.writeAll("\n");
    if (success_count == 0 and fail_count == 0) {
        try stdout.writeAll("No Orca plugins were found to disable.\n");
    } else if (fail_count == 0) {
        try stdout.writeAll("✅ All Orca plugins have been disabled.\n");
    } else {
        try stdout.print("⚠️  Disabled {d} plugin(s), {d} failed.\n", .{ success_count, fail_count });
    }
    try stdout.writeAll("Orca binary and policy files remain in place.\n");
    try stdout.writeAll("Restart protection with: ryk start\n");
    return exit_codes.success;
}

// ---------------------------------------------------------------------------
// Per-host disable functions (pub so uninstall.zig can delegate)
// ---------------------------------------------------------------------------

pub fn disableOpenCode(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    var removed = false;
    const project_path = try std.fs.path.join(allocator, &.{ ".opencode", "plugins", "orca.ts" });
    defer allocator.free(project_path);
    const global_path = blk: {
        const home = std.c.getenv("HOME") orelse break :blk null;
        break :blk try std.fs.path.join(allocator, &.{ std.mem.span(home), ".config", "opencode", "plugins", "orca.ts" });
    };
    defer if (global_path) |p| allocator.free(p);

    if (plugin.fileExistsAbsolute(io, project_path)) {
        blk: {
            std.Io.Dir.cwd().deleteFile(io, project_path) catch |err| {
                try stdout.print("  project plugin: failed to remove ({s})\n", .{@errorName(err)});
                break :blk;
            };
            try stdout.writeAll("  project plugin: removed (.opencode/plugins/orca.ts)\n");
            removed = true;
        }
    }
    if (global_path) |gp| {
        if (plugin.fileExistsAbsolute(io, gp)) {
            blk: {
                std.Io.Dir.cwd().deleteFile(io, gp) catch |err| {
                    try stdout.print("  global plugin: failed to remove ({s})\n", .{@errorName(err)});
                    break :blk;
                };
                try stdout.writeAll("  global plugin: removed (~/.config/opencode/plugins/orca.ts)\n");
                removed = true;
            }
        }
    }
    return removed;
}

pub fn disableOpenClaw(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    if (plugin.binaryInPath(io, allocator, "openclaw")) {
        try stdout.writeAll("  openclaw: running 'openclaw plugins uninstall orca-openclaw-plugin' (10s timeout)...\n");

        const status = runOpenClawUninstall(allocator) catch |err| blk: {
            try stdout.print("  host uninstall: failed ({s})\n", .{@errorName(err)});
            try stdout.writeAll("    → Will fall back to direct file cleanup where possible.\n");
            break :blk 255;
        };

        if (status == 0) {
            try stdout.writeAll("  host uninstall: removed via openclaw plugins uninstall\n");
            return true;
        } else {
            try stdout.print("  host uninstall: openclaw exited with code {d} (or timed out)\n", .{status});
            try stdout.writeAll("    → Attempting direct cleanup of known Orca plugin files for OpenClaw...\n");
            return false;
        }
    }
    try stdout.writeAll("  status: openclaw binary not found in PATH\n");
    return false;
}

pub fn disableHermes(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    var disabled = false;
    if (plugin.binaryInPath(io, allocator, "hermes")) {
        try stdout.writeAll("  hermes: running 'hermes plugins disable orca' (10s timeout)...\n");

        const status = runHermesDisable(allocator) catch |err| blk: {
            try stdout.print("  host disable: failed ({s})\n", .{@errorName(err)});
            try stdout.writeAll("    → Will perform direct file cleanup of ~/.hermes/plugins/orca/\n");
            break :blk 255;
        };
        if (status == 0) {
            try stdout.writeAll("  host disable: hermes plugins disable orca\n");
            disabled = true;
        } else {
            try stdout.print("  host disable: hermes exited with code {d} (or timed out)\n", .{status});
            try stdout.writeAll("    → Ensuring ~/.hermes/plugins/orca/ is removed directly...\n");
        }
    }
    const user_root = try plugin.hermesUserPluginRoot(allocator);
    defer allocator.free(user_root);
    if (plugin.dirExists(user_root)) {
        blk: {
            std.Io.Dir.cwd().deleteTree(io, user_root) catch |err| {
                try stdout.print("  plugin files: failed to remove ({s})\n", .{@errorName(err)});
                break :blk;
            };
            try stdout.print("  plugin files: removed {s}\n", .{user_root});
            disabled = true;
        }
    }
    return disabled;
}

pub fn disableCodex(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    return try removeKnownPluginPaths(io, allocator, stdout, "codex", &[_][]const u8{
        ".agents/plugins/orca",
        ".codex/plugins/orca",
    });
}

pub fn disableClaude(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    return try removeKnownPluginPaths(io, allocator, stdout, "claude", &[_][]const u8{
        ".claude/plugins/orca",
    });
}

pub fn disableCursor(io: std.Io, allocator: std.mem.Allocator, stdout: anytype) !bool {
    var removed = try removeKnownPluginPaths(io, allocator, stdout, "cursor", &[_][]const u8{
        ".cursor/hooks/orca-pre-shell.py",
    });

    const global_hook = if (std.c.getenv("HOME")) |home|
        try std.fs.path.join(allocator, &.{ std.mem.span(home), ".cursor", "hooks", "orca-pre-shell.py" })
    else
        null;
    defer if (global_hook) |p| allocator.free(p);
    if (global_hook) |path| {
        removed = try removeKnownPluginPaths(io, allocator, stdout, "cursor", &[_][]const u8{path}) or removed;
    }

    removed = try disableCursorHooksJsonIfOrcaOnly(io, allocator, stdout, ".cursor/hooks.json") or removed;
    const global_hooks_json = if (std.c.getenv("HOME")) |home|
        try std.fs.path.join(allocator, &.{ std.mem.span(home), ".cursor", "hooks.json" })
    else
        null;
    defer if (global_hooks_json) |p| allocator.free(p);
    if (global_hooks_json) |path| {
        removed = try disableCursorHooksJsonIfOrcaOnly(io, allocator, stdout, path) or removed;
    }

    return removed;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn disableCursorHooksJsonIfOrcaOnly(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, path: []const u8) !bool {
    if (!plugin.fileExistsAbsolute(io, path)) return false;

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        try stdout.print("  cursor hooks: failed to read {s} ({s})\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, "orca") == null) return false;
    const is_orca_hook = std.mem.indexOf(u8, content, "orca-pre-shell.py") != null or
        std.mem.indexOf(u8, content, "\"orca\"") != null;
    if (!is_orca_hook) return false;

    if (countOccurrences(content, "\"command\"") != 1) {
        try stdout.print("  cursor hooks: {s} references Orca alongside other hooks; remove the Orca beforeShellExecution entry manually\n", .{path});
        return false;
    }

    const disabled_hooks =
        \\{
        \\  "version": 1,
        \\  "hooks": {
        \\    "beforeShellExecution": []
        \\  }
        \\}
        \\
    ;
    try overwriteTextFile(io, path, disabled_hooks);
    try stdout.print("  cursor hooks: disabled Orca beforeShellExecution in {s}\n", .{path});
    return true;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

fn overwriteTextFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        return;
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub fn runOpenClawUninstall(allocator: std.mem.Allocator) !u8 {
    const child_process = @import("child_process.zig");
    const argv = [_][]const u8{ "openclaw", "plugins", "uninstall", "orca-openclaw-plugin" };

    // Use the robust timed runner (10s) so a stuck/broken/misbehaving openclaw
    // cannot hang `orca uninstall` or `ryk stop` forever.
    const res = try child_process.runHostCommandTimed(allocator, &argv, 10_000, null, null);
    defer child_process.deinitHostCommandResult(res, allocator);

    if (res.timed_out) {
        // The caller (disableOpenClaw / uninstall) can decide to do direct fallback.
        return 255;
    }
    return res.exit_code;
}

pub fn runHermesDisable(allocator: std.mem.Allocator) !u8 {
    const child_process = @import("child_process.zig");
    const argv = [_][]const u8{ "hermes", "plugins", "disable", "orca" };

    const res = try child_process.runHostCommandTimed(allocator, &argv, 10_000, null, null);
    defer child_process.deinitHostCommandResult(res, allocator);

    if (res.timed_out) {
        return 255;
    }
    return res.exit_code;
}

pub fn removeKnownPluginPaths(io: std.Io, allocator: std.mem.Allocator, stdout: anytype, host_name: []const u8, paths: []const []const u8) !bool {
    var removed_any = false;
    for (paths) |rel_path| {
        if (plugin.fileExistsAbsolute(io, rel_path)) {
            std.Io.Dir.cwd().deleteFile(io, rel_path) catch |err| {
                try stdout.print("  {s} plugin: failed to remove {s} ({s})\n", .{ host_name, rel_path, @errorName(err) });
                continue;
            };
            try stdout.print("  {s} plugin: removed {s}\n", .{ host_name, rel_path });
            removed_any = true;
        }
        if (plugin.dirExists(rel_path)) {
            std.Io.Dir.cwd().deleteTree(io, rel_path) catch |err| {
                try stdout.print("  {s} plugin: failed to remove {s} ({s})\n", .{ host_name, rel_path, @errorName(err) });
                continue;
            };
            try stdout.print("  {s} plugin: removed {s}\n", .{ host_name, rel_path });
            removed_any = true;
        }
    }
    _ = allocator;
    return removed_any;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stop command help and invalid args" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const help_code = try command(std.testing.io, &.{"--help"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, help_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "stop") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "cursor") != null);

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const bad_code = try command(std.testing.io, &.{"--unknown"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, bad_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk stop") != null);

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const typo_code = try command(std.testing.io, &.{"codxe"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, typo_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "Did you mean 'codex'?") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help stop") != null);
}

test "stop accepts legacy -all spelling but requires confirmation in non-TTY" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, &.{"all"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--yes") != null);
}

test "stop success output points at ryk start not setup" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    // --yes skips confirmation; no plugins required for footer messaging.
    const code = try command(std.testing.io, &.{"--yes"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "orca setup") == null);
}
