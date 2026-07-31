const std = @import("std");
const plugin = @import("ryk").cli.plugin;
const init = @import("ryk").cli.init;
const exit_codes = @import("ryk").cli.exit_codes;

test "host detection finds a known binary in PATH" {
    const allocator = std.testing.allocator;
    // zig is expected to be on PATH in the dev environment
    try std.testing.expect(plugin.binaryInPath(std.testing.io, allocator, "zig"));
    try std.testing.expect(!plugin.binaryInPath(std.testing.io, allocator, "definitely-not-a-real-binary-12345"));
}

test "policy init creates file when missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try init.command(std.testing.io, tmp.dir, &.{ "--preset", "generic-agent", "--force", "--quiet" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    tmp.dir.access(std.testing.io, ".ryk/policy.yaml", .{}) catch {
        std.debug.panic("policy file was not created", .{});
    };
}

test "smoke test result parsing extracts decision" {
    const allocator = std.testing.allocator;
    const stdout_json =
        \\{
        \\  "version": 1,
        \\  "decision": "allow",
        \\  "risk": "low",
        \\  "category": "command",
        \\  "reason": "test",
        \\  "rule": null,
        \\  "message": "test message",
        \\  "redactions": [],
        \\  "host_limitations": []
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout_json, .{});
    defer parsed.deinit();

    const decision = parsed.value.object.get("decision") orelse {
        return error.MissingDecision;
    };
    try std.testing.expectEqualStrings("allow", decision.string);
}
