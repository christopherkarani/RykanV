const std = @import("std");

pub const Policy = struct { rich: bool };

pub fn resolve(no_rich_env: bool, no_rich_flag: bool, machine_output: bool) Policy {
    return .{ .rich = !no_rich_env and !no_rich_flag and !machine_output };
}

pub fn envDisablesRich(value: ?[]const u8) bool {
    const raw = value orelse return false;
    if (raw.len == 0) return false;
    return !std.mem.eql(u8, raw, "0") and !std.ascii.eqlIgnoreCase(raw, "false");
}

/// Pure argv scan: machine/plain/no-rich escapes that must never open an alt-screen TUI.
/// Recognises `--json`, `--robot`, `--plain`, `--no-rich`, `--format=json`, and
/// `--format` followed by `json`. Does not treat other `--format` values as escapes.
pub fn argvDisablesTui(argv: []const []const u8) bool {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json") or
            std.mem.eql(u8, arg, "--robot") or
            std.mem.eql(u8, arg, "--plain") or
            std.mem.eql(u8, arg, "--no-rich") or
            std.mem.eql(u8, arg, "--format=json"))
        {
            return true;
        }
        if (std.mem.eql(u8, arg, "--format") and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], "json")) {
            return true;
        }
    }
    return false;
}

/// Central pure TUI entry gate for packs / allowlist / doctor (and similar browse TUIs).
///
/// Returns true only when both stdin and stdout are TTYs **and** argv does not
/// request machine/plain/no-rich output. Inject TTY flags in tests — never requires
/// a real Tty loop or alt-screen.
///
/// Fail-closed: non-TTY on either stream, or any recognised escape hatch → false.
pub fn shouldEnterTui(stdin_is_tty: bool, stdout_is_tty: bool, argv: []const []const u8) bool {
    if (!stdin_is_tty or !stdout_is_tty) return false;
    return !argvDisablesTui(argv);
}

/// Runtime convenience: probe real stdin/stdout TTYs, then apply `shouldEnterTui`.
/// Prefer the pure form in tests and when TTY state is already known.
pub fn shouldEnterTuiIo(io: std.Io, argv: []const []const u8) bool {
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    return shouldEnterTui(stdin_tty, stdout_tty, argv);
}

test "rich output escape hatches are fail-safe" {
    try std.testing.expect(resolve(false, false, false).rich);
    try std.testing.expect(!resolve(true, false, false).rich);
    try std.testing.expect(!resolve(false, true, false).rich);
    try std.testing.expect(!resolve(false, false, true).rich);
    try std.testing.expect(!envDisablesRich("0"));
    try std.testing.expect(envDisablesRich("1"));
}

test "shouldEnterTui: true only for TTY pair with no machine/plain/no-rich escapes" {
    // Happy path: interactive colour TTY pair, bare command argv.
    try std.testing.expect(shouldEnterTui(true, true, &.{"packs"}));
    try std.testing.expect(shouldEnterTui(true, true, &.{ "allowlist", "list" }));
    try std.testing.expect(shouldEnterTui(true, true, &.{}));
    // Non-json format values do not disable TUI.
    try std.testing.expect(shouldEnterTui(true, true, &.{ "report", "--format", "human" }));
    try std.testing.expect(shouldEnterTui(true, true, &.{"--format=markdown"}));
}

test "shouldEnterTui: false when either stream is non-TTY" {
    try std.testing.expect(!shouldEnterTui(false, true, &.{"packs"}));
    try std.testing.expect(!shouldEnterTui(true, false, &.{"packs"}));
    try std.testing.expect(!shouldEnterTui(false, false, &.{"packs"}));
    // Escapes still false on non-TTY (fail-closed, no exception).
    try std.testing.expect(!shouldEnterTui(false, false, &.{ "packs", "--json" }));
}

test "shouldEnterTui: false for --json/--robot/--plain/--no-rich argv escapes" {
    const tty = true;
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "packs", "--json" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "--json", "packs" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "packs", "--robot" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "allowlist", "--plain" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "packs", "--no-rich" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{"--no-rich"}));
}

test "shouldEnterTui: false for --format json and --format=json aliases" {
    const tty = true;
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "packs", "--format", "json" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "packs", "--format=json" }));
    try std.testing.expect(!shouldEnterTui(tty, tty, &.{ "--format", "json" }));
}

test "argvDisablesTui: pure escape detection without TTY" {
    try std.testing.expect(!argvDisablesTui(&.{"packs"}));
    try std.testing.expect(!argvDisablesTui(&.{"--format", "human"}));
    try std.testing.expect(argvDisablesTui(&.{"--json"}));
    try std.testing.expect(argvDisablesTui(&.{"--robot"}));
    try std.testing.expect(argvDisablesTui(&.{"--plain"}));
    try std.testing.expect(argvDisablesTui(&.{"--no-rich"}));
    try std.testing.expect(argvDisablesTui(&.{"--format", "json"}));
    try std.testing.expect(argvDisablesTui(&.{"--format=json"}));
    // Trailing --format without value is not a machine escape.
    try std.testing.expect(!argvDisablesTui(&.{"--format"}));
}
