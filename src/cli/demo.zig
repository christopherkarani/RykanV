const std = @import("std");

const core = @import("orca_core").core;
const supervisor = core.supervisor;
const demo = @import("../demo.zig");
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const suggestions = @import("suggestions.zig");

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        _ = try help.writeCommand(io, stdout, "demo");
        return if (argv.len == 0) exit_codes.usage else exit_codes.success;
    }
    if (!std.mem.eql(u8, argv[0], "blocked-action")) {
        try suggestions.writeUnknownSubcommand(stderr, "orca demo", argv[0], &.{"blocked-action"}, "demo");
        return exit_codes.usage;
    }
    if (argv.len != 1) {
        try stderr.writeAll("orca demo blocked-action: expected no additional arguments.\nRun 'ryk help demo' for usage.\n");
        return exit_codes.usage;
    }
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const workspace_root = supervisor.resolveWorkspaceRoot(io, allocator, null, ".") catch try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace_root);
    const session_id = demo.createBlockedActionSession(io, allocator, workspace_root) catch |err| {
        try stderr.print("orca demo blocked-action: failed: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer allocator.free(session_id);
    try stdout.print(
        \\Created safe blocked-action demo session: {s}
        \\No destructive command was executed.
        \\View it with:
        \\  orca replay --session {s} --only denied --verify
        \\  orca report --session {s} --format markdown
        \\
    , .{ session_id, session_id, session_id });
    return exit_codes.success;
}

test "demo command rejects unknown demos" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try command(std.testing.io, &.{"blocked-acton"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "Did you mean 'blocked-action'?") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help demo") != null);
}
