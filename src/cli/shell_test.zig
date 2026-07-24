//! `orca test` — evaluate a shell command via the Zig shell engine.
const std = @import("std");
const shell_engine = @import("../shell_engine/mod.zig");
const shell_eval = @import("shell_eval.zig");
const pack_config = @import("pack_config.zig");
const core = @import("orca_core").core;

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        try stderr.writeAll(
            \\Usage: orca test [--format json] <command>
            \\
            \\Evaluate a shell command with the in-process Zig shell engine.
            \\Exit 0 = allow, 2 = deny.
            \\
        );
        return 0;
    }

    if (shell_eval.resolveShellEvalBackend() == .rust) {
        try stderr.writeAll("ryk test: ORCA_SHELL_EVAL=rust is no longer supported; Zig shell_engine is the sole Evaluate authority\n");
        return 3;
    }

    var format_json = false;
    var cmd_start: usize = 0;
    if (std.mem.eql(u8, argv[0], "--format")) {
        if (argv.len < 3) {
            try stderr.writeAll("ryk test: --format requires a value and a command\n");
            return 64;
        }
        if (!std.mem.eql(u8, argv[1], "json")) {
            try stderr.writeAll("ryk test: only --format json is supported\n");
            return 64;
        }
        format_json = true;
        cmd_start = 2;
    }

    const command_text = try joinArgs(std.heap.smp_allocator, argv[cmd_start..]);
    defer std.heap.smp_allocator.free(command_text);

    // Walk up from cwd so nested directories still load project .orca.toml.
    const workspace = core.supervisor.resolveWorkspaceRoot(io, std.heap.smp_allocator, null, ".") catch ".";
    defer if (!std.mem.eql(u8, workspace, ".")) std.heap.smp_allocator.free(workspace);

    var packs = pack_config.loadPackIdsForWorkspace(io, std.heap.smp_allocator, workspace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HomeDirectoryNotFound, error.FileNotFound => pack_config.LoadedPackIds{},
        else => {
            try stderr.writeAll("ryk test: pack configuration could not be loaded (fail-closed)\n");
            return 2;
        },
    };
    defer packs.deinit(std.heap.smp_allocator);

    var eval = try shell_engine.evaluateCommand(std.heap.smp_allocator, command_text, .{
        .default_packs_only = true,
        .extra_enabled = packs.enabled,
        .disabled = packs.disabled,
    });
    defer eval.deinit(std.heap.smp_allocator);

    if (format_json) {
        const payload = struct {
            schema_version: i64 = 1,
            decision: []const u8,
            rule_id: ?[]const u8 = null,
            pack_id: ?[]const u8 = null,
            pattern_name: ?[]const u8 = null,
            severity: []const u8,
            reason: []const u8,
            source: []const u8 = "zig.shell_engine",
        }{
            .decision = eval.decision.toString(),
            .rule_id = eval.rule_id,
            .pack_id = eval.pack_id,
            .pattern_name = eval.pattern_name,
            .severity = eval.severity.toString(),
            .reason = eval.reason,
        };
        const json = try std.json.Stringify.valueAlloc(std.heap.smp_allocator, payload, .{});
        defer std.heap.smp_allocator.free(json);
        try stdout.writeAll(json);
        try stdout.writeAll("\n");
    } else {
        try stdout.print("{s}", .{eval.decision.toString()});
        if (eval.rule_id) |rid| try stdout.print(" ({s})", .{rid});
        try stdout.writeAll("\n");
        try stdout.print("{s}\n", .{eval.reason});
    }

    return switch (eval.decision) {
        .allow => 0,
        .deny => 2,
    };
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return allocator.dupe(u8, "");
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (args, 0..) |arg, i| {
        if (i > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, arg);
    }
    return try list.toOwnedSlice(allocator);
}

test "joinArgs" {
    const s = try joinArgs(std.testing.allocator, &.{ "git", "status" });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("git status", s);
}
