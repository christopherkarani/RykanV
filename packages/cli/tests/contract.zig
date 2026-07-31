const std = @import("std");
const orca_cli = @import("orca_cli");

test "cli package exposes existing command surface without becoming edge" {
    try std.testing.expectEqualStrings("23-product-split-cli-contract", orca_cli.phase);
    try std.testing.expect(orca_cli.cli.help.findCommand("run") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("doctor") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("redteam") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("report") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("license") == null);
    try std.testing.expect(orca_cli.cli.help.findCommand("ci") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("explain") != null);
    try std.testing.expect(orca_cli.cli.help.findCommand("edge") == null);
}

test "cli package help still renders Orca CLI command summary" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try orca_cli.cli.help.write(std.testing.io, &writer);
    const written = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, written, "Orca") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Getting Started") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "redteam") != null);
}

test "cli package can evaluate CLI actions through Core facade" {
    var selected = try orca_cli.core.api.parsePolicyFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: strict
        \\commands:
        \\  allow:
        \\    - "echo *"
    , "cli-core-api.yaml");
    defer selected.deinit();

    var evaluation = try orca_cli.core.api.evaluateAction(
        std.testing.allocator,
        selected,
        .{ .command_exec = .{ .argv = &.{ "echo", "hello" } } },
        .{},
    );
    defer evaluation.deinit(std.testing.allocator);

    try std.testing.expectEqual(orca_cli.core.decision.DecisionResult.allow, evaluation.decision.result);
}
