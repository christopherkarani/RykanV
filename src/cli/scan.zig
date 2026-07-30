//! `ryk scan` — free, offline session forensics for new users.
const std = @import("std");
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const scan_lib = @import("../scan/mod.zig");
const tui = @import("../tui/mod.zig");

const Options = struct {
    days: ?u32 = null,
    all_time: bool = false,
    show_all: bool = false,
    json: bool = false,
    /// Force linear rich text (skip alt-screen TUI).
    plain: bool = false,
    only_host: ?scan_lib.types.Host = null,
};

const ProgressCtx = struct {
    io: std.Io,
    stdout: *std.Io.Writer,
    label_buf: [96]u8 = undefined,
    label_len: usize = 0,
    spinner: ?tui.spinner.Spinner(*std.Io.Writer) = null,
    active: bool = false,

    fn setLabel(self: *ProgressCtx, text: []const u8) void {
        const n = @min(text.len, self.label_buf.len);
        @memcpy(self.label_buf[0..n], text[0..n]);
        self.label_len = n;
        if (self.spinner) |*sp| sp.label = self.label_buf[0..self.label_len];
    }

    fn ensureSpinner(self: *ProgressCtx) void {
        if (self.spinner != null) return;
        self.setLabel("Scanning agent sessions");
        self.spinner = .{
            .label = self.label_buf[0..self.label_len],
            .io = self.io,
            .stdout = self.stdout,
        };
        self.spinner.?.start() catch {};
        self.active = true;
    }

    fn tick(self: *ProgressCtx) void {
        if (self.spinner) |*sp| sp.tick() catch {};
    }

    fn clear(self: *ProgressCtx) void {
        if (!self.active) return;
        // Clear in-place spinner without a residual success line (TUI follows).
        if (tui.theme.active(self.io, self.stdout).capability.hasColor() and
            !tui.theme.reducedMotion(self.io, self.stdout))
        {
            self.stdout.writeAll("\r\x1b[2K\r") catch {};
        }
        flushWriter(self.stdout) catch {};
        self.active = false;
    }

    fn finishPlain(self: *ProgressCtx, success: bool) void {
        if (!self.active) return;
        if (self.spinner) |*sp| sp.stop(success) catch {};
        self.active = false;
    }
};

fn progressCb(ctx: ?*anyopaque, host: scan_lib.types.Host, phase: scan_lib.engine.ProgressPhase, sessions: usize) void {
    const self: *ProgressCtx = @ptrCast(@alignCast(ctx orelse return));
    self.ensureSpinner();
    var tmp: [96]u8 = undefined;
    const text = switch (phase) {
        .host_start => std.fmt.bufPrint(&tmp, "Scanning {s}", .{host.toString()}) catch "Scanning",
        .host_done => std.fmt.bufPrint(&tmp, "Scanned {s} ({d} files)", .{ host.toString(), sessions }) catch "Scanned",
    };
    self.setLabel(text);
    self.tick();
}

fn flushWriter(writer: anytype) !void {
    const Writer = @TypeOf(writer);
    switch (@typeInfo(Writer)) {
        .pointer => |pointer| if (@hasDecl(pointer.child, "flush")) try writer.flush(),
        else => if (@hasDecl(Writer, "flush")) try writer.flush(),
    }
}

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseOptions(io, argv, stdout, stderr) catch |err| switch (err) {
        error.HelpShown => return exit_codes.success,
        error.Usage => return exit_codes.usage,
        else => return err,
    };

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // No license gate (free forensics — unlike `report`).

    if (options.json and options.plain) {
        try stderr.writeAll("ryk scan: --plain cannot be combined with --json.\n");
        return exit_codes.usage;
    }

    const home = blk: {
        if (std.c.getenv("HOME")) |h| {
            const s = std.mem.span(h);
            if (s.len > 0) break :blk try allocator.dupe(u8, s);
        }
        try stderr.writeAll("ryk scan: HOME is not set; cannot locate host session stores.\n");
        return exit_codes.general;
    };
    defer allocator.free(home);

    const xdg_data: ?[]u8 = blk: {
        if (std.c.getenv("XDG_DATA_HOME")) |x| {
            const s = std.mem.span(x);
            if (s.len > 0) break :blk try allocator.dupe(u8, s);
        }
        break :blk null;
    };
    defer if (xdg_data) |x| allocator.free(x);

    // TTY auto-TUI: interactive colour terminal, not --json/--plain.
    const want_tui = !options.json and !options.plain and tui.theme.active(io, stdout).capability.hasColor();

    var progress_ctx: ProgressCtx = .{
        .io = io,
        .stdout = stdout,
    };

    var result = scan_lib.runScan(io, allocator, .{
        .home = home,
        .xdg_data_home = xdg_data,
        .days = options.days,
        .all_time = options.all_time,
        .show_all = options.show_all,
        .only_host = options.only_host,
        .progress = if (want_tui or (!options.json and tui.theme.active(io, stdout).capability.hasColor()))
            progressCb
        else
            null,
        .progress_ctx = if (want_tui or (!options.json and tui.theme.active(io, stdout).capability.hasColor()))
            &progress_ctx
        else
            null,
    }) catch |err| {
        progress_ctx.clear();
        try stderr.print("ryk scan: failed: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer result.deinit();

    if (options.json) {
        progress_ctx.clear();
        try scan_lib.writeJson(stdout, result);
    } else if (want_tui) {
        progress_ctx.clear();
        // Print a durable scorecard on the primary screen first. Alt-screen is
        // saved/restored around the interactive viewer — without this, quitting
        // the TUI (or a failed enter) leaves only the brand banner and looks
        // like "scan did nothing".
        try scan_lib.writeHuman(io, stdout, result);
        try flushWriter(stdout);
        scan_lib.tui_view.run(io, stdout, &result) catch |err| switch (err) {
            // Already printed linear findings; interactive layer is optional.
            error.TtyUnavailable => {},
            else => return err,
        };
    } else {
        progress_ctx.finishPlain(true);
        try scan_lib.writeHuman(io, stdout, result);
    }
    // Successful scan always exits 0 (even with findings).
    return exit_codes.success;
}

fn parseOptions(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !Options {
    _ = stdout;
    var options: Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            if (!try help.writeCommand(io, stderr, "scan")) {
                try stderr.writeAll("ryk scan: help entry missing\n");
                return error.Usage;
            }
            return error.HelpShown;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            options.plain = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            options.show_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all-time")) {
            options.all_time = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--days")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.writeAll("ryk scan: --days requires a number\n");
                return error.Usage;
            }
            const n = std.fmt.parseInt(u32, argv[i], 10) catch {
                try stderr.writeAll("ryk scan: --days requires a positive integer\n");
                return error.Usage;
            };
            if (n == 0) {
                try stderr.writeAll("ryk scan: --days must be >= 1 (or use --all-time)\n");
                return error.Usage;
            }
            options.days = n;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--days=")) {
            const n = std.fmt.parseInt(u32, arg["--days=".len..], 10) catch {
                try stderr.writeAll("ryk scan: --days requires a positive integer\n");
                return error.Usage;
            };
            if (n == 0) {
                try stderr.writeAll("ryk scan: --days must be >= 1 (or use --all-time)\n");
                return error.Usage;
            }
            options.days = n;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.writeAll("ryk scan: --host requires a name (claude|codex|pi|opencode|grok|ryk)\n");
                return error.Usage;
            }
            options.only_host = parseHost(argv[i]) orelse {
                try stderr.writeAll("ryk scan: unknown host (claude|codex|pi|opencode|grok|ryk)\n");
                return error.Usage;
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--host=")) {
            options.only_host = parseHost(arg["--host=".len..]) orelse {
                try stderr.writeAll("ryk scan: unknown host (claude|codex|pi|opencode|grok|ryk)\n");
                return error.Usage;
            };
            continue;
        }
        try stderr.print("ryk scan: unknown option '{s}'\n", .{arg});
        try stderr.writeAll("Run 'ryk scan --help' for usage.\n");
        return error.Usage;
    }
    if (options.all_time and options.days != null) {
        try stderr.writeAll("ryk scan: use either --days N or --all-time, not both\n");
        return error.Usage;
    }
    return options;
}

fn parseHost(name: []const u8) ?scan_lib.types.Host {
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "pi")) return .pi;
    if (std.mem.eql(u8, name, "opencode")) return .opencode;
    if (std.mem.eql(u8, name, "grok")) return .grok;
    if (std.mem.eql(u8, name, "ryk") or std.mem.eql(u8, name, "orca")) return .ryk;
    return null;
}

test "scan CLI module loads" {
    _ = command;
}

test "scan CLI rejects --plain with --json" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    const code = try command(std.testing.io, &.{ "--plain", "--json" }, &out, &err);
    try std.testing.expectEqual(@as(u8, exit_codes.usage), code);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "--plain") != null);
}
