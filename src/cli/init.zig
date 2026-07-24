const std = @import("std");

const orca_policy = @import("orca_core").policy;
const core = @import("orca_core").core;
const exit_codes = @import("exit_codes.zig");
const help = @import("help.zig");
const style = @import("style.zig");
const suggestions = @import("suggestions.zig");
const pack_state = @import("pack_state.zig");

const InitOptions = struct {
    mode: ?[]const u8 = null,
    preset: orca_policy.presets.AgentPreset = .generic_agent,
    force: bool = false,
    quiet: bool = false,
};

pub fn command(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    const options = parseOptions(io, argv, stdout, stderr) catch |err| switch (err) {
        error.HelpShown => return exit_codes.success,
        error.Usage => return exit_codes.usage,
        else => return err,
    };

    cwd.createDirPath(io, ".orca") catch |err| {
        try stderr.print("ryk init: failed to create .orca: {s}\n", .{@errorName(err)});
        return exit_codes.general;
    };

    const flags: std.Io.Dir.CreateFileOptions = if (options.force) .{} else .{ .exclusive = true };
    const file = cwd.createFile(io, ".orca/policy.yaml", flags) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try stderr.writeAll("ryk init: .orca/policy.yaml already exists; use --force to overwrite.\n");
            return exit_codes.general;
        },
        else => {
            try stderr.print("ryk init: failed to write .orca/policy.yaml: {s}\n", .{@errorName(err)});
            return exit_codes.general;
        },
    };
    defer file.close(io);

    const preset_text = orca_policy.presets.agentPresetText(options.preset);
    try writePolicy(io, file, preset_text, options.mode);
    const info = orca_policy.presets.agentPresetInfo(options.preset);

    // Additive pack enablement for the daemon evaluator (project `.orca.toml` when in a git
    // repo, else user config). Zig still owns policy.yaml; packs config is additive.
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Resolve workspace from the init cwd (avoid importing onboarding — circular with init).
    const cwd_path = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd_path);
    const workspace_root = core.supervisor.resolveWorkspaceRoot(io, allocator, null, cwd_path) catch try allocator.dupe(u8, cwd_path);
    defer allocator.free(workspace_root);

    var packs_result = pack_state.ensurePresetPacks(io, allocator, workspace_root, options.preset) catch pack_state.EnsurePacksResult{
        .message = "Packs: baseline only (pack config write skipped)",
        .owned = false,
    };
    defer packs_result.deinit(allocator);

    if (!options.quiet) {
        // Warm success message: format into a buffer so it can route through
        // maybeColor, matching the style of setup.zig and run.zig warm paths.
        try stdout.writeAll("\n");
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} Created .orca/policy.yaml from preset '{s}'.\n", .{ style.Glyph.check, info.name }) catch null;
        if (msg) |m| {
            try style.maybeColor(io, stdout, style.Style.green, m);
        } else {
            // Buffer too small (should never happen): fall back to manual gating.
            if (style.useColor(io, stdout)) {
                try stdout.writeAll(style.Style.green);
                try stdout.print("{s} Created .orca/policy.yaml from preset '{s}'.\n", .{ style.Glyph.check, info.name });
                try stdout.writeAll(style.Style.reset);
            } else {
                try stdout.print("{s} Created .orca/policy.yaml from preset '{s}'.\n", .{ style.Glyph.check, info.name });
            }
        }
        try stdout.print("{s}\n", .{packs_result.message});
        if (packs_result.config_path) |path| {
            try stdout.print("  Pack config ({s}): {s}\n", .{ packs_result.scope.?.label(), path });
        }
        if (info.experimental) try stdout.print("Warning: {s}\n", .{info.warning});
        try stdout.writeAll("\n" ++
            "Your policy is ready.\n" ++
            "\n" ++
            "Next steps:\n" ++
            "  ryk policy check .orca/policy.yaml\n" ++
            "  orca status\n" ++
            "  orca doctor\n" ++
            "  ryk run -- <command>\n" ++
            "\n");
    }
    return exit_codes.success;
}

fn parseOptions(io: std.Io, argv: []const []const u8, stdout: anytype, stderr: anytype) !InitOptions {
    var options: InitOptions = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try help.writeCommand(io, stdout, "init");
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--ci")) {
            options.mode = "ci";
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--preset")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("ryk init: --preset requires a preset name.\n");
                return error.Usage;
            }
            const preset = orca_policy.presets.AgentPreset.parse(argv[index]) orelse {
                try suggestions.writeInvalidValue(stderr, "ryk init", "--preset", argv[index], &.{ "generic-agent", "claude-code", "codex", "cursor-agent", "opencode", "cline-roo", "mcp-dev", "github-actions", "solo-dev", "strict-local", "team-ci", "openclaw-hermes", "trusted-local" }, "init");
                return error.Usage;
            };
            options.preset = preset;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            index += 1;
            if (index >= argv.len) {
                try stderr.writeAll("ryk init: --mode requires strict, ask, observe, ci, or trusted.\n");
                return error.Usage;
            }
            const mode = argv[index];
            if (!isValidMode(mode)) {
                try suggestions.writeInvalidValue(stderr, "ryk init", "--mode", mode, &.{ "strict", "ask", "observe", "ci", "trusted" }, "init");
                return error.Usage;
            }
            options.mode = mode;
        } else {
            try suggestions.writeUnknownOption(stderr, "ryk init", arg, &.{ "--force", "--ci", "--quiet", "--preset", "--mode", "--help", "-h" }, "init");
            return error.Usage;
        }
    }
    return options;
}

fn isValidMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "strict") or
        std.mem.eql(u8, mode, "ask") or
        std.mem.eql(u8, mode, "observe") or
        std.mem.eql(u8, mode, "ci") or
        std.mem.eql(u8, mode, "trusted");
}

fn writePolicy(io: std.Io, file: std.Io.File, preset_text: []const u8, mode_override: ?[]const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    if (mode_override) |mode| {
        var lines = std.mem.splitScalar(u8, preset_text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "mode:")) {
                try writer.interface.print("mode: {s}\n", .{mode});
            } else {
                try writer.interface.writeAll(line);
                try writer.interface.writeByte('\n');
            }
        }
        try writer.interface.flush();
        return;
    }
    try writer.interface.writeAll(preset_text);
    try writer.interface.flush();
}

test "init creates policy and refuses overwrite without force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, tmp.dir, &.{ "--mode", "strict" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);

    const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "version: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: strict") != null);

    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const second_code = try command(std.testing.io, tmp.dir, &.{}, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.general, second_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "already exists") != null);
}

test "init force overwrites existing policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const existing = try tmp.dir.createFile(std.testing.io, ".orca/policy.yaml", .{});
        defer existing.close(std.testing.io);
        try existing.writeStreamingAll(std.testing.io, "old\n");
    }

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, tmp.dir, &.{ "--mode", "observe", "--force" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());

    const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "mode: observe") != null);
}

test "init accepts generic-agent preset alias" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, tmp.dir, &.{ "--preset", "generic-agent", "--force" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "generic-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Packs: baseline only") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());

    const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "version: 1") != null);
}

test "init team-ci enables opt-in packs in project .orca.toml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git");

    var stdout_buf: [2048]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, tmp.dir, &.{ "--preset", "team-ci", "--force" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, code);
    const out = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Enabled packs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "containers.docker") != null);
    try std.testing.expectEqualStrings("", stderr_writer.buffered());

    const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(policy);
    try std.testing.expect(std.mem.indexOf(u8, policy, "version: 1") != null);

    const packs_cfg = try tmp.dir.readFileAlloc(std.testing.io, ".orca.toml", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(packs_cfg);
    try std.testing.expect(std.mem.indexOf(u8, packs_cfg, "containers.docker") != null);
    try std.testing.expect(std.mem.indexOf(u8, packs_cfg, "kubernetes.kubectl") != null);
    try std.testing.expect(std.mem.indexOf(u8, packs_cfg, "infrastructure.terraform") != null);

    // Idempotent re-run with force for policy only still merges packs without wiping.
    stdout_writer = .fixed(&stdout_buf);
    stderr_writer = .fixed(&stderr_buf);
    const second = try command(std.testing.io, tmp.dir, &.{ "--preset", "team-ci", "--force" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.success, second);
    const packs_cfg2 = try tmp.dir.readFileAlloc(std.testing.io, ".orca.toml", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(packs_cfg2);
    try std.testing.expect(std.mem.indexOf(u8, packs_cfg2, "containers.docker") != null);
}

test "init writes requested phase 18 presets as valid policies" {
    const sample_presets = [_][]const u8{ "generic-agent", "github-actions", "strict-local", "trusted-local" };
    for (sample_presets) |preset_name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var stdout_buf: [2048]u8 = undefined;
        var stderr_buf: [512]u8 = undefined;
        var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
        var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

        const code = try command(std.testing.io, tmp.dir, &.{ "--preset", preset_name, "--force" }, &stdout_writer, &stderr_writer);
        try std.testing.expectEqual(exit_codes.success, code);
        try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Next steps:") != null);
        // Warm success path (checkmark + "Your policy is ready")
        try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), style.Glyph.check ++ " Created") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), "Your policy is ready") != null);
        try std.testing.expectEqualStrings("", stderr_writer.buffered());

        const policy = try tmp.dir.readFileAlloc(std.testing.io, ".orca/policy.yaml", std.testing.allocator, .limited(16 * 1024));
        defer std.testing.allocator.free(policy);
        var loaded = try orca_policy.load.parseFromSlice(std.testing.allocator, policy, ".orca/policy.yaml");
        defer loaded.deinit();
        try orca_policy.validate.policy(&loaded);
    }
}

test "init rejects invalid preset names clearly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);

    const code = try command(std.testing.io, tmp.dir, &.{ "--preset", "not-real" }, &stdout_writer, &stderr_writer);
    try std.testing.expectEqual(exit_codes.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_writer.buffered(), "invalid --preset value 'not-real'") != null);
}
