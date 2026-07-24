const std = @import("std");

const license = @import("orca").license;
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const suggestions = @import("suggestions.zig");

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        _ = try help.writeCommand(io, stdout, "license");
        return if (argv.len == 0) exit_codes.usage else exit_codes.success;
    }
    if (std.mem.eql(u8, argv[0], "status")) return status(io, argv[1..], stdout, stderr);
    if (std.mem.eql(u8, argv[0], "activate")) return activate(io, argv[1..], stdout, stderr);
    try suggestions.writeUnknownSubcommand(stderr, "ryk license", argv[0], &.{ "status", "activate" }, "license");
    return exit_codes.usage;
}

fn status(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    var json = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true else {
            try suggestions.writeUnknownOption(stderr, "ryk license status", arg, &.{"--json"}, "license");
            return exit_codes.usage;
        }
    }
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    var current = license.status(io, allocator) catch |err| switch (err) {
        error.InvalidLicense, error.InvalidLicenseSignature, error.UnsupportedLicenseIssuer, error.UnsupportedLicenseTier => {
            try stderr.print("ryk license status: stored license is invalid: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
        else => return err,
    };
    defer current.deinit();
    if (json) {
        try writeStatusJson(stdout, current);
    } else {
        try stdout.print("License: {s}\nStatus: {s}\nSource: {s}\n", .{
            current.tier.label(),
            if (current.verified) "verified" else "free",
            current.source,
        });
    }
    return exit_codes.success;
}

fn activate(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (argv.len != 1) {
        try stderr.writeAll("ryk license activate: expected a development key or license file path.\n");
        return exit_codes.usage;
    }
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    var result = license.activate(io, allocator, argv[0]) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("ryk license activate: key is not a known development key and file was not found.\n");
            return exit_codes.general;
        },
        error.InvalidLicense, error.InvalidLicenseSignature, error.UnsupportedLicenseIssuer, error.UnsupportedLicenseTier => {
            try stderr.print("ryk license activate: invalid license: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
        else => return err,
    };
    defer result.deinit();
    try stdout.print("Activated {s} license at {s}.\n", .{ result.license.tier.label(), result.path });
    return exit_codes.success;
}

fn writeStatusJson(writer: anytype, current: license.License) !void {
    try writer.writeAll("{\"tier\":");
    try @import("orca_core").core.util.writeJsonString(writer, current.tier.label());
    try writer.writeAll(",\"verified\":");
    try writer.writeAll(if (current.verified) "true" else "false");
    try writer.writeAll(",\"license_id\":");
    try @import("orca_core").core.util.writeJsonString(writer, current.license_id);
    try writer.writeAll(",\"source\":");
    try @import("orca_core").core.util.writeJsonString(writer, current.source);
    try writer.writeAll("}\n");
}

test "license status --json contract is stable and presentation-free" {
    var current = try license.License.free(std.testing.allocator, "test-source");
    defer current.deinit();

    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try writeStatusJson(&writer, current);
    try std.testing.expectEqualStrings(
        "{\"tier\":\"Free\",\"verified\":false,\"license_id\":\"free\",\"source\":\"test-source\"}\n",
        writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, writer.buffered(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Orca") == null);
}

test "license status reports free when path is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing-license.json" });
    defer std.testing.allocator.free(path);
    var current = try license.statusFromPath(std.testing.io, std.testing.allocator, path);
    defer current.deinit();
    try std.testing.expectEqual(license.Tier.free, current.tier);
}

test "license command rejects unknown subcommands" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try command(std.testing.io, &.{"stats"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "unknown subcommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "Did you mean 'status'?") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help license") != null);
}
