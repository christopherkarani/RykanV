//! Doctor opt-in `--tui` — four panes on the shared browse chassis.
//!
//! # Product (W3 / U06)
//!
//! Default `ryk doctor` stays **linear** (fast glance). `ryk doctor --tui` opens
//! four panes on the shared browse kit:
//!
//! **Summary · Hosts · Capabilities · Next steps**
//!
//! - Summary includes a packs/status one-liner.
//! - Next steps include `ryk packs` and `ryk allowlist`.
//! - Same facts as the linear default (no silent drop of host fail-stance).
//! - Fail-closed on non-TTY / machine escapes: message + linear fallback.
//!
//! # Test floor
//!
//! Pure pane builders + would-enter decision. The raw TTY loop is comptime-gated
//! under `builtin.is_test` (same pattern as packs_tui / allowlist_browse).
const std = @import("std");
const builtin = @import("builtin");
const tui = @import("../tui/mod.zig");
const exit_codes = @import("exit_codes.zig");
const vaxis = @import("vaxis");

// ── Panes ───────────────────────────────────────────────────────────────────

/// Fixed four-pane order on the browse list (not a 5th packs pane).
pub const PaneId = enum {
    summary,
    hosts,
    capabilities,
    next_steps,

    pub fn label(self: PaneId) []const u8 {
        return switch (self) {
            .summary => "Summary",
            .hosts => "Hosts",
            .capabilities => "Capabilities",
            .next_steps => "Next steps",
        };
    }

    pub fn all() [4]PaneId {
        return .{ .summary, .hosts, .capabilities, .next_steps };
    }
};

/// Browse list labels in fixed pane order.
pub fn paneListLabels() [4][]const u8 {
    return .{
        PaneId.summary.label(),
        PaneId.hosts.label(),
        PaneId.capabilities.label(),
        PaneId.next_steps.label(),
    };
}

pub fn paneAt(index: usize) PaneId {
    const panes = PaneId.all();
    if (index >= panes.len) return .summary;
    return panes[index];
}

pub fn footerActions() []const u8 {
    return "↑↓ panes · Enter detail · q quit";
}

pub fn browseTitle() []const u8 {
    return "doctor · deep-dive";
}

// ── Entry gate ──────────────────────────────────────────────────────────────

/// Pure entry decision for doctor **opt-in** TUI.
///
/// Requires explicit `want_tui` (CLI `--tui`). False when machine JSON is set,
/// or when the shared TUI gate fails (non-TTY, `--json`/`--plain`/`--no-rich`/…).
/// Default doctor (no `--tui`) never enters.
pub fn wouldEnterDoctorTui(
    stdin_is_tty: bool,
    stdout_is_tty: bool,
    argv: []const []const u8,
    want_tui: bool,
    machine_json: bool,
) bool {
    if (!want_tui) return false;
    if (machine_json) return false;
    return tui.output_policy.shouldEnterTui(stdin_is_tty, stdout_is_tty, argv);
}

/// Message when `--tui` was requested but the gate refuses (non-TTY / escapes).
/// Caller prints this then falls through to the linear report.
pub const fail_closed_message =
    "ryk doctor: --tui requires an interactive TTY (and no --json/--plain/--no-rich); using linear report.\n";

// ── Fact models (borrowed slices; pure builders) ────────────────────────────

/// Summary pane facts — parity with linear one-line Summary + System health.
pub const SummaryFacts = struct {
    os: []const u8,
    policy_status: []const u8,
    daemon_status: []const u8,
    active: usize,
    limited: usize,
    unavailable: usize,
    /// Packs one-liner for the summary pane (not a 5th pane).
    packs_line: []const u8,
    secret_boundary: []const u8 = "",
};

/// One host row — must surface fail_stance (no silent drop of fail-closed stance).
pub const HostFact = struct {
    host: []const u8,
    wired: []const u8,
    shell_gate: []const u8,
    fail_stance: []const u8,
    smoke_allow: []const u8 = "—",
    smoke_deny: []const u8 = "—",
    fix: []const u8 = "—",
};

/// Capability row — glyph + label + level string (probe display).
pub const CapabilityFact = struct {
    label: []const u8,
    level: []const u8,
    glyph: []const u8 = "·",
};

/// Next-steps priority inputs (mirrors linear writeRecommendations priority).
pub const NextStepFacts = struct {
    daemon_health_compatible: bool,
    daemon_detail: []const u8 = "",
    daemon_binary_untrusted: bool = false,
    daemon_binary_exists: bool = true,
    daemon_binary_executable: bool = true,
    policy_present: bool = true,
    policy_valid: bool = true,
    mcp_manifest_invalid_count: usize = 0,
    redteam_fixtures_present: bool = true,
    hermes_fail_open: bool = false,
    hermes_installed: bool = false,
};

// ── Packs one-liner (summary line; pure) ────────────────────────────────────

/// Format packs status for the Summary pane (no allocation when buf fits).
pub fn formatPacksLine(
    buf: []u8,
    known: bool,
    opt_in_count: usize,
) []const u8 {
    if (!known) {
        // RT-12: packs inventory offline ≠ shell evaluate dead.
        return std.fmt.bufPrint(
            buf,
            "Packs: unknown (inventory offline; shell evaluate is Zig in-process)",
            .{},
        ) catch "Packs: unknown";
    }
    if (opt_in_count == 0) {
        return std.fmt.bufPrint(buf, "Packs: baseline only — `ryk packs` to enable more", .{}) catch "Packs: baseline only";
    }
    return std.fmt.bufPrint(
        buf,
        "Packs: baseline + {d} opt-in enabled — `ryk packs` for browse",
        .{opt_in_count},
    ) catch "Packs: enabled";
}

// ── Pane builders (pure; write into caller buffers) ─────────────────────────

/// Fill Summary detail lines. Returns count written (capped at out.len).
pub fn buildSummaryLines(facts: SummaryFacts, out: [][]u8) usize {
    var n: usize = 0;
    n = appendLine(out, n, "Platform       {s}", .{facts.os});
    n = appendLine(out, n, "Policy         {s}", .{facts.policy_status});
    n = appendLine(out, n, "Daemon         {s}", .{facts.daemon_status});
    n = appendLine(out, n, "Capabilities   {d} active · {d} limited · {d} unavailable", .{
        facts.active,
        facts.limited,
        facts.unavailable,
    });
    if (facts.secret_boundary.len > 0) {
        n = appendLine(out, n, "Secret boundary {s}", .{facts.secret_boundary});
    }
    // Packs one-liner lives in Summary (not a 5th pane).
    n = appendRaw(out, n, facts.packs_line);
    return n;
}

/// Fill Hosts detail lines. Always includes fail_stance per host.
pub fn buildHostsLines(hosts: []const HostFact, out: [][]u8) usize {
    var n: usize = 0;
    if (hosts.len == 0) {
        return appendRaw(out, n, "No host integration rows collected.");
    }
    n = appendRaw(out, n, "HOST  wired  gate  fail-stance  smoke");
    for (hosts) |h| {
        n = appendLine(out, n, "{s}  {s}  {s}  {s}  allow={s} deny={s}", .{
            h.host,
            h.wired,
            h.shell_gate,
            h.fail_stance,
            h.smoke_allow,
            h.smoke_deny,
        });
        if (h.fix.len > 0 and !std.mem.eql(u8, h.fix, "—")) {
            n = appendLine(out, n, "  fix {s}: {s}", .{ h.host, h.fix });
        }
    }
    return n;
}

/// Fill Capabilities detail lines.
pub fn buildCapabilitiesLines(caps: []const CapabilityFact, out: [][]u8) usize {
    var n: usize = 0;
    if (caps.len == 0) {
        return appendRaw(out, n, "No capability probes available.");
    }
    n = appendRaw(out, n, "Doctor = host capability (probe ≠ live session).");
    for (caps) |c| {
        n = appendLine(out, n, "{s}  {s}: {s}", .{ c.glyph, c.label, c.level });
    }
    return n;
}

/// Primary recommendation string (static slices; mirrors linear priority).
pub fn primaryRecommendation(facts: NextStepFacts) []const u8 {
    if (!facts.daemon_health_compatible) {
        if (facts.daemon_binary_untrusted) {
            return "Daemon: remove untrusted ORCA_DAEMON override, then re-run `ryk doctor`.";
        }
        if (facts.daemon_binary_exists and !facts.daemon_binary_executable) {
            return "Daemon: restore companion-service execute permission or reinstall ryk.";
        }
        if (!facts.daemon_binary_exists) {
            return "Daemon: reinstall the complete ryk release, then re-run `ryk doctor`.";
        }
        return "Daemon: reinstall ryk or rebuild with `./scripts/build-all.sh`.";
    }
    if (!facts.policy_present) {
        return "Run `ryk init --preset generic-agent` and review .orca/policy.yaml.";
    }
    if (!facts.policy_valid) {
        return "Fix `.orca/policy.yaml`, then run `ryk policy check .orca/policy.yaml`.";
    }
    if (facts.mcp_manifest_invalid_count > 0) {
        return "Fix invalid MCP manifests with `ryk mcp manifest check <path>`.";
    }
    if (!facts.redteam_fixtures_present) {
        return "Runtime assets missing — export PATH + RYK_RESOURCE_ROOT, then re-run `ryk doctor`.";
    }
    return "Run `ryk run -- <command>` or `ryk redteam --ci` for a local smoke test.";
}

/// Fill Next steps detail lines. Always includes `ryk packs` and `ryk allowlist`.
pub fn buildNextStepsLines(facts: NextStepFacts, out: [][]u8) usize {
    var n: usize = 0;
    n = appendRaw(out, n, "Recommended next step:");
    if (!facts.daemon_health_compatible and facts.daemon_detail.len > 0) {
        n = appendLine(out, n, "  Daemon health issue: {s}", .{facts.daemon_detail});
    }
    n = appendLine(out, n, "  {s}", .{primaryRecommendation(facts)});
    // Teaching links into day-2 verbs (product story D4).
    n = appendRaw(out, n, "Day-2 protection:");
    n = appendRaw(out, n, "  ryk packs       — browse / enable shell packs");
    n = appendRaw(out, n, "  ryk allowlist   — permanent allowlist entries");
    n = appendRaw(out, n, "  ryk doctor --fix — repair policy + day-one host wiring");
    if (facts.hermes_installed and facts.hermes_fail_open) {
        n = appendRaw(out, n, "Hermes: effective fail-open — set ORCA_HERMES_FAIL_OPEN=0 or `ryk run -- hermes`.");
    }
    return n;
}

/// Fill detail lines for the selected pane into pre-sized line buffers.
/// `line_bufs` is a slice of writable buffers; `out_slices` receives written slices.
pub fn fillPaneDetail(
    pane: PaneId,
    summary: SummaryFacts,
    hosts: []const HostFact,
    caps: []const CapabilityFact,
    next: NextStepFacts,
    line_bufs: [][]u8,
    out_slices: [][]const u8,
) usize {
    // Temporary mutable view for builders that write into line_bufs.
    var writable: [64][]u8 = undefined;
    const cap = @min(line_bufs.len, writable.len);
    const capped_out = @min(cap, out_slices.len);
    for (0..capped_out) |i| writable[i] = line_bufs[i];

    const written = switch (pane) {
        .summary => buildSummaryLines(summary, writable[0..capped_out]),
        .hosts => buildHostsLines(hosts, writable[0..capped_out]),
        .capabilities => buildCapabilitiesLines(caps, writable[0..capped_out]),
        .next_steps => buildNextStepsLines(next, writable[0..capped_out]),
    };
    var i: usize = 0;
    while (i < written) : (i += 1) {
        out_slices[i] = writable[i];
    }
    return written;
}

fn appendLine(out: [][]u8, n: usize, comptime fmt: []const u8, args: anytype) usize {
    if (n >= out.len) return n;
    out[n] = std.fmt.bufPrint(out[n], fmt, args) catch {
        // On overflow keep a truncated empty-safe marker.
        if (out[n].len >= 3) {
            @memcpy(out[n][0..3], "...");
            out[n] = out[n][0..3];
        } else {
            out[n] = out[n][0..0];
        }
        return n + 1;
    };
    return n + 1;
}

fn appendRaw(out: [][]u8, n: usize, text: []const u8) usize {
    if (n >= out.len) return n;
    const copy_len = @min(text.len, out[n].len);
    @memcpy(out[n][0..copy_len], text[0..copy_len]);
    out[n] = out[n][0..copy_len];
    return n + 1;
}

// ── Browse session input ────────────────────────────────────────────────────

pub const RunInput = struct {
    summary: SummaryFacts,
    hosts: []const HostFact,
    capabilities: []const CapabilityFact,
    next: NextStepFacts,
};

/// Run doctor four-pane browse. Caller must gate with `wouldEnterDoctorTui`.
/// Restores alt-screen on every exit. Under `builtin.is_test` the TTY loop is
/// skipped (composition proved by pure builders + call-site wiring).
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: anytype,
    input: RunInput,
) !u8 {
    _ = allocator;
    try stdout.writeAll(vaxis.ctlseqs.smcup);
    try stdout.writeAll(vaxis.ctlseqs.hide_cursor);
    var left_alt = false;
    defer {
        if (!left_alt) {
            stdout.writeAll(vaxis.ctlseqs.show_cursor) catch {};
            stdout.writeAll(vaxis.ctlseqs.rmcup) catch {};
        }
    }

    if (comptime builtin.is_test) {
        left_alt = true;
        try stdout.writeAll(vaxis.ctlseqs.show_cursor);
        try stdout.writeAll(vaxis.ctlseqs.rmcup);
        return exit_codes.success;
    }

    const code = try runLoop(io, stdout, input);
    left_alt = true;
    try stdout.writeAll(vaxis.ctlseqs.show_cursor);
    try stdout.writeAll(vaxis.ctlseqs.rmcup);
    return code;
}

fn runLoop(io: std.Io, stdout: anytype, input: RunInput) !u8 {
    var tty_buf: [4096]u8 = undefined;
    var tty = vaxis.tty.Tty.init(io, &tty_buf) catch return exit_codes.success;
    defer tty.deinit();

    const saved = if (comptime builtin.os.tag != .windows)
        std.posix.tcgetattr(tty.fd.handle) catch null
    else
        null;
    defer if (saved) |s| {
        if (comptime builtin.os.tag != .windows) {
            std.posix.tcsetattr(tty.fd.handle, .NOW, s) catch {};
        }
    };
    configureReadTimeout(&tty);

    const list_rows: usize = blk: {
        const ws = tty.getWinsize() catch break :blk 6;
        if (ws.rows > 16) break :blk 6; // four panes + chrome
        break :blk 4;
    };

    var nav: tui.browse.NavState = .{};
    const labels = paneListLabels();
    const item_count: usize = labels.len;

    // Detail line storage (reused each frame).
    var line_storage: [24][160]u8 = undefined;
    var line_bufs: [24][]u8 = undefined;
    for (&line_bufs, 0..) |*b, i| b.* = &line_storage[i];
    var detail_slices: [24][]const u8 = undefined;

    var decoder: Decoder = .{};
    var frame_lines: usize = 0;
    var first_frame = true;

    while (true) {
        nav.selected = tui.browse.clampSelected(nav.selected, item_count);
        nav.list_scroll = tui.browse.scrollToShow(nav.selected, nav.list_scroll, list_rows, item_count);

        const pane = paneAt(nav.selected);
        // Reset writable buffers each frame.
        for (&line_bufs, 0..) |*b, i| b.* = line_storage[i][0..];
        const detail_n = fillPaneDetail(
            pane,
            input.summary,
            input.hosts,
            input.capabilities,
            input.next,
            &line_bufs,
            &detail_slices,
        );

        if (!first_frame and frame_lines > 0) {
            try moveCursorUp(stdout, frame_lines);
            try stdout.writeAll("\x1b[J");
        }
        first_frame = false;

        frame_lines = try tui.browse.renderFrameWithLineEnding(io, stdout, .{
            .title = browseTitle(),
            .items = &labels,
            .selected = nav.selected,
            .list_scroll = nav.list_scroll,
            .list_rows = list_rows,
            .detail_lines = detail_slices[0..detail_n],
            .footer_actions = footerActions(),
            .status_msg = "",
            .filter_query = null,
        }, "\r\n");
        try flush(stdout);

        const key = readKey(&tty, &decoder) catch break;
        const action = tui.browse.keyToAction(key);
        switch (action) {
            .quit => break,
            .up, .down, .top, .bottom => nav.apply(action, item_count, list_rows),
            .enter => {
                // Detail always visible; enter is no-op activate.
            },
            .start_filter => {
                // Doctor panes are fixed; filter not needed — ignore.
            },
            .other => {},
        }
    }
    return exit_codes.success;
}

// ── Minimal TTY helpers (mirrors packs_tui / live_view) ─────────────────────

const Decoder = struct {
    parser: vaxis.Parser = .{},
    carry: [256]u8 = undefined,
    len: usize = 0,

    fn feed(self: *Decoder, bytes: []const u8) !?vaxis.Key {
        if (bytes.len > self.carry.len - self.len) return error.InputTooLong;
        @memcpy(self.carry[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        if (self.len == 1 and self.carry[0] == 0x1b) return null;
        var consumed: usize = 0;
        while (consumed < self.len) {
            const res = try self.parser.parse(self.carry[consumed..self.len], null);
            if (res.n == 0) break;
            consumed += res.n;
            if (res.event) |event| switch (event) {
                .key_press => |key| {
                    std.mem.copyForwards(u8, self.carry[0 .. self.len - consumed], self.carry[consumed..self.len]);
                    self.len -= consumed;
                    return key;
                },
                else => {},
            };
        }
        if (consumed > 0) {
            std.mem.copyForwards(u8, self.carry[0 .. self.len - consumed], self.carry[consumed..self.len]);
            self.len -= consumed;
        }
        if (self.len == 1 and self.carry[0] == 0x1b) {
            self.len = 0;
            return vaxis.Key{ .codepoint = vaxis.Key.escape };
        }
        return null;
    }
};

fn readKey(tty: anytype, decoder: *Decoder) !vaxis.Key {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.posix.read(tty.fd.handle, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return vaxis.Key{ .codepoint = 'q' },
        };
        if (n == 0) {
            if (decoder.len == 1 and decoder.carry[0] == 0x1b) {
                decoder.len = 0;
                return vaxis.Key{ .codepoint = vaxis.Key.escape };
            }
            continue;
        }
        if (try decoder.feed(buf[0..n])) |key| return key;
    }
}

fn configureReadTimeout(tty: anytype) void {
    if (comptime builtin.os.tag == .windows) return;
    var attrs = std.posix.tcgetattr(tty.fd.handle) catch return;
    attrs.lflag.ICANON = false;
    attrs.lflag.ECHO = false;
    attrs.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    attrs.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    std.posix.tcsetattr(tty.fd.handle, .NOW, attrs) catch {};
}

fn moveCursorUp(stdout: anytype, lines: usize) !void {
    if (lines == 0) return;
    var buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[{d}A", .{lines});
    try stdout.writeAll(seq);
}

fn flush(stdout: anytype) !void {
    if (@hasDecl(@TypeOf(stdout.*), "flush")) {
        try stdout.flush();
    }
}

// ── Pure unit tests ─────────────────────────────────────────────────────────

test "doctor tui: wouldEnterDoctorTui requires --tui and TTY pair" {
    const bare = [_][]const u8{};
    // Default linear: no --tui → never enter.
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &bare, false, false));
    // Opt-in on TTY pair.
    try std.testing.expect(wouldEnterDoctorTui(true, true, &.{"--tui"}, true, false));
    // Non-TTY fail-closed.
    try std.testing.expect(!wouldEnterDoctorTui(false, true, &.{"--tui"}, true, false));
    try std.testing.expect(!wouldEnterDoctorTui(true, false, &.{"--tui"}, true, false));
    // Machine json frozen.
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &.{ "--tui", "--json" }, true, true));
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &.{"--tui"}, true, true));
    // Argv escapes.
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &.{ "--tui", "--plain" }, true, false));
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &.{ "--tui", "--no-rich" }, true, false));
    try std.testing.expect(!wouldEnterDoctorTui(true, true, &.{ "--tui", "--robot" }, true, false));
}

test "doctor tui: four pane labels in product order" {
    const labels = paneListLabels();
    try std.testing.expectEqual(@as(usize, 4), labels.len);
    try std.testing.expectEqualStrings("Summary", labels[0]);
    try std.testing.expectEqualStrings("Hosts", labels[1]);
    try std.testing.expectEqualStrings("Capabilities", labels[2]);
    try std.testing.expectEqualStrings("Next steps", labels[3]);
    try std.testing.expectEqual(PaneId.summary, paneAt(0));
    try std.testing.expectEqual(PaneId.next_steps, paneAt(3));
}

test "doctor tui: summary pane includes packs one-liner" {
    var packs_buf: [128]u8 = undefined;
    var packs_unknown_buf: [128]u8 = undefined;
    var packs_opt_buf: [128]u8 = undefined;
    const packs = formatPacksLine(&packs_buf, true, 0);
    try std.testing.expect(std.mem.indexOf(u8, packs, "baseline only") != null);
    try std.testing.expect(std.mem.indexOf(u8, packs, "ryk packs") != null);

    const packs_unknown = formatPacksLine(&packs_unknown_buf, false, 0);
    try std.testing.expect(std.mem.indexOf(u8, packs_unknown, "unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, packs_unknown, "shell evaluate is Zig in-process") != null);

    const packs_opt = formatPacksLine(&packs_opt_buf, true, 3);
    try std.testing.expect(std.mem.indexOf(u8, packs_opt, "3 opt-in") != null);

    var storage: [8][160]u8 = undefined;
    var lines: [8][]u8 = undefined;
    for (&lines, 0..) |*l, i| l.* = &storage[i];
    const n = buildSummaryLines(.{
        .os = "macos",
        .policy_status = "policy valid",
        .daemon_status = "daemon compatible",
        .active = 5,
        .limited = 2,
        .unavailable = 1,
        .packs_line = packs,
        .secret_boundary = "unavailable (empty-backpack requires live OS attach)",
    }, &lines);
    try std.testing.expect(n >= 5);
    var joined: [2048]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&joined);
    for (lines[0..n]) |line| {
        try jw.writeAll(line);
        try jw.writeAll("\n");
    }
    const text = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "macos") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "policy valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "daemon compatible") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Packs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "baseline only") != null);
}

test "doctor tui: hosts pane surfaces fail-stance (no silent drop)" {
    const hosts = [_]HostFact{
        .{
            .host = "codex",
            .wired = "yes",
            .shell_gate = "PreToolUse",
            .fail_stance = "fail-closed shell",
            .smoke_allow = "pass",
            .smoke_deny = "pass",
        },
        .{
            .host = "opencode",
            .wired = "no",
            .shell_gate = "tool.execute.before",
            .fail_stance = "unwired (no fail-closed shell)",
            .fix = "ryk doctor --fix",
        },
        .{
            .host = "hermes",
            .wired = "yes",
            .shell_gate = "pre_tool_call",
            .fail_stance = "fail-open (default)",
            .fix = "ORCA_HERMES_FAIL_OPEN=0",
        },
    };
    var storage: [16][160]u8 = undefined;
    var lines: [16][]u8 = undefined;
    for (&lines, 0..) |*l, i| l.* = &storage[i];
    const n = buildHostsLines(&hosts, &lines);
    try std.testing.expect(n >= 4);
    var joined: [4096]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&joined);
    for (lines[0..n]) |line| {
        try jw.writeAll(line);
        try jw.writeAll("\n");
    }
    const text = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "fail-closed shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unwired (no fail-closed shell)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fail-open (default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fix opencode:") != null);
}

test "doctor tui: capabilities pane lists probe levels" {
    const caps = [_]CapabilityFact{
        .{ .label = "process supervision", .level = "active", .glyph = "✓" },
        .{ .label = "strong sandbox", .level = "unavailable", .glyph = "✗" },
    };
    var storage: [8][160]u8 = undefined;
    var lines: [8][]u8 = undefined;
    for (&lines, 0..) |*l, i| l.* = &storage[i];
    const n = buildCapabilitiesLines(&caps, &lines);
    try std.testing.expect(n >= 3);
    var joined: [1024]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&joined);
    for (lines[0..n]) |line| {
        try jw.writeAll(line);
        try jw.writeAll("\n");
    }
    const text = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "process supervision") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "strong sandbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "probe") != null);
}

test "doctor tui: next steps include ryk packs and ryk allowlist" {
    var storage: [12][160]u8 = undefined;
    var lines: [12][]u8 = undefined;
    for (&lines, 0..) |*l, i| l.* = &storage[i];
    const n = buildNextStepsLines(.{
        .daemon_health_compatible = true,
        .policy_present = true,
        .policy_valid = true,
        .redteam_fixtures_present = true,
    }, &lines);
    try std.testing.expect(n >= 4);
    var joined: [2048]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&joined);
    for (lines[0..n]) |line| {
        try jw.writeAll(line);
        try jw.writeAll("\n");
    }
    const text = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "ryk packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ryk allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Recommended next step") != null);
}

test "doctor tui: next steps prioritize daemon remediation" {
    var storage: [12][160]u8 = undefined;
    var lines: [12][]u8 = undefined;
    for (&lines, 0..) |*l, i| l.* = &storage[i];
    const n = buildNextStepsLines(.{
        .daemon_health_compatible = false,
        .daemon_detail = "no running daemon answered on the expected socket.",
        .daemon_binary_exists = false,
        .policy_present = false,
    }, &lines);
    var joined: [2048]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&joined);
    for (lines[0..n]) |line| {
        try jw.writeAll(line);
        try jw.writeAll("\n");
    }
    const text = jw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "no running daemon answered") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "reinstall") != null);
    // Still teach packs/allowlist even when daemon is the priority fix.
    try std.testing.expect(std.mem.indexOf(u8, text, "ryk packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ryk allowlist") != null);
}

test "doctor tui: fillPaneDetail dispatches four panes" {
    var storage: [16][160]u8 = undefined;
    var line_bufs: [16][]u8 = undefined;
    for (&line_bufs, 0..) |*b, i| b.* = &storage[i];
    var out: [16][]const u8 = undefined;

    const summary: SummaryFacts = .{
        .os = "linux",
        .policy_status = "policy valid",
        .daemon_status = "daemon compatible",
        .active = 1,
        .limited = 0,
        .unavailable = 0,
        .packs_line = "Packs: baseline only — `ryk packs` to enable more",
    };
    const hosts = [_]HostFact{.{
        .host = "claude",
        .wired = "yes",
        .shell_gate = "PreToolUse",
        .fail_stance = "fail-closed shell",
    }};
    const caps = [_]CapabilityFact{.{ .label = "env filtering", .level = "active", .glyph = "✓" }};
    const next: NextStepFacts = .{ .daemon_health_compatible = true };

    const n_sum = fillPaneDetail(.summary, summary, &hosts, &caps, next, &line_bufs, &out);
    try std.testing.expect(n_sum > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "linux") != null or std.mem.indexOf(u8, out[0], "Platform") != null);

    // Reset buffers for next pane.
    for (&line_bufs, 0..) |*b, i| b.* = storage[i][0..];
    const n_host = fillPaneDetail(.hosts, summary, &hosts, &caps, next, &line_bufs, &out);
    try std.testing.expect(n_host > 0);
    var found_stance = false;
    for (out[0..n_host]) |line| {
        if (std.mem.indexOf(u8, line, "fail-closed shell") != null) found_stance = true;
    }
    try std.testing.expect(found_stance);

    for (&line_bufs, 0..) |*b, i| b.* = storage[i][0..];
    const n_next = fillPaneDetail(.next_steps, summary, &hosts, &caps, next, &line_bufs, &out);
    var found_packs = false;
    var found_allow = false;
    for (out[0..n_next]) |line| {
        if (std.mem.indexOf(u8, line, "ryk packs") != null) found_packs = true;
        if (std.mem.indexOf(u8, line, "ryk allowlist") != null) found_allow = true;
    }
    try std.testing.expect(found_packs);
    try std.testing.expect(found_allow);
}

test "doctor tui: renderFrame via kit shows four panes (no alt-screen)" {
    var out_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    const items = paneListLabels();
    const detail = [_][]const u8{
        "Platform       macos",
        "Packs: baseline only — `ryk packs` to enable more",
    };
    const n = try tui.browse.renderFrame(std.testing.io, &w, .{
        .title = browseTitle(),
        .items = &items,
        .selected = 0,
        .list_rows = 6,
        .detail_lines = &detail,
        .footer_actions = footerActions(),
        .status_msg = "",
    });
    try std.testing.expect(n > 0);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hosts") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Next steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Packs:") != null);
    // Pure frame never enters alt-screen.
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.smcup) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.rmcup) == null);
}
