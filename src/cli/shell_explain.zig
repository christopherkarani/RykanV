//! `ryk explain` — explain why a shell command would be allowed or denied.
const std = @import("std");
const shell_engine = @import("../shell_engine/mod.zig");
const shell_eval = @import("shell_eval.zig");
const pack_config = @import("pack_config.zig");
const core = @import("orca_core").core;
const help = @import("help.zig");
const explain_render = @import("explain_render.zig");
const exit_codes = @import("exit_codes.zig");

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        _ = try help.writeCommand(io, stdout, "explain");
        return if (argv.len == 0) exit_codes.usage else exit_codes.success;
    }

    if (shell_eval.resolveShellEvalBackend() == .rust) {
        try stderr.writeAll("ryk explain: ORCA_SHELL_EVAL=rust is no longer supported; Zig shell_engine is the sole Evaluate authority\n");
        return 3;
    }

    var format_json = false;
    var cmd_start: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            cmd_start = i + 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= argv.len) {
                try stderr.writeAll("ryk explain: --format requires a value and a command\n");
                return exit_codes.usage;
            }
            if (!std.mem.eql(u8, argv[i + 1], "json")) {
                try stderr.writeAll("ryk explain: only --format json is supported\n");
                return exit_codes.usage;
            }
            format_json = true;
            i += 1;
            cmd_start = i + 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("ryk explain: unknown option '{s}'.\nRun 'ryk help explain' for usage.\n", .{arg});
            return exit_codes.usage;
        }
        cmd_start = i;
        break;
    }

    if (cmd_start >= argv.len) {
        try stderr.writeAll(
            \\ryk explain: expected a command to explain.
            \\Examples:
            \\  ryk explain "rm -rf /"
            \\  ryk explain -- "git reset --hard"
            \\  ryk explain --format json "rm -rf /tmp/x"
            \\
        );
        return exit_codes.usage;
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
            try stderr.writeAll("ryk explain: pack configuration could not be loaded (fail-closed)\n");
            return 2;
        },
    };
    defer packs.deinit(std.heap.smp_allocator);

    // Opt-in TraceCollector only on explain path (hooks leave null).
    var collector = shell_engine.TraceCollector.init(std.heap.smp_allocator);
    defer collector.deinit();

    var eval = try shell_engine.evaluateCommand(std.heap.smp_allocator, command_text, .{
        .default_packs_only = true,
        .extra_enabled = packs.enabled,
        .disabled = packs.disabled,
        .trace = &collector,
    });
    defer eval.deinit(std.heap.smp_allocator);

    if (format_json) {
        try explain_render.writeJson(std.heap.smp_allocator, stdout, command_text, eval);
    } else {
        try explain_render.writePretty(io, stdout, command_text, eval);
    }
    return exit_codes.success;
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return allocator.dupe(u8, "");
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (args, 0..) |arg, idx| {
        if (idx > 0) try list.append(allocator, ' ');
        try list.appendSlice(allocator, arg);
    }
    return try list.toOwnedSlice(allocator);
}
