const std = @import("std");
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const telemetry = @import("../telemetry.zig");

pub fn command(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h"))) {
        _ = try help.writeCommand(io, stdout, "feedback");
        return exit_codes.success;
    }
    if (argv.len != 1) {
        try stderr.writeAll(
            "ryk feedback: choose one category: bug, false_positive, false_negative, missing_integration, confusing.\n",
        );
        return exit_codes.usage;
    }
    const category = parseCategory(argv[0]) orelse {
        try stderr.writeAll(
            "ryk feedback: unknown category. Choose bug, false_positive, false_negative, missing_integration, or confusing.\n",
        );
        return exit_codes.usage;
    };
    return switch (telemetry.recordFeedback(io, environ_map, std.heap.smp_allocator, category)) {
        .accepted => blk: {
            try stdout.writeAll("Feedback accepted for telemetry delivery.\n");
            break :blk exit_codes.success;
        },
        .disabled => blk: {
            try stderr.writeAll("ryk feedback: telemetry is disabled; nothing was sent.\n");
            break :blk exit_codes.general;
        },
        .unavailable => blk: {
            try stderr.writeAll("ryk feedback: telemetry state is unavailable; nothing was sent.\n");
            break :blk exit_codes.general;
        },
    };
}

fn parseCategory(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "bug")) return "bug";
    if (std.mem.eql(u8, value, "false_positive") or std.mem.eql(u8, value, "false-positive")) return "false_positive";
    if (std.mem.eql(u8, value, "false_negative") or std.mem.eql(u8, value, "false-negative")) return "false_negative";
    if (std.mem.eql(u8, value, "missing_integration") or std.mem.eql(u8, value, "missing-integration")) return "missing_integration";
    if (std.mem.eql(u8, value, "confusing")) return "confusing";
    return null;
}

test "feedback accepts only fixed categories" {
    try std.testing.expectEqualStrings("false_positive", parseCategory("false-positive").?);
    try std.testing.expect(parseCategory("free text") == null);
}

test "feedback reports unavailable transport instead of claiming delivery" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try std.testing.expectEqual(
        telemetry.FeedbackStatus.disabled,
        telemetry.recordFeedback(std.testing.io, &environ_map, std.testing.allocator, "bug"),
    );
}
