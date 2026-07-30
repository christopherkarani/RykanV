//! Alt-screen session-forensics viewer for `ryk scan` (libvaxis + theme).
//!
//! Pure `renderFrame` is unit-tested. The raw TTY loop mirrors `tui/live_view.zig`
//! and is comptime-gated out of test builds (stubbed libvaxis Tty).
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const risk = @import("risk.zig");
const present = @import("present.zig");
const theme = @import("../tui/theme.zig");
const vaxis = @import("vaxis");

pub const KeyAction = enum { quit, up, down, top, bottom, other };

/// Pure frame renderer: scorecard-first risk snapshot + selectable findings list
/// + detail pane for the selected finding. Emits content + theme colour only
/// (no alt-screen / cursor controls — those live in `run`).
///
/// Returns lines written so the live loop can re-home the cursor.
pub fn renderFrame(
    io: std.Io,
    stdout: anytype,
    result: *const types.ScanResult,
    selected: usize,
    list_scroll: usize,
    list_rows: usize,
    line_ending: []const u8,
) !usize {
    var written: usize = 0;
    const sc = result.scorecard;
    const level = risk.riskLevel(sc);
    var win_buf: [32]u8 = undefined;
    const window = risk.windowLabel(sc, &win_buf);

    // ── Header ──────────────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .brand, "🛡  ryk");
    try stdout.writeAll(" · ");
    try theme.paintBold(io, stdout, .text_bright, "session scan");
    try stdout.writeAll(line_ending);
    written += 1;

    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "Past agent sessions · known paths only · offline");
    try stdout.writeAll(line_ending);
    written += 1;

    try writeRule(io, stdout, line_ending);
    written += 1;

    // ── Risk snapshot ───────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, riskToken(level), level.headline());
    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "·");
    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, window);
    try stdout.writeAll(line_ending);
    written += 1;

    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .text, level.blurb());
    try stdout.writeAll(line_ending);
    written += 1;

    // Counts row
    try stdout.writeAll("  ");
    try writeCount(io, stdout, "sessions", sc.sessions_scanned, .info);
    try stdout.writeAll("  ");
    try writeCount(io, stdout, "danger", sc.danger_count, if (sc.danger_count > 0) .danger else .muted);
    try stdout.writeAll("  ");
    try writeCount(io, stdout, "secret access", sc.secret_access_count, if (sc.secret_access_count > 0) .warn else .muted);
    try stdout.writeAll("  ");
    try writeCount(io, stdout, "secret material", sc.secret_material_count, if (sc.secret_material_count > 0) .warn else .muted);
    try stdout.writeAll(line_ending);
    written += 1;

    // Host chips
    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "hosts");
    try stdout.writeAll("  ");
    for (sc.hosts, 0..) |h, i| {
        if (i > 0) try stdout.writeAll("  ");
        try theme.paint(io, stdout, hostToken(h.status), h.host.toString());
        try stdout.writeAll(":");
        try theme.paint(io, stdout, hostToken(h.status), risk.hostStatusGlyph(h.status));
        if (h.sessions_seen > 0) {
            var nbuf: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "({d})", .{h.sessions_seen}) catch "";
            try theme.paint(io, stdout, .muted, ns);
        }
    }
    try stdout.writeAll(line_ending);
    written += 1;

    try writeRule(io, stdout, line_ending);
    written += 1;

    // ── Empty / guided ──────────────────────────────────────────────────────
    if (result.total_findings == 0) {
        written += try renderEmptyGuidance(io, stdout, result, level, line_ending);
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "q quit");
        try stdout.writeAll(line_ending);
        written += 1;
        return written;
    }

    // ── Findings list ───────────────────────────────────────────────────────
    const total_shown = result.findings.len;
    const sel = if (total_shown == 0) 0 else @min(selected, total_shown - 1);
    const cap = if (list_rows == 0) total_shown else list_rows;
    const max_start: usize = if (total_shown > cap) total_shown - cap else 0;
    var start = @min(list_scroll, max_start);
    // Keep selection visible.
    if (sel < start) start = sel;
    if (cap > 0 and sel >= start + cap) start = sel + 1 - cap;
    const end = @min(start + cap, total_shown);

    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .text_bright, "Findings");
    try stdout.writeAll("  ");
    var range_buf: [64]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "{d}-{d} of {d} shown · {d} total", .{
        if (total_shown == 0) 0 else start + 1,
        end,
        total_shown,
        result.total_findings,
    }) catch "findings";
    try theme.paint(io, stdout, .muted, range);
    if (result.total_findings > total_shown) {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "(use --all for full list)");
    }
    try stdout.writeAll(line_ending);
    written += 1;

    if (start > 0) {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "… earlier findings above");
        try stdout.writeAll(line_ending);
        written += 1;
    }

    var i = start;
    while (i < end) : (i += 1) {
        const f = result.findings[i];
        const is_sel = i == sel;
        try stdout.writeAll(if (is_sel) " ›" else "  ");
        try stdout.writeAll(" ");
        const sev_tok = severityToken(f.severity);
        if (is_sel) {
            try theme.paintBold(io, stdout, sev_tok, risk.severityShort(f.severity));
        } else {
            try theme.paint(io, stdout, sev_tok, risk.severityShort(f.severity));
        }
        try stdout.writeAll(" ");
        try theme.paint(io, stdout, if (is_sel) .text_bright else .muted, present.kindHuman(f.kind));
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .info, f.host.toString());
        try stdout.writeAll("  ");
        var title_buf: [96]u8 = undefined;
        const list_title = present.listTitle(f, &title_buf);
        try writeTrunc(stdout, list_title, 40);
        try stdout.writeAll(line_ending);
        written += 1;
    }

    if (end < total_shown) {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "… more below");
        try stdout.writeAll(line_ending);
        written += 1;
    }

    try writeRule(io, stdout, line_ending);
    written += 1;

    // ── Detail pane (new-user oriented) ─────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .text_bright, "Detail");
    try stdout.writeAll(line_ending);
    written += 1;

    if (total_shown > 0) {
        const f = result.findings[sel];
        var sentence_buf: [200]u8 = undefined;
        var why_buf: [160]u8 = undefined;
        var next_buf: [120]u8 = undefined;
        var title_buf: [96]u8 = undefined;

        // Plain sentence first.
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .text, present.plainSentence(f, &sentence_buf));
        try stdout.writeAll(line_ending);
        written += 1;

        // Severity words + host + type chip.
        try stdout.writeAll("  ");
        try theme.paintBold(io, stdout, severityToken(f.severity), present.severityWords(f.severity));
        try stdout.writeAll("  ·  ");
        try theme.paint(io, stdout, .info, f.host.toString());
        try stdout.writeAll("  ·  ");
        try theme.paint(io, stdout, .muted, present.kindHuman(f.kind));
        if (f.occurrence_count > 1) {
            var cnt_buf: [24]u8 = undefined;
            const cnt = std.fmt.bufPrint(&cnt_buf, "  ·  seen ×{d}", .{f.occurrence_count}) catch "";
            try theme.paint(io, stdout, .muted, cnt);
        }
        try stdout.writeAll(line_ending);
        written += 1;

        // Action.
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .warn, "Do");
        try stdout.writeAll("  ");
        try writeTrunc(stdout, present.actionLine(f), 72);
        try stdout.writeAll(line_ending);
        written += 1;

        // Why.
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "Why");
        try stdout.writeAll(" ");
        try writeTrunc(stdout, present.whyFired(f, &why_buf), 70);
        try stdout.writeAll(line_ending);
        written += 1;

        // Type + fingerprint (no nested REDACTED "what").
        if (f.secret_label) |label| {
            try stdout.writeAll("  ");
            try theme.paint(io, stdout, .muted, "Type");
            try stdout.writeAll(" ");
            try theme.paint(io, stdout, .warn, present.humanSecretLabel(label));
            if (f.secret_fingerprint) |fp| {
                try stdout.writeAll("  ");
                try theme.paint(io, stdout, .muted, "id");
                try stdout.writeAll(" ");
                try theme.paint(io, stdout, .muted, fp);
            }
            try stdout.writeAll(line_ending);
            written += 1;
        } else if (f.kind == .danger or f.kind == .secret_access) {
            try stdout.writeAll("  ");
            try theme.paint(io, stdout, .muted, "Cmd");
            try stdout.writeAll("  ");
            try writeTrunc(stdout, present.cleanHiddenDisplay(f.detail), 70);
            try stdout.writeAll(line_ending);
            written += 1;
        }

        // Session short id + path secondary.
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "Session");
        try stdout.writeAll(" ");
        try writeTrunc(stdout, present.shortId(f.session_id), 28);
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, present.listTitle(f, &title_buf));
        try stdout.writeAll(line_ending);
        written += 1;

        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "File");
        try stdout.writeAll("    ");
        try writeTrunc(stdout, f.evidence_ref, 62);
        try stdout.writeAll(line_ending);
        written += 1;

        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .info, present.hostNextStep(f.host, f.session_id, &next_buf));
        try stdout.writeAll(line_ending);
        written += 1;
    }

    // Footer
    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "↑↓/jk move · g/G top/end · q quit");
    try stdout.writeAll(line_ending);
    written += 1;

    return written;
}

fn renderEmptyGuidance(
    io: std.Io,
    stdout: anytype,
    result: *const types.ScanResult,
    level: risk.RiskLevel,
    line_ending: []const u8,
) !usize {
    var written: usize = 0;
    const kind: theme.Token = switch (level) {
        .clear => .success,
        .no_data => .info,
        else => .warn,
    };
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, kind, if (level == .clear) "✓  No risky findings in this window" else "ℹ  No findings to list");
    try stdout.writeAll(line_ending);
    written += 1;

    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "What we checked:");
    try stdout.writeAll(line_ending);
    written += 1;

    for (result.scorecard.hosts) |h| {
        try stdout.writeAll("    ");
        try theme.paint(io, stdout, hostToken(h.status), h.host.toString());
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, risk.hostStatusGlyph(h.status));
        if (h.note.len > 0) {
            try stdout.writeAll("  ");
            try writeTrunc(stdout, h.note, 56);
        }
        try stdout.writeAll(line_ending);
        written += 1;
    }

    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, "Next:");
    try stdout.writeAll(" use an agent (Claude/Codex/Grok/…) then re-run ");
    try theme.paint(io, stdout, .brand, "ryk scan");
    try stdout.writeAll(". Existing ryk users: ");
    try theme.paint(io, stdout, .info, "ryk replay");
    try stdout.writeAll(line_ending);
    written += 1;

    // Soft-skip callout for OpenCode when present-but-unsupported.
    for (result.scorecard.hosts) |h| {
        if (h.host == .opencode and h.status == .unsupported) {
            try stdout.writeAll("  ");
            try theme.paint(io, stdout, .warn, "Note:");
            try stdout.writeAll(" OpenCode SQLite store is soft-skipped in v1 (not parsed yet).");
            try stdout.writeAll(line_ending);
            written += 1;
            break;
        }
    }
    return written;
}

fn writeCount(io: std.Io, stdout: anytype, label: []const u8, n: usize, tok: theme.Token) !void {
    var buf: [24]u8 = undefined;
    const ns = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
    try theme.paintBold(io, stdout, tok, ns);
    try stdout.writeAll(" ");
    try theme.paint(io, stdout, .muted, label);
}

fn writeRule(io: std.Io, stdout: anytype, line_ending: []const u8) !void {
    try stdout.writeAll("  ");
    const a = theme.active(io, stdout);
    const ch: []const u8 = if (a.supportsUnicode()) "─" else "-";
    var i: usize = 0;
    while (i < 62) : (i += 1) try stdout.writeAll(ch);
    try stdout.writeAll(line_ending);
}

fn writeTrunc(stdout: anytype, s: []const u8, max_cols: usize) !void {
    // Single-line sanitize + hard cap on byte length for layout (display width approx).
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len and col < max_cols) {
        const c = s[i];
        if (c == '\n' or c == '\r' or c == '\t') {
            try stdout.writeAll(" ");
            col += 1;
            i += 1;
            continue;
        }
        if (c < 0x20) {
            i += 1;
            continue;
        }
        // Emit one UTF-8 codepoint if possible.
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        if (col + 1 > max_cols) break;
        try stdout.writeAll(s[i .. i + len]);
        col += 1;
        i += len;
    }
    if (i < s.len) try stdout.writeAll("…");
}

fn riskToken(level: risk.RiskLevel) theme.Token {
    return switch (level) {
        .dangerous => .danger,
        .secrets_accessed, .secrets_seen => .warn,
        .clear => .success,
        .no_data => .info,
    };
}

fn severityToken(sev: types.Severity) theme.Token {
    return switch (sev) {
        .critical, .high => .danger,
        .medium => .warn,
        .low => .muted,
    };
}

fn hostToken(status: types.HostStatus) theme.Token {
    return switch (status) {
        .ok => .success,
        .empty => .muted,
        .not_found => .muted,
        .unreadable => .danger,
        .unsupported => .warn,
    };
}

/// Enter alt-screen, browse findings with list+detail, leave cleanly on every path.
/// Real-TTY only; callers must reject non-TTY / --json / --plain first.
///
/// Returns `error.TtyUnavailable` **before** entering the alt-screen when the
/// controlling TTY cannot be opened — callers should fall back to linear human
/// output so findings are never silently dropped.
pub fn run(io: std.Io, stdout: anytype, result: *const types.ScanResult) !void {
    if (comptime builtin.is_test) return;

    var tty_buf: [4096]u8 = undefined;
    var tty = vaxis.tty.Tty.init(io, &tty_buf) catch return error.TtyUnavailable;
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

    // Enter alt-screen only after TTY is ready so init failure never blank-screens.
    try stdout.writeAll(vaxis.ctlseqs.smcup);
    try stdout.writeAll(vaxis.ctlseqs.hide_cursor);
    // Always restore on every exit path (including write errors during loop).
    defer {
        stdout.writeAll(vaxis.ctlseqs.show_cursor) catch {};
        stdout.writeAll(vaxis.ctlseqs.rmcup) catch {};
    }

    var selected: usize = 0;
    var list_scroll: usize = 0;

    // Reserve rows: header(~8) + list + detail(~7) + footer. List gets remainder.
    const list_rows: usize = blk: {
        const ws = tty.getWinsize() catch break :blk 8;
        if (ws.rows < 16) break :blk 4;
        // ~10 chrome lines for scorecard/header/detail/footer.
        const avail = ws.rows -| 16;
        break :blk if (avail < 4) 4 else @min(avail, 12);
    };

    var decoder: Decoder = .{};
    var frame_lines: usize = 0;
    var first_frame = true;
    while (true) {
        if (!first_frame and frame_lines > 0) {
            try moveCursorUp(stdout, frame_lines);
            try stdout.writeAll("\x1b[J");
        }
        first_frame = false;
        // Keep scroll so selection is visible.
        if (result.findings.len > 0) {
            if (selected < list_scroll) list_scroll = selected;
            if (selected >= list_scroll + list_rows) list_scroll = selected + 1 - list_rows;
        }
        frame_lines = try renderFrame(io, stdout, result, selected, list_scroll, list_rows, "\r\n");
        try flush(stdout);

        // Hard read failures: leave the viewer (primary-screen summary remains).
        const action = readKey(&tty, &decoder) catch break;
        switch (action) {
            .quit => break,
            .up => if (selected > 0) {
                selected -= 1;
            },
            .down => if (result.findings.len > 0 and selected + 1 < result.findings.len) {
                selected += 1;
            },
            .top => selected = 0,
            .bottom => if (result.findings.len > 0) {
                selected = result.findings.len - 1;
            },
            .other => {},
        }
    }
}

const Decoder = struct {
    parser: vaxis.Parser = .{},
    carry: [256]u8 = undefined,
    len: usize = 0,

    fn feed(self: *Decoder, bytes: []const u8) !?KeyAction {
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
                    const action = keyToAction(key);
                    std.mem.copyForwards(u8, self.carry[0 .. self.len - consumed], self.carry[consumed..self.len]);
                    self.len -= consumed;
                    return action;
                },
                else => {},
            };
        }
        if (consumed > 0) {
            std.mem.copyForwards(u8, self.carry[0 .. self.len - consumed], self.carry[consumed..self.len]);
            self.len -= consumed;
        }
        return null;
    }

    fn interByteTimeout(self: *Decoder) ?KeyAction {
        if (self.len == 1 and self.carry[0] == 0x1b) {
            self.len = 0;
            return .quit;
        }
        return null;
    }
};

fn keyToAction(key: vaxis.Key) KeyAction {
    if (key.matches(vaxis.Key.escape, .{})) return .quit;
    if (key.matches('q', .{})) return .quit;
    if (key.matches(vaxis.Key.up, .{})) return .up;
    if (key.matches(vaxis.Key.down, .{})) return .down;
    if (key.matches('k', .{})) return .up;
    if (key.matches('j', .{})) return .down;
    if (key.matches('g', .{})) return .top;
    if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) return .bottom;
    return .other;
}

fn readKey(tty: *vaxis.tty.Tty, decoder: *Decoder) !KeyAction {
    if (comptime builtin.os.tag == .windows) {
        while (true) switch (try tty.nextEvent(&decoder.parser, null)) {
            .key_press => |key| return keyToAction(key),
            else => {},
        };
    }
    configureReadTimeout(tty);
    var buf: [256]u8 = undefined;
    while (true) {
        // Same as prompt.zig: libvaxis `Tty.read` turns VMIN=0/VTIME idle into
        // error.EndOfStream, which would immediately quit the viewer (blank
        // flash → restore). Read the fd directly so timeout is n==0.
        const n = std.posix.read(tty.fd.handle, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n == 0) {
            if (decoder.interByteTimeout()) |action| return action;
            continue;
        }
        if (try decoder.feed(buf[0..n])) |action| return action;
    }
}

fn configureReadTimeout(tty: anytype) void {
    if (comptime builtin.os.tag == .windows) return;
    if (builtin.is_test) return;
    var raw = std.posix.tcgetattr(tty.fd.handle) catch return;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    std.posix.tcsetattr(tty.fd.handle, .NOW, raw) catch {};
}

fn moveCursorUp(stdout: anytype, n: usize) !void {
    if (n == 0) return;
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\r\x1b[{d}A\r", .{n}) catch return;
    try stdout.writeAll(seq);
}

fn flush(writer: anytype) !void {
    const Writer = @TypeOf(writer);
    switch (@typeInfo(Writer)) {
        .pointer => |pointer| if (@hasDecl(pointer.child, "flush")) try writer.flush(),
        else => if (@hasDecl(Writer, "flush")) try writer.flush(),
    }
}

// ── Tests (pure frame; no raw TTY) ──────────────────────────────────────────

fn testResult(findings: []types.Finding, sessions: usize, danger: usize, material: usize) types.ScanResult {
    var sc: types.Scorecard = .{
        .window_days = 30,
        .all_time = false,
        .sessions_scanned = sessions,
        .danger_count = danger,
        .secret_material_count = material,
    };
    sc.setHost(.claude, .ok, 1, "Claude Code project transcripts (*.jsonl)");
    sc.setHost(.codex, .empty, 0, "Codex rollout JSONL under date partitions");
    sc.setHost(.pi, .not_found, 0, "Pi agent session.jsonl trees");
    sc.setHost(.opencode, .unsupported, 0, "OpenCode SQLite soft-skipped");
    sc.setHost(.grok, .ok, 2, "Grok Build session chat_history.jsonl");
    sc.setHost(.ryk, .empty, 0, "ryk sessions");
    return .{
        .scorecard = sc,
        .findings = findings,
        .total_findings = findings.len,
        .shown_cap = 20,
        .allocator = std.testing.allocator,
    };
}

test "scan tui frame: risk headline and counts for danger" {
    theme.resetCache();
    var findings = try std.testing.allocator.alloc(types.Finding, 1);
    defer {
        for (findings) |*f| f.deinit(std.testing.allocator);
        std.testing.allocator.free(findings);
    }
    findings[0] = .{
        .kind = .danger,
        .severity = .critical,
        .host = .grok,
        .session_id = try std.testing.allocator.dupe(u8, "sess-1"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/s.jsonl"),
        .timestamp_secs = 1,
        .title = try std.testing.allocator.dupe(u8, "Dangerous command (critical)"),
        .detail = try std.testing.allocator.dupe(u8, "rm -rf /tmp/demo"),
        .evidence_ref = try std.testing.allocator.dupe(u8, "/tmp/s.jsonl"),
    };
    const result = testResult(findings, 3, 1, 0);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const n = try renderFrame(std.testing.io, &w, &result, 0, 0, 6, "\n");
    const out = w.buffered();
    try std.testing.expect(n > 8);
    try std.testing.expect(std.mem.indexOf(u8, out, "🛡  ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "session scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Attention needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "danger") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "CRIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rm -rf /tmp/demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "q quit") != null);
    // No alt-screen controls in pure frame.
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.smcup) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\x1b') == null);
}

test "scan tui frame: guided empty state for no_data" {
    theme.resetCache();
    const result = testResult(&.{}, 0, 0, 0);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, &result, 0, 0, 6, "\n");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Nothing to scan yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "What we checked") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Next:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OpenCode") != null);
}

test "scan tui frame: clear empty with sessions" {
    theme.resetCache();
    var sc_result = testResult(&.{}, 5, 0, 0);
    sc_result.scorecard.sessions_scanned = 5;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, &sc_result, 0, 0, 6, "\n");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Looking good") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "No risky findings") != null);
}

test "scan tui frame: redacted secret never shows raw token" {
    theme.resetCache();
    var findings = try std.testing.allocator.alloc(types.Finding, 1);
    defer {
        for (findings) |*f| f.deinit(std.testing.allocator);
        std.testing.allocator.free(findings);
    }
    findings[0] = .{
        .kind = .secret_material,
        .severity = .high,
        .host = .codex,
        .session_id = try std.testing.allocator.dupe(u8, "rollout-1"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/c.jsonl"),
        .timestamp_secs = 1,
        .title = try std.testing.allocator.dupe(u8, "Secret material in session"),
        .detail = try std.testing.allocator.dupe(u8, "[REDACTED:secret:github_token]"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:github_token"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, "abcd1234"),
        .evidence_ref = try std.testing.allocator.dupe(u8, "/tmp/c.jsonl"),
    };
    const result = testResult(findings, 2, 0, 1);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, &result, 0, 0, 6, "\n");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Secrets appeared") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "GitHub token") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Value hidden") != null or std.mem.indexOf(u8, out, "hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Worth reviewing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Do") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[REDACTED:secret:[REDACTED]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") == null);
}

test "scan tui frame: selection marker and multi-finding" {
    theme.resetCache();
    var findings = try std.testing.allocator.alloc(types.Finding, 3);
    defer {
        for (findings) |*f| f.deinit(std.testing.allocator);
        std.testing.allocator.free(findings);
    }
    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        const title = try std.fmt.allocPrint(std.testing.allocator, "Finding {d}", .{idx});
        findings[idx] = .{
            .kind = .danger,
            .severity = .medium,
            .host = .claude,
            .session_id = try std.testing.allocator.dupe(u8, "s"),
            .path = try std.testing.allocator.dupe(u8, "/p"),
            .timestamp_secs = 1,
            .title = title,
            .detail = try std.testing.allocator.dupe(u8, "cmd"),
            .evidence_ref = try std.testing.allocator.dupe(u8, "/p"),
        };
    }
    const result = testResult(findings, 3, 3, 0);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, &result, 1, 0, 6, "\n");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Finding 1") != null);
}
