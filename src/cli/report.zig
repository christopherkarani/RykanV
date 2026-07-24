const std = @import("std");

const core = @import("orca_core").core;
const core_api = @import("orca_core").api;
const supervisor = core.supervisor;
const report = @import("../report.zig");
const license = @import("../license.zig");
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const tui = @import("../tui/mod.zig");
const suggestions = @import("suggestions.zig");

const Format = enum { markdown, json };
const Options = struct { session: []const u8 = "last", format: Format = .markdown };

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseOptions(io, argv, stdout, stderr) catch |err| switch (err) {
        error.HelpShown => return exit_codes.success,
        error.Usage => return exit_codes.usage,
        else => return err,
    };
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    var current = license.status(io, allocator) catch |err| switch (err) {
        error.InvalidLicense, error.InvalidLicenseSignature, error.UnsupportedLicenseIssuer, error.UnsupportedLicenseTier => {
            try stderr.print("orca report: stored license is invalid: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
        else => return err,
    };
    defer current.deinit();
    if (!current.tier.allows(.report_export)) {
        try tui.render.callout(
            io,
            stderr,
            .info,
            "Report export requires a license",
            "Activate a local development license with: orca license activate dev-pro",
        );
        return exit_codes.unsupported;
    }

    const workspace_root = supervisor.resolveWorkspaceRoot(io, allocator, null, ".") catch |err| {
        try stderr.print("orca report: failed to resolve workspace: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer allocator.free(workspace_root);

    var replay = core_api.loadReplay(io, allocator, workspace_root, .{ .session = options.session, .only_denied = true, .verify = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try tui.render.callout(
                io,
                stderr,
                .info,
                "No reportable session found",
                "Run a protected command first: ryk run -- echo hello. Then retry: orca report --session last",
            );
            return exit_codes.general;
        },
        error.HashVerificationFailed => {
            try stderr.writeAll("orca report: hash verification failed; refusing to export report from tampered evidence.\n");
            return exit_codes.general;
        },
        else => {
            try stderr.print("orca report: failed: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
    };
    defer replay.deinit();

    switch (options.format) {
        .markdown => report.writeMarkdown(io, allocator, stdout, workspace_root, replay) catch |err| return mapReportExportError(stderr, err),
        .json => report.writeJson(io, allocator, stdout, workspace_root, replay) catch |err| return mapReportExportError(stderr, err),
    }
    return exit_codes.success;
}

fn mapReportExportError(stderr: anytype, err: anyerror) !u8 {
    switch (err) {
        error.ParseIntegrityFailed => {
            try stderr.writeAll("orca report: event parse integrity failed; refusing to export report from incomplete evidence.\n");
            return exit_codes.general;
        },
        else => return err,
    }
}

fn parseOptions(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "report");
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--session")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("orca report: --session requires a session id or 'last'.\n");
                return error.Usage;
            }
            options.session = argv[index];
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("orca report: --format requires markdown or json.\n");
                return error.Usage;
            }
            if (std.mem.eql(u8, argv[index], "markdown")) options.format = .markdown else if (std.mem.eql(u8, argv[index], "json")) options.format = .json else {
                try stderr.writeAll("orca report: --format supports markdown or json.\n");
                return error.Usage;
            }
        } else {
            try suggestions.writeUnknownOption(stderr, "orca report", arg, &.{ "--session", "--format", "--help", "-h" }, "report");
            return error.Usage;
        }
    }
    return options;
}

test "report rejects unsupported format" {
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try command(std.testing.io, &.{ "--format", "html" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "--format") != null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn restoreXdgConfigHome(previous: ?[:0]u8) void {
    if (previous) |value| {
        _ = setenv("XDG_CONFIG_HOME", value, 1);
        std.testing.allocator.free(value);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    }
}

test "report public errors render license remediation and missing-session guidance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const previous_xdg: ?[:0]u8 = if (std.c.getenv("XDG_CONFIG_HOME")) |value|
        try std.testing.allocator.dupeZ(u8, std.mem.sliceTo(value, 0))
    else
        null;
    defer restoreXdgConfigHome(previous_xdg);
    try std.testing.expectEqual(@as(c_int, 0), setenv("XDG_CONFIG_HOME", root, 1));

    const previous_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(previous_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentPath(std.testing.io, previous_cwd) catch {};
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const policy_file = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer policy_file.close(std.testing.io);
        try policy_file.writeStreamingAll(std.testing.io, "version: 1\nmode: strict\n");
    }

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const unlicensed_code = try command(std.testing.io, &.{}, &stdout_writer, &stderr_writer);

    try std.testing.expectEqual(exit_codes.unsupported, unlicensed_code);
    try std.testing.expectEqualStrings("", stdout_writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ℹ  Report export requires a license") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk license activate dev-pro") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, stderr_writer.buffered(), 0x1b) == null);

    const license_path = try std.fs.path.join(std.testing.allocator, &.{ root, "orca", "license.json" });
    defer std.testing.allocator.free(license_path);
    var activated = try license.activateToPath(std.testing.io, std.testing.allocator, "dev-pro", license_path);
    activated.deinit();

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const missing_code = try command(std.testing.io, &.{ "--session", "missing" }, &stdout_writer, &stderr_writer);

    try std.testing.expectEqual(exit_codes.general, missing_code);
    try std.testing.expectEqualStrings("", stdout_writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "No reportable session found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk run -- echo") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, stderr_writer.buffered(), 0x1b) == null);
}
