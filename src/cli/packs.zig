const std = @import("std");
const exit_codes = @import("exit_codes.zig");
const contracts = @import("daemon_contracts.zig");
const help = @import("help.zig");
const tui = @import("../tui/mod.zig");
const suggestions = @import("suggestions.zig");
const pack_state = @import("pack_state.zig");
const onboarding = @import("onboarding.zig");

const Options = struct {
    filter: ?[]const u8 = null,
    installed: bool = false,
    page: usize = 1,
    page_size: usize = 25,
};

const ShowOptions = struct {
    pack_id: []const u8,
    no_patterns: bool = false,
    verbose: bool = false,
    machine_json: bool = false,
};

pub fn command(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    return commandWithExecutor(realExecute, io, argv, stdout, stderr);
}

fn realExecute(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const cli = @import("mod.zig");
    return cli.executeDaemonCli(io, argv, stdout, stderr);
}

pub fn commandWithExecutor(comptime execute_cli: anytype, io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    // Zig owns human help for the friendly packs interface; raw daemon help is
    // still available via machine passthrough flags (--robot, --format, …).
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "packs");
            return exit_codes.success;
        }
    }

    if (argv.len > 0) {
        if (std.mem.eql(u8, argv[0], "show") or std.mem.eql(u8, argv[0], "info")) {
            return runShow(execute_cli, io, argv[1..], stdout, stderr);
        }
        if (std.mem.eql(u8, argv[0], "enable")) {
            return runEnable(execute_cli, io, argv[1..], stdout, stderr);
        }
        if (std.mem.eql(u8, argv[0], "disable")) {
            return runDisable(io, argv[1..], stdout, stderr);
        }
    }

    if (shouldPassThrough(argv)) {
        const daemon_argv = try std.heap.smp_allocator.alloc([]const u8, argv.len + 1);
        defer std.heap.smp_allocator.free(daemon_argv);
        daemon_argv[0] = "packs";
        @memcpy(daemon_argv[1..], argv);
        return execute_cli(io, daemon_argv, stdout, stderr);
    }

    const options = parseOptions(argv, stderr) catch return exit_codes.usage;
    var daemon_stdout: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer daemon_stdout.deinit();
    var daemon_stderr: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer daemon_stderr.deinit();

    const daemon_argv: []const []const u8 = if (options.installed)
        &.{ "packs", "--enabled", "--format", "json" }
    else
        &.{ "packs", "--format", "json" };
    const code = try execute_cli(io, daemon_argv, &daemon_stdout.writer, &daemon_stderr.writer);
    if (code != exit_codes.success) {
        try stdout.writeAll(daemon_stdout.written());
        try stderr.writeAll(daemon_stderr.written());
        return code;
    }

    var parsed = contracts.parsePacks(std.heap.smp_allocator, daemon_stdout.written()) catch |err| {
        try stderr.print("ryk packs: daemon returned invalid JSON ({s}). Try 'orca doctor'.\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer parsed.deinit();
    return renderHuman(io, options, parsed.value, stdout, stderr);
}

fn runShow(comptime execute_cli: anytype, io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseShowOptions(argv, stderr) catch return exit_codes.usage;
    const allocator = std.heap.smp_allocator;

    var daemon_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer daemon_stdout.deinit();
    var daemon_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer daemon_stderr.deinit();

    const daemon_argv: []const []const u8 = if (options.no_patterns)
        &.{ "pack", "info", options.pack_id, "--json", "--no-patterns" }
    else
        &.{ "pack", "info", options.pack_id, "--json" };

    const code = execute_cli(io, daemon_argv, &daemon_stdout.writer, &daemon_stderr.writer) catch |err| {
        try stderr.print(
            "ryk packs show: daemon {s}. Upgrade/restart orca-daemon so `pack info` is available, then retry. Or run 'orca doctor'.\n",
            .{@errorName(err)},
        );
        return exit_codes.general;
    };
    if (code != exit_codes.success) {
        if (daemon_stderr.written().len > 0) {
            try stderr.writeAll(daemon_stderr.written());
        } else {
            try stderr.print(
                "ryk packs: pack '{s}' not found or daemon unavailable. Try 'orca packs --filter {s}' or 'orca doctor'.\n",
                .{ options.pack_id, options.pack_id },
            );
        }
        if (daemon_stdout.written().len > 0 and options.machine_json) {
            try stdout.writeAll(daemon_stdout.written());
        }
        return if (code == exit_codes.usage) exit_codes.usage else exit_codes.general;
    }

    if (options.machine_json) {
        try stdout.writeAll(daemon_stdout.written());
        return exit_codes.success;
    }

    var detail = contracts.parsePackDetail(allocator, daemon_stdout.written()) catch |err| {
        try stderr.print("ryk packs: daemon returned invalid pack JSON ({s}). Try 'orca doctor'.\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer detail.deinit();

    var category: []const u8 = "";
    var enabled: ?bool = null;
    var list_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer list_stdout.deinit();
    var list_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer list_stderr.deinit();
    if (execute_cli(io, &.{ "packs", "--format", "json" }, &list_stdout.writer, &list_stderr.writer)) |list_code| {
        if (list_code == exit_codes.success) {
            if (contracts.parsePacks(allocator, list_stdout.written())) |parsed_list| {
                defer parsed_list.deinit();
                for (parsed_list.value.packs) |pack| {
                    if (std.mem.eql(u8, pack.id, options.pack_id)) {
                        category = pack.category;
                        enabled = pack.enabled;
                        break;
                    }
                }
            } else |_| {}
        }
    } else |_| {}

    return renderShowHuman(allocator, io, detail.value, category, enabled, options.verbose, options.no_patterns, stdout);
}

fn parseShowOptions(argv: []const []const u8, stderr: anytype) !ShowOptions {
    var options: ShowOptions = .{ .pack_id = "" };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--no-patterns")) {
            options.no_patterns = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--robot") or std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f") or
            std.mem.startsWith(u8, arg, "--format="))
        {
            if (std.mem.eql(u8, arg, "--robot")) {
                options.machine_json = true;
            } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= argv.len) return usageError(stderr, "--format requires a value");
                if (std.mem.eql(u8, argv[i], "json")) options.machine_json = true else return usageError(stderr, "only --format json is supported for show");
            } else if (std.mem.eql(u8, arg, "--format=json")) {
                options.machine_json = true;
            } else {
                return usageError(stderr, "only --format json is supported for show");
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageError(stderr, "unknown show option");
        } else if (options.pack_id.len == 0) {
            options.pack_id = arg;
        } else {
            return usageError(stderr, "show accepts a single pack id");
        }
    }
    if (options.pack_id.len == 0) return usageError(stderr, "show requires a pack id");
    return options;
}

fn trackSanitized(allocator: std.mem.Allocator, owned: *std.ArrayListUnmanaged([]u8), value: []const u8) ![]u8 {
    const safe = try tui.terminal_text.sanitizeAlloc(allocator, value, .single_line);
    errdefer allocator.free(safe);
    try owned.append(allocator, safe);
    return safe;
}

fn renderShowHuman(
    allocator: std.mem.Allocator,
    io: std.Io,
    detail: contracts.PackDetail,
    category: []const u8,
    enabled: ?bool,
    verbose: bool,
    no_patterns: bool,
    stdout: anytype,
) !u8 {
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |v| allocator.free(v);
        owned.deinit(allocator);
    }

    const safe_id = try trackSanitized(allocator, &owned, detail.id);
    const safe_name = try trackSanitized(allocator, &owned, detail.name);
    const safe_desc = try trackSanitized(allocator, &owned, detail.description);

    try tui.theme.paintBold(io, stdout, .text_bright, "Safety pack");
    try stdout.writeAll("  ");
    try tui.theme.paintBold(io, stdout, .success, safe_id);
    if (enabled) |en| {
        try stdout.writeAll("  ");
        try tui.theme.paint(io, stdout, if (en) .success else .muted, if (en) "[enabled]" else "[available]");
    }
    try stdout.writeAll("\n");
    try stdout.writeAll("Name         ");
    try stdout.writeAll(safe_name);
    try stdout.writeAll("\n");
    if (category.len > 0) {
        const safe_cat = try trackSanitized(allocator, &owned, category);
        try stdout.writeAll("Category     ");
        try stdout.writeAll(safe_cat);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("Description  ");
    try tui.render.writeWrappedWidth(stdout, safe_desc, 13, 80);
    try stdout.writeAll("\n");
    try stdout.print("Patterns     {d} safe / {d} destructive\n", .{ detail.safe_pattern_count, detail.destructive_pattern_count });

    if (!no_patterns) {
        if (detail.destructive_patterns) |destructive| {
            try stdout.writeAll("\n");
            try tui.theme.paintBold(io, stdout, .text_bright, "Destructive rules");
            try stdout.print(" ({d})\n", .{destructive.len});
            for (destructive) |rule| {
                const name = try trackSanitized(allocator, &owned, rule.name);
                const severity = try trackSanitized(allocator, &owned, rule.severity);
                const reason = try trackSanitized(allocator, &owned, rule.reason);
                try stdout.writeAll("  • ");
                try tui.theme.paintBold(io, stdout, .danger, name);
                try stdout.writeAll("  ");
                try tui.theme.paint(io, stdout, .danger, severity);
                try stdout.writeAll("\n    ");
                try tui.render.writeWrappedWidth(stdout, reason, 4, 80);
                try stdout.writeAll("\n");
                if (rule.explanation) |explanation| {
                    const expl = try trackSanitized(allocator, &owned, explanation);
                    try stdout.writeAll("    ");
                    try tui.render.writeWrappedWidth(stdout, expl, 4, 80);
                    try stdout.writeAll("\n");
                }
                for (rule.suggestions) |sug| {
                    const cmd = try trackSanitized(allocator, &owned, sug.command);
                    try stdout.writeAll("    Try: ");
                    try stdout.writeAll(cmd);
                    try stdout.writeAll("\n");
                }
                if (verbose and rule.regex.len > 0) {
                    const rx = try trackSanitized(allocator, &owned, rule.regex);
                    try stdout.writeAll("    regex: ");
                    try stdout.writeAll(rx);
                    try stdout.writeAll("\n");
                }
            }
        }
        if (detail.safe_patterns) |safe| {
            try stdout.writeAll("\n");
            try tui.theme.paintBold(io, stdout, .text_bright, "Safe rules");
            try stdout.print(" ({d})\n", .{safe.len});
            try stdout.writeAll("  ");
            var first = true;
            for (safe) |rule| {
                if (!first) try stdout.writeAll(", ");
                first = false;
                const name = try trackSanitized(allocator, &owned, rule.name);
                try stdout.writeAll(name);
                if (verbose and rule.regex.len > 0) {
                    const rx = try trackSanitized(allocator, &owned, rule.regex);
                    try stdout.writeAll(" (");
                    try stdout.writeAll(rx);
                    try stdout.writeAll(")");
                }
            }
            try stdout.writeAll("\n");
        }
    }

    try stdout.writeAll("\nNext: orca packs enable ");
    try stdout.writeAll(safe_id);
    try stdout.writeAll("  ·  orca test \"…\"\n");
    return exit_codes.success;
}

fn runEnable(comptime execute_cli: anytype, io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const allocator = std.heap.smp_allocator;
    const ids = parseIdList(argv, stderr) catch return exit_codes.usage;

    // Validate against registry when daemon list is available.
    var unknown: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unknown.deinit(allocator);
    var list_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer list_stdout.deinit();
    var list_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer list_stderr.deinit();
    var registry_known = false;
    if (execute_cli(io, &.{ "packs", "--format", "json" }, &list_stdout.writer, &list_stderr.writer)) |list_code| {
        if (list_code == exit_codes.success) {
            if (contracts.parsePacks(allocator, list_stdout.written())) |parsed| {
                defer parsed.deinit();
                registry_known = true;
                for (ids) |id| {
                    if (pack_state.isBaselinePackId(id)) continue;
                    var found = false;
                    for (parsed.value.packs) |pack| {
                        if (std.mem.eql(u8, pack.id, id)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try unknown.append(allocator, id);
                }
            } else |_| {}
        }
    } else |_| {}

    if (unknown.items.len > 0) {
        try stderr.print(
            "ryk packs: unknown pack id '{s}'. Run 'orca packs --filter {s}' or 'orca packs show {s}'.\n",
            .{ unknown.items[0], unknown.items[0], unknown.items[0] },
        );
        return exit_codes.usage;
    }

    const workspace_root = onboarding.resolveWorkspaceRoot(io, allocator) catch {
        try stderr.writeAll("ryk packs: could not resolve workspace root.\n");
        return exit_codes.general;
    };
    defer allocator.free(workspace_root);

    var result = pack_state.enablePacks(io, allocator, workspace_root, ids) catch |err| {
        try stderr.print("ryk packs enable: {s}. Run 'ryk help packs' for usage.\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer result.deinit(allocator);

    return printMutationResult(io, stdout, result, registry_known);
}

fn runDisable(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const allocator = std.heap.smp_allocator;
    const ids = parseIdList(argv, stderr) catch return exit_codes.usage;

    const workspace_root = onboarding.resolveWorkspaceRoot(io, allocator) catch {
        try stderr.writeAll("ryk packs: could not resolve workspace root.\n");
        return exit_codes.general;
    };
    defer allocator.free(workspace_root);

    var result = pack_state.disablePacks(io, allocator, workspace_root, ids) catch |err| {
        try stderr.print("ryk packs disable: {s}. Run 'ryk help packs' for usage.\n", .{@errorName(err)});
        return exit_codes.general;
    };
    defer result.deinit(allocator);

    return printMutationResult(io, stdout, result, true);
}

fn parseIdList(argv: []const []const u8, stderr: anytype) ![]const []const u8 {
    if (argv.len == 0) return usageError(stderr, "requires at least one pack id");
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return usageError(stderr, "unexpected option");
        if (arg.len == 0) return usageError(stderr, "pack id must be non-empty");
    }
    return argv;
}

fn printMutationResult(io: std.Io, stdout: anytype, result: pack_state.PackMutationResult, registry_known: bool) !u8 {
    try tui.theme.paintBold(io, stdout, .text_bright, "Safety packs");
    try stdout.writeAll("\n");
    try stdout.writeAll(result.message);
    try stdout.writeAll("\n");
    if (result.config_path) |path| {
        try stdout.writeAll("  Config: ");
        try stdout.writeAll(path);
        if (result.scope) |scope| {
            try stdout.print(" ({s})", .{scope.label()});
        }
        try stdout.writeAll("\n");
    }
    if (!registry_known) {
        try stdout.writeAll("  Note: daemon unavailable; pack ids were not verified against the registry.\n");
    }
    if (result.added.len > 0) {
        try stdout.writeAll("  Next:   orca packs show ");
        try stdout.writeAll(result.added[0]);
        try stdout.writeAll("\n          orca test \"…\"\n");
    } else if (result.removed.len > 0 or result.disabled_added.len > 0) {
        try stdout.writeAll("  Next:   orca packs --enabled\n");
    } else {
        try stdout.writeAll("  Next:   orca packs --enabled  ·  orca packs show <id>\n");
    }
    return exit_codes.success;
}

fn shouldPassThrough(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--robot") or std.mem.eql(u8, arg, "--expand") or
            std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v") or
            std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f") or
            std.mem.startsWith(u8, arg, "--format=") or std.mem.eql(u8, arg, "--max-patterns") or
            std.mem.startsWith(u8, arg, "--max-patterns=")) return true;
    }
    return false;
}

fn parseOptions(argv: []const []const u8, stderr: anytype) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--installed") or std.mem.eql(u8, arg, "--enabled")) {
            options.installed = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0 or std.mem.startsWith(u8, argv[i], "--"))
                return usageError(stderr, "--filter requires a non-empty search term");
            options.filter = argv[i];
        } else if (std.mem.eql(u8, arg, "--page")) {
            i += 1;
            if (i >= argv.len) return usageError(stderr, "--page requires a positive integer");
            options.page = std.fmt.parseInt(usize, argv[i], 10) catch return usageError(stderr, "--page requires a positive integer");
            if (options.page == 0) return usageError(stderr, "--page requires a positive integer");
        } else if (std.mem.eql(u8, arg, "--page-size")) {
            i += 1;
            if (i >= argv.len) return usageError(stderr, "--page-size requires a positive integer");
            options.page_size = std.fmt.parseInt(usize, argv[i], 10) catch return usageError(stderr, "--page-size requires a positive integer");
            if (options.page_size == 0) return usageError(stderr, "--page-size requires a positive integer");
        } else {
            suggestions.writeUnknownOption(stderr, "ryk packs", arg, &.{ "--installed", "--enabled", "--filter", "--page", "--page-size" }, "packs") catch {};
            return error.InvalidArguments;
        }
    }
    return options;
}

fn usageError(stderr: anytype, message: []const u8) error{InvalidArguments} {
    stderr.print("ryk packs: {s}. Run 'ryk help packs' for usage.\n", .{message}) catch {};
    return error.InvalidArguments;
}

fn renderHuman(io: std.Io, options: Options, output: contracts.PacksOutput, stdout: anytype, stderr: anytype) !u8 {
    return renderHumanAlloc(std.heap.smp_allocator, io, options, output, stdout, stderr);
}

fn renderHumanAlloc(allocator: std.mem.Allocator, io: std.Io, options: Options, output: contracts.PacksOutput, stdout: anytype, stderr: anytype) !u8 {
    var selected: std.ArrayListUnmanaged(contracts.PackInfo) = .empty;
    defer selected.deinit(allocator);
    for (output.packs) |pack| {
        if (options.installed and !pack.enabled) continue;
        if (options.filter) |term| {
            if (!containsIgnoreCase(pack.id, term) and !containsIgnoreCase(pack.name, term) and
                !containsIgnoreCase(pack.category, term) and !containsIgnoreCase(pack.description, term)) continue;
        }
        try selected.append(allocator, pack);
    }
    std.mem.sort(contracts.PackInfo, selected.items, {}, lessThanPack);

    if (selected.items.len == 0) {
        try tui.render.callout(io, stdout, .info, "No safety packs found", if (options.filter != null)
            "Try a broader --filter term, or run 'orca packs' to list all packs."
        else if (options.installed)
            "No opt-in packs enabled. Enable more with `orca packs enable <id>` (baseline is always on)."
        else
            "Run 'orca doctor' to verify the daemon and pack configuration.");
        return exit_codes.success;
    }

    const total_pages = 1 + (selected.items.len - 1) / options.page_size;
    if (options.page > total_pages) {
        return usageExit(stderr, "--page is beyond the available filtered results");
    }

    const start = std.math.mul(usize, options.page - 1, options.page_size) catch
        return usageExit(stderr, "--page and --page-size are too large");
    const end = @min(selected.items.len, std.math.add(usize, start, options.page_size) catch selected.items.len);
    const page_items = selected.items[start..end];

    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |value| allocator.free(value);
        owned.deinit(allocator);
    }
    try tui.theme.paintBold(io, stdout, .text_bright, "Safety packs");
    try stdout.writeAll("\n\n");
    for (page_items) |pack| {
        const safe_id = try tui.terminal_text.sanitizeAlloc(allocator, pack.id, .single_line);
        owned.append(allocator, safe_id) catch |err| {
            allocator.free(safe_id);
            return err;
        };
        const safe_category = try tui.terminal_text.sanitizeAlloc(allocator, pack.category, .single_line);
        owned.append(allocator, safe_category) catch |err| {
            allocator.free(safe_category);
            return err;
        };
        const safe_description = try tui.terminal_text.sanitizeAlloc(allocator, pack.description, .single_line);
        owned.append(allocator, safe_description) catch |err| {
            allocator.free(safe_description);
            return err;
        };
        const patterns = try std.fmt.allocPrint(allocator, "{d} safe / {d} blocked", .{ pack.safe_pattern_count, pack.destructive_pattern_count });
        owned.append(allocator, patterns) catch |err| {
            allocator.free(patterns);
            return err;
        };
        try stdout.writeAll("  ");
        try tui.theme.paintBold(io, stdout, if (pack.enabled) .success else .text_bright, if (pack.enabled) "●" else "○");
        try stdout.writeAll(" ");
        try tui.render.writeTruncated(stdout, safe_id, 60);
        try stdout.writeAll("  ");
        try tui.theme.paint(io, stdout, if (pack.enabled) .success else .muted, if (pack.enabled) "[enabled]" else "[available]");
        try stdout.writeAll("\n    ");
        try tui.render.writeTruncated(stdout, safe_category, 28);
        try stdout.writeAll(" · ");
        try stdout.writeAll(patterns);
        try stdout.writeAll("\n");
        try tui.render.writeWrappedWidth(stdout, safe_description, 4, 80);
        try stdout.writeAll("\n\n");
    }
    try stdout.print("Page {d} of {d} · {d} pack(s)\n", .{ options.page, total_pages, selected.items.len });
    return exit_codes.success;
}

fn usageExit(stderr: anytype, message: []const u8) u8 {
    usageError(stderr, message) catch {};
    return exit_codes.usage;
}

fn lessThanPack(_: void, lhs: contracts.PackInfo, rhs: contracts.PackInfo) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matches = true;
        for (needle, 0..) |char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(char)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

test "human packs requests daemon JSON instead of parsing pretty output" {
    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithExecutor(fakePacksJson, std.testing.io, &.{}, &stdout_writer, &stderr_writer);

    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Safety packs") != null);
}

fn fakePacksJson(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try std.testing.expectEqualSlices([]const u8, &.{ "packs", "--format", "json" }, argv);
    try stdout.writeAll(
        \\{"packs":[{"id":"core.git","name":"Git","category":"core","description":"Protects Git","enabled":true,"safe_pattern_count":2,"destructive_pattern_count":3}],"enabled_count":1,"total_count":1}
    );
    return exit_codes.success;
}

test "packs filters sorts paginates and sanitizes daemon fields" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try commandWithExecutor(fakeUnsortedPacksJson, std.testing.io, &.{ "--filter", "DATA", "--page", "1", "--page-size", "1" }, &stdout_writer, &stderr_writer);
    const rendered = stdout_writer.buffered();
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "database.mysql") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "database.postgresql") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Page 1 of 2") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 0x1b) == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "packs installed alias uses daemon enabled semantics and renders empty guidance" {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeEnabledPacksEmpty, std.testing.io, &.{"--installed"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "No safety packs found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "packs enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "config.toml") == null);
}

test "packs machine raw modes are byte identical passthrough" {
    const Case = struct { args: []const []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "--format", "json" }, .expected = "packs|--format|json" },
        .{ .args = &.{"--robot"}, .expected = "packs|--robot" },
        .{ .args = &.{ "-f", "json" }, .expected = "packs|-f|json" },
        .{ .args = &.{"--format=json"}, .expected = "packs|--format=json" },
        .{ .args = &.{ "--format", "pretty" }, .expected = "packs|--format|pretty" },
        .{ .args = &.{"--expand"}, .expected = "packs|--expand" },
        .{ .args = &.{ "--max-patterns", "7" }, .expected = "packs|--max-patterns|7" },
        .{ .args = &.{"--max-patterns=7"}, .expected = "packs|--max-patterns=7" },
    };
    for (cases) |case| {
        var stdout_buf: [128]u8 = undefined;
        var stderr_buf: [128]u8 = undefined;
        var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
        const code = try commandWithExecutor(fakePassthrough, std.testing.io, case.args, &stdout_writer, &stderr_writer);
        try std.testing.expectEqual(@as(u8, 23), code);
        try std.testing.expectEqualStrings(case.expected, stdout_writer.buffered());
        try std.testing.expectEqualStrings("daemon exact stderr\n", stderr_writer.buffered());
    }
}

test "packs --help is Zig-owned and does not call the daemon" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(failIfCalled, std.testing.io, &.{"--help"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "safety packs") != null or std.mem.indexOf(u8, out, "Safety packs") != null or std.mem.indexOf(u8, out, "packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "show") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk packs") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "packs rejects missing and invalid Zig option values with remediation" {
    const cases = [_][]const []const u8{
        &.{"--filter"}, &.{ "--page", "0" }, &.{ "--page", "nope" }, &.{ "--page-size", "0" }, &.{"--unknown"},
    };
    for (cases) |args| {
        var stdout_buf: [64]u8 = undefined;
        var stderr_buf: [256]u8 = undefined;
        var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
        const code = try commandWithExecutor(failIfCalled, std.testing.io, args, &stdout_writer, &stderr_writer);
        try std.testing.expectEqual(exit_codes.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help packs") != null);
    }
}

test "packs sanitizes fields before deterministic compact layout" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeHostilePacksJson, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings(
        "Safety packs\n\n" ++
            "  ● db.mysql  [enabled]\n" ++
            "    database · 3 safe / 4 blocked\n" ++
            "    safe line\n\n" ++
            "Page 1 of 1 · 1 pack(s)\n",
        stdout_writer.buffered(),
    );
}

test "packs human layout does not exceed eighty columns" {
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeWidePackJson, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    var lines = std.mem.splitScalar(u8, stdout_writer.buffered(), '\n');
    while (lines.next()) |line| {
        try std.testing.expect(tui.render.displayWidth(line) <= 80);
    }
}

test "packs rejects pages beyond filtered results including max usize" {
    const max_page = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{std.math.maxInt(usize)});
    defer std.testing.allocator.free(max_page);
    const cases = [_][]const []const u8{
        &.{ "--filter", "git", "--page", "2" },
        &.{ "--page", max_page, "--page-size", max_page },
    };
    for (cases) |args| {
        var stdout_buf: [64]u8 = undefined;
        var stderr_buf: [256]u8 = undefined;
        var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
        const code = try commandWithExecutor(fakeUnsortedPacksJson, std.testing.io, args, &stdout_writer, &stderr_writer);
        try std.testing.expectEqual(exit_codes.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "page") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help packs") != null);
    }
}

test "packs daemon failures preserve stdout stderr and exit code" {
    var stdout_buf: [128]u8 = undefined;
    var stderr_buf: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeDaemonFailure, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(@as(u8, 17), code);
    try std.testing.expectEqualStrings("daemon partial stdout\n", stdout_writer.buffered());
    try std.testing.expectEqualStrings("daemon exact stderr\n", stderr_writer.buffered());
}

test "packs invalid daemon JSON gives doctor remediation without leaking payload" {
    var stdout_buf: [128]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeInvalidJson, std.testing.io, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, code);
    try std.testing.expectEqualStrings("", stdout_writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "TOP_SECRET") == null);
}

test "packs row construction cleans completed rows on later allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderPacksAllocationFailureProbe, .{});
}

fn renderPacksAllocationFailureProbe(allocator: std.mem.Allocator) !void {
    const pack_rows = [_]contracts.PackInfo{
        .{ .id = "core.git", .name = "Git", .category = "core", .description = "Protects Git", .enabled = true, .safe_pattern_count = 2, .destructive_pattern_count = 3 },
        .{ .id = "database.mysql", .name = "MySQL", .category = "database", .description = "Protects MySQL", .enabled = false, .safe_pattern_count = 4, .destructive_pattern_count = 5 },
    };
    const output: contracts.PacksOutput = .{ .packs = &pack_rows, .enabled_count = 1, .total_count = 2 };
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    _ = renderHumanAlloc(allocator, std.testing.io, .{}, output, &stdout_writer, &stderr_writer) catch |err| switch (err) {
        // AllocatingWriter intentionally erases allocator failures to WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
}

fn fakeUnsortedPacksJson(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try std.testing.expectEqualSlices([]const u8, &.{ "packs", "--format", "json" }, argv);
    try stdout.writeAll(
        \\{"packs":[{"id":"database.postgresql","name":"Postgres","category":"database","description":"Postgres","enabled":false,"safe_pattern_count":1,"destructive_pattern_count":2},{"id":"database.mysql","name":"MySQL","category":"database","description":"MySQL\u001b[2J","enabled":true,"safe_pattern_count":3,"destructive_pattern_count":4},{"id":"core.git","name":"Git","category":"core","description":"Git","enabled":true,"safe_pattern_count":2,"destructive_pattern_count":3}],"enabled_count":2,"total_count":3}
    );
    return exit_codes.success;
}

fn fakeEnabledPacksEmpty(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try std.testing.expectEqualSlices([]const u8, &.{ "packs", "--enabled", "--format", "json" }, argv);
    try stdout.writeAll("{\"packs\":[],\"enabled_count\":0,\"total_count\":3}");
    return exit_codes.success;
}

fn fakeHostilePacksJson(_: std.Io, _: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try stdout.writeAll(
        \\{"packs":[{"id":"db.\u001b[2Jmysql","name":"MySQL","category":"data\u001b]0;x\u0007base","description":"safe\nline","enabled":true,"safe_pattern_count":3,"destructive_pattern_count":4}],"enabled_count":1,"total_count":1}
    );
    return exit_codes.success;
}

fn fakeWidePackJson(_: std.Io, _: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try stdout.writeAll(
        \\{"packs":[{"id":"infrastructure.fastly.edge.service","name":"Fastly","category":"infrastructure","description":"Protects against destructive Fastly CLI operations like service, domain, backend, and VCL deletion.","enabled":false,"safe_pattern_count":10,"destructive_pattern_count":6}],"enabled_count":0,"total_count":1}
    );
    return exit_codes.success;
}

fn fakeDaemonFailure(_: std.Io, _: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    try stdout.writeAll("daemon partial stdout\n");
    try stderr.writeAll("daemon exact stderr\n");
    return 17;
}

fn fakeInvalidJson(_: std.Io, _: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try stdout.writeAll("{TOP_SECRET:not-json}");
    return exit_codes.success;
}

fn fakePassthrough(_: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    for (argv, 0..) |arg, index| {
        if (index > 0) try stdout.writeByte('|');
        try stdout.writeAll(arg);
    }
    try stderr.writeAll("daemon exact stderr\n");
    return 23;
}

fn failIfCalled(_: std.Io, _: []const []const u8, _: anytype, _: anytype) !u8 {
    return error.UnexpectedExecutorCall;
}

fn fakePackInfoAndList(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "pack")) {
        try std.testing.expect(argv.len >= 4);
        try std.testing.expectEqualStrings("info", argv[1]);
        try std.testing.expectEqualStrings("core.git", argv[2]);
        try std.testing.expectEqualStrings("--json", argv[3]);
        try stdout.writeAll(
            \\{"id":"core.git","name":"Git","description":"Protects destructive Git operations","keywords":["git"],"safe_pattern_count":2,"destructive_pattern_count":1,"safe_patterns":[{"name":"status","regex":"^git status$"}],"destructive_patterns":[{"name":"force-push","regex":"git push --force","severity":"critical","reason":"Rewrites remote history","suggestions":[{"command":"git push --force-with-lease","description":"Safer force push"}]}]}
        );
        return exit_codes.success;
    }
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "packs")) {
        try stdout.writeAll(
            \\{"packs":[{"id":"core.git","name":"Git","category":"core","description":"Protects Git","enabled":true,"safe_pattern_count":2,"destructive_pattern_count":1}],"enabled_count":1,"total_count":1}
        );
        return exit_codes.success;
    }
    return error.UnexpectedExecutorCall;
}

fn fakePackInfoMissing(_: std.Io, argv: []const []const u8, _: anytype, stderr: anytype) !u8 {
    try std.testing.expectEqualStrings("pack", argv[0]);
    try stderr.writeAll("Pack not found: no.such.pack\n");
    return 1;
}

fn fakeRegistryForEnable(_: std.Io, argv: []const []const u8, stdout: anytype, _: anytype) !u8 {
    try std.testing.expectEqualStrings("packs", argv[0]);
    try stdout.writeAll(
        \\{"packs":[{"id":"containers.docker","name":"Docker","category":"containers","description":"d","enabled":false,"safe_pattern_count":1,"destructive_pattern_count":1}],"enabled_count":0,"total_count":1}
    );
    return exit_codes.success;
}

test "packs show renders human detail without raw regex by default" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakePackInfoAndList, std.testing.io, &.{ "show", "core.git" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "core.git") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "force-push") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "critical") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Rewrites remote history") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "git push --force-with-lease") != null);
    // Raw regex must stay hidden unless --verbose (suggestion text may share substrings).
    try std.testing.expect(std.mem.indexOf(u8, out, "regex:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^git status$") == null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());
}

test "packs show missing pack returns remediation" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakePackInfoMissing, std.testing.io, &.{ "show", "no.such.pack" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "Pack not found") != null);
}

test "packs show requires pack id" {
    var stdout_buf: [64]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(failIfCalled, std.testing.io, &.{"show"}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help packs") != null);
}

test "packs enable and disable require pack ids" {
    const cases = [_][]const []const u8{
        &.{"enable"},
        &.{"disable"},
    };
    for (cases) |args| {
        var stdout_buf: [64]u8 = undefined;
        var stderr_buf: [256]u8 = undefined;
        var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
        const code = try commandWithExecutor(failIfCalled, std.testing.io, args, &stdout_writer, &stderr_writer);
        try std.testing.expectEqual(exit_codes.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk help packs") != null);
    }
}

test "packs enable rejects unknown pack ids when registry is available" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakeRegistryForEnable, std.testing.io, &.{ "enable", "no.such.pack" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "unknown pack id") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "ryk packs --filter") != null);
}

test "packs info is an alias for show" {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const code = try commandWithExecutor(fakePackInfoAndList, std.testing.io, &.{ "info", "core.git" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Safety pack") != null);
}
