const std = @import("std");
const builtin = @import("builtin");

pub const settings_relative_path = ".grok/user-settings.json";
pub const max_settings_size = 1024 * 1024;

pub const MergeResult = struct {
    bytes: []u8,
    changed: bool,
};

pub const InstallResult = struct {
    changed: bool,
    settings_path: []u8,

    pub fn deinit(self: InstallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.settings_path);
    }
};

/// Return whether the current user's Grok settings contain a ryk PreToolUse
/// hook. Invalid or unreadable settings are never reported as installed.
pub fn installed(io: std.Io, allocator: std.mem.Allocator) bool {
    const home_z = std.c.getenv("HOME") orelse return false;
    return installedAtHome(io, allocator, std.mem.span(home_z));
}

pub fn installedAtHome(io: std.Io, allocator: std.mem.Allocator, home: []const u8) bool {
    const settings_path = std.fs.path.join(allocator, &.{ home, settings_relative_path }) catch return false;
    defer allocator.free(settings_path);
    const settings = std.Io.Dir.cwd().readFileAlloc(
        io,
        settings_path,
        allocator,
        .limited(max_settings_size),
    ) catch return false;
    defer allocator.free(settings);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const hooks = parsed.value.object.get("hooks") orelse return false;
    if (hooks != .object) return false;
    const pre_tool_use = hooks.object.get("PreToolUse") orelse return false;
    if (pre_tool_use != .array) return false;
    for (pre_tool_use.array.items) |entry| {
        if (entryContainsAnyRykHook(entry)) return true;
    }
    return false;
}

/// Conservative identity check for stdout captured from a bounded `grok
/// --help` probe. All independent markers come from superagent-ai/grok-cli's
/// Commander surface; a name-only PATH hit must not be treated as compatible.
pub fn isSupportedCliHelp(help_output: []const u8) bool {
    return std.mem.indexOf(u8, help_output, "AI coding agent powered by Grok") != null and
        std.mem.indexOf(u8, help_output, "--prompt <prompt>") != null and
        std.mem.indexOf(u8, help_output, "--verify") != null and
        std.mem.indexOf(u8, help_output, "--batch-api") != null;
}

/// Merge ryk's Grok PreToolUse hook into an existing settings document.
///
/// The returned bytes are owned by `allocator`. Existing settings and hook
/// entries are retained in their original order. Invalid hook container shapes
/// are rejected instead of being overwritten.
pub fn mergeSettingsAlloc(
    allocator: std.mem.Allocator,
    existing: []const u8,
    ryk_binary: []const u8,
) !MergeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch
        return error.InvalidSettings;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;
    const tree_allocator = parsed.arena.allocator();

    const command = try hookCommandAlloc(allocator, ryk_binary);
    defer allocator.free(command);

    var hooks = parsed.value.object.getPtr("hooks");
    if (hooks == null) {
        try parsed.value.object.put(tree_allocator, "hooks", .{ .object = .empty });
        hooks = parsed.value.object.getPtr("hooks");
    }
    if (hooks.?.* != .object) return error.InvalidHooks;

    var pre_tool_use = hooks.?.object.getPtr("PreToolUse");
    if (pre_tool_use == null) {
        try hooks.?.object.put(tree_allocator, "PreToolUse", .{ .array = std.json.Array.init(tree_allocator) });
        pre_tool_use = hooks.?.object.getPtr("PreToolUse");
    }
    if (pre_tool_use.?.* != .array) return error.InvalidPreToolUseHooks;

    for (pre_tool_use.?.array.items) |entry| {
        if (entryContainsRykHook(entry, command)) {
            return .{
                .bytes = try allocator.dupe(u8, existing),
                .changed = false,
            };
        }
    }

    var command_hook: std.json.ObjectMap = .empty;
    try command_hook.put(tree_allocator, "type", .{ .string = "command" });
    try command_hook.put(tree_allocator, "command", .{ .string = command });
    try command_hook.put(tree_allocator, "timeout", .{ .integer = 30 });

    var command_hooks = std.json.Array.init(tree_allocator);
    try command_hooks.append(.{ .object = command_hook });

    var matcher: std.json.ObjectMap = .empty;
    try matcher.put(tree_allocator, "matcher", .{ .string = "bash" });
    try matcher.put(tree_allocator, "hooks", .{ .array = command_hooks });
    try pre_tool_use.?.array.append(.{ .object = matcher });

    const bytes = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    return .{ .bytes = bytes, .changed = true };
}

/// Install the Grok user hook under an explicit home directory. This is the
/// onboarding-friendly API and is deterministic in tests.
pub fn installAtHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
    ryk_binary: []const u8,
) !InstallResult {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHomePath;
    try ensureSafeGrokDirectory(io, allocator, home);

    const settings_path = try std.fs.path.join(allocator, &.{ home, settings_relative_path });
    errdefer allocator.free(settings_path);

    const existed = fileState(io, settings_path) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    const existing = std.Io.Dir.cwd().readFileAlloc(
        io,
        settings_path,
        allocator,
        .limited(max_settings_size),
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(existing);

    const merged = try mergeSettingsAlloc(allocator, existing, ryk_binary);
    defer allocator.free(merged.bytes);
    if (!merged.changed) {
        return .{ .changed = false, .settings_path = settings_path };
    }

    const nonce = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.ryk-{d}.tmp", .{ settings_path, nonce });
    defer allocator.free(temp_path);
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .exclusive = true });
    defer file.close(io);
    if (builtin.os.tag != .windows) {
        try file.setPermissions(io, @enumFromInt(0o600));
    }
    try file.writeStreamingAll(io, merged.bytes);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    try ensureSettingsUnchanged(io, allocator, settings_path, existing, existed);
    try std.Io.Dir.renameAbsolute(temp_path, settings_path, io);

    return .{ .changed = true, .settings_path = settings_path };
}

fn ensureSafeGrokDirectory(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !void {
    const home_stat = try std.Io.Dir.cwd().statFile(io, home, .{ .follow_symlinks = false });
    if (home_stat.kind != .directory) return error.UnsafeHomePath;

    const grok_dir = try std.fs.path.join(allocator, &.{ home, ".grok" });
    defer allocator.free(grok_dir);
    const stat = std.Io.Dir.cwd().statFile(io, grok_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().createDirPath(io, grok_dir);
            const created = try std.Io.Dir.cwd().statFile(io, grok_dir, .{ .follow_symlinks = false });
            if (created.kind != .directory) return error.UnsafeGrokDirectory;
            return;
        },
        else => return err,
    };
    if (stat.kind != .directory) return error.UnsafeGrokDirectory;
}

fn fileState(io: std.Io, path: []const u8) !bool {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.UnsafeSettingsPath;
    if (stat.kind != .file) return error.UnsafeSettingsPath;
    return true;
}

fn ensureSettingsUnchanged(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
    existed: bool,
) !void {
    if (!existed) {
        _ = fileState(io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return error.ConcurrentSettingsChange;
    }
    _ = try fileState(io, path);
    const current = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_size));
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, expected)) return error.ConcurrentSettingsChange;
}

fn hookCommandAlloc(allocator: std.mem.Allocator, ryk_binary: []const u8) ![]u8 {
    if (std.mem.trim(u8, ryk_binary, " \t\r\n").len == 0) return error.InvalidRykBinary;
    const quoted = try shellQuoteAlloc(allocator, ryk_binary);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "{s} hook grok PreToolUse", .{quoted});
}

fn shellQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, value, " \t\r\n'\"\\$`;&|<>()") == null) {
        return allocator.dupe(u8, value);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\"'\"'");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn entryContainsRykHook(entry: std.json.Value, expected_command: []const u8) bool {
    if (entry != .object) return false;
    const hooks = entry.object.get("hooks") orelse return false;
    if (hooks != .array) return false;
    for (hooks.array.items) |hook| {
        if (hook != .object) continue;
        const command = hook.object.get("command") orelse continue;
        if (command != .string) continue;
        if (std.mem.eql(u8, command.string, expected_command) or isRykGrokHookCommand(command.string)) return true;
    }
    return false;
}

fn entryContainsAnyRykHook(entry: std.json.Value) bool {
    if (entry != .object) return false;
    const hooks = entry.object.get("hooks") orelse return false;
    if (hooks != .array) return false;
    for (hooks.array.items) |hook| {
        if (hook != .object) continue;
        const command = hook.object.get("command") orelse continue;
        if (command == .string and isRykGrokHookCommand(command.string)) return true;
    }
    return false;
}

/// Recognize existing ryk Grok hook commands without matching arbitrary shell
/// command text that merely mentions ryk.
pub fn isRykGrokHookCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    const suffix = " hook grok PreToolUse";
    if (!std.mem.endsWith(u8, trimmed, suffix)) return false;
    const executable = std.mem.trim(u8, trimmed[0 .. trimmed.len - suffix.len], " \t\r\n'");
    return std.mem.eql(u8, std.fs.path.basename(executable), "ryk");
}

test "Grok settings merge preserves unrelated settings and existing hooks" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "apiKey": "synthetic-key",
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "matcher": "edit",
        \\        "hooks": [
        \\          {"type": "command", "command": "./existing-hook.sh", "timeout": 7}
        \\        ]
        \\      }
        \\    ],
        \\    "SessionStart": [
        \\      {"hooks": [{"type": "command", "command": "./welcome.sh"}]}
        \\    ]
        \\  }
        \\}
    ;

    const merged = try mergeSettingsAlloc(allocator, existing, "/opt/ryk/bin/ryk");
    defer allocator.free(merged.bytes);
    try std.testing.expect(merged.changed);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, merged.bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("synthetic-key", parsed.value.object.get("apiKey").?.string);
    const hooks = parsed.value.object.get("hooks").?.object;
    try std.testing.expect(hooks.get("SessionStart") != null);
    const pre_tool = hooks.get("PreToolUse").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), pre_tool.len);
    try std.testing.expectEqualStrings("./existing-hook.sh", pre_tool[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
    try std.testing.expectEqualStrings("/opt/ryk/bin/ryk hook grok PreToolUse", pre_tool[1].object.get("hooks").?.array.items[0].object.get("command").?.string);
}

test "Grok settings merge is idempotent and detects an existing ryk hook" {
    const allocator = std.testing.allocator;
    const first = try mergeSettingsAlloc(allocator, "{}", "ryk");
    defer allocator.free(first.bytes);
    try std.testing.expect(first.changed);

    const second = try mergeSettingsAlloc(allocator, first.bytes, "ryk");
    defer allocator.free(second.bytes);
    try std.testing.expect(!second.changed);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
}

test "Grok installed check requires a real ryk PreToolUse entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".grok");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".grok/user-settings.json",
        .data = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo unrelated\"}]}]}}",
    });
    try std.testing.expect(!installedAtHome(std.testing.io, std.testing.allocator, home));

    const result = try installAtHome(std.testing.io, std.testing.allocator, home, "/opt/ryk/bin/ryk");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(installedAtHome(std.testing.io, std.testing.allocator, home));
}

test "Grok CLI help evidence does not trust a binary name alone" {
    try std.testing.expect(!isSupportedCliHelp("grok 1.0\nUsage: grok [options]\n"));
    try std.testing.expect(isSupportedCliHelp(
        \\Usage: grok [options]
        \\AI coding agent powered by Grok — built with Bun and OpenTUI
        \\  -p, --prompt <prompt>  Run a single prompt headlessly
        \\  --verify              Run the built-in verify flow headlessly
        \\  --batch-api           Use xAI Batch API
    ));
}

test "Grok settings merge rejects malformed or incompatible hook configuration" {
    try std.testing.expectError(error.InvalidSettings, mergeSettingsAlloc(std.testing.allocator, "{", "ryk"));
    try std.testing.expectError(error.InvalidHooks, mergeSettingsAlloc(std.testing.allocator, "{\"hooks\":[]}", "ryk"));
    try std.testing.expectError(error.InvalidPreToolUseHooks, mergeSettingsAlloc(std.testing.allocator, "{\"hooks\":{\"PreToolUse\":{}}}", "ryk"));
}

test "Grok installer writes atomically and preserves the previous settings file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    try tmp.dir.createDirPath(std.testing.io, ".grok");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".grok/user-settings.json",
        .data = "{\"defaultModel\":\"grok-test\",\"hooks\":{\"SessionEnd\":[{\"hooks\":[]}]}}\n",
    });

    const first = try installAtHome(std.testing.io, std.testing.allocator, home, "/usr/local/bin/ryk");
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.changed);

    const settings_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".grok", "user-settings.json" });
    defer std.testing.allocator.free(settings_path);
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, settings_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(written);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("grok-test", parsed.value.object.get("defaultModel").?.string);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"SessionEnd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/usr/local/bin/ryk hook grok PreToolUse") != null);

    const second = try installAtHome(std.testing.io, std.testing.allocator, home, "/usr/local/bin/ryk");
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!second.changed);
}

test "Grok installer rejects a symlinked configuration directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "redirect");
    tmp.dir.symLink(std.testing.io, "redirect", ".grok", .{}) catch return error.SkipZigTest;
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    try std.testing.expectError(
        error.UnsafeGrokDirectory,
        installAtHome(std.testing.io, std.testing.allocator, home, "/opt/ryk/bin/ryk"),
    );
}
