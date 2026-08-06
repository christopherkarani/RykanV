//! Shared browse kit (list + detail + action footer + optional filter).
//!
//! # Browse contract
//!
//! Reusable chassis for packs / allowlist / doctor TUIs. Navigation matches the
//! `ryk scan` session viewer so muscle memory transfers.
//!
//! ## Keys (scan-compatible navigation)
//!
//! | Key        | Action                                      |
//! |------------|---------------------------------------------|
//! | ↑↓ / j k   | Move selection                              |
//! | g / G      | Top / bottom                                |
//! | Enter      | Detail / activate selected row              |
//! | q / Esc    | Quit                                        |
//! | /          | Start search/filter mode                    |
//! | Domain     | Footer-defined (enable/disable/remove/…)    |
//! | c / o      | Reserved for scan (copy/reveal); map to     |
//! |            | `other` here — never silently steal         |
//!
//! ## TTY-only
//!
//! Callers must gate with `shouldEnterTui` (or equivalent): non-TTY, `--json` /
//! `--robot`, `--plain`, and `--no-rich` never enter the alt-screen. This module
//! provides pure frame + key mapping only; it does not open a TTY loop.
//!
//! ## Footer
//!
//! Every frame shows an action footer: shared nav hints plus caller-supplied
//! domain actions (`footer_actions`). Optional `status_msg` toasts appear to the
//! left of the key hints.
//!
//! ## Restore on quit
//!
//! Esc/q → quit is a pure `KeyAction`; **alt-screen enter/leave and terminal
//! restore are the caller's responsibility** (same pattern as `live_view.run`
//! / `scan/tui_view.run`). Pure `renderFrame` never emits smcup/rmcup/cursor
//! controls.
const std = @import("std");
const theme = @import("theme.zig");
const terminal_text = @import("terminal_text.zig");
const vaxis = @import("vaxis");

/// Keys the browse kit reacts to (scan-compatible nav + enter + filter).
/// Domain keys (e/d/r/…) remain `.other` for the host command to interpret.
pub const KeyAction = enum {
    quit,
    up,
    down,
    top,
    bottom,
    enter,
    start_filter,
    other,
};

/// Map a libvaxis `Key` to a browse `KeyAction`.
///
/// Scan-compatible: ↑↓/jk, g/G, q/Esc. Plus Enter (activate) and `/` (filter).
/// `c` and `o` intentionally return `.other` so packs/allowlist/doctor never
/// steal scan's copy-path / reveal semantics.
pub fn keyToAction(key: vaxis.Key) KeyAction {
    if (key.matches(vaxis.Key.escape, .{})) return .quit;
    if (key.matches('q', .{})) return .quit;
    if (key.matches(vaxis.Key.up, .{})) return .up;
    if (key.matches(vaxis.Key.down, .{})) return .down;
    if (key.matches('k', .{})) return .up;
    if (key.matches('j', .{})) return .down;
    if (key.matches('g', .{})) return .top;
    if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) return .bottom;
    if (key.matches(vaxis.Key.enter, .{})) return .enter;
    if (key.matches('/', .{})) return .start_filter;
    // c/o reserved for scan — no silent steal.
    return .other;
}

/// Clamp a selection index into `[0, count)` (or `0` when empty).
pub fn clampSelected(selected: usize, item_count: usize) usize {
    if (item_count == 0) return 0;
    return @min(selected, item_count - 1);
}

/// Adjust list scroll so `selected` stays inside the visible window of
/// `list_rows` rows (pager semantics matching `scan/tui_view`).
pub fn scrollToShow(selected: usize, list_scroll: usize, list_rows: usize, item_count: usize) usize {
    if (item_count == 0) return 0;
    const sel = clampSelected(selected, item_count);
    const cap = if (list_rows == 0) item_count else list_rows;
    const max_start: usize = if (item_count > cap) item_count - cap else 0;
    var start = @min(list_scroll, max_start);
    if (sel < start) start = sel;
    if (cap > 0 and sel >= start + cap) start = sel + 1 - cap;
    return start;
}

/// Visible window for the list region: start inclusive, end exclusive.
pub const ListWindow = struct {
    start: usize,
    end: usize,
    scroll: usize,
};

pub fn listWindow(selected: usize, list_scroll: usize, list_rows: usize, item_count: usize) ListWindow {
    if (item_count == 0) return .{ .start = 0, .end = 0, .scroll = 0 };
    const sel = clampSelected(selected, item_count);
    const scroll = scrollToShow(sel, list_scroll, list_rows, item_count);
    const cap = if (list_rows == 0) item_count else list_rows;
    const end = @min(scroll + cap, item_count);
    return .{ .start = scroll, .end = end, .scroll = scroll };
}

/// Navigation + selection state (pure; no I/O).
pub const NavState = struct {
    selected: usize = 0,
    list_scroll: usize = 0,

    /// Apply a nav action and re-clamp selection + scroll for the current list.
    pub fn apply(self: *NavState, action: KeyAction, item_count: usize, list_rows: usize) void {
        switch (action) {
            .up => if (self.selected > 0) {
                self.selected -= 1;
            },
            .down => {
                if (item_count > 0 and self.selected + 1 < item_count) self.selected += 1;
            },
            .top => self.selected = 0,
            .bottom => self.selected = if (item_count > 0) item_count - 1 else 0,
            .quit, .enter, .start_filter, .other => {},
        }
        self.selected = clampSelected(self.selected, item_count);
        self.list_scroll = scrollToShow(self.selected, self.list_scroll, list_rows, item_count);
    }
};

/// Optional filter mode: active flag + query length into a caller-owned buffer.
/// When the filtered list shrinks, use `clampSelected` / `NavState.apply` with
/// the filtered count so the index stays in range.
pub const FilterModel = struct {
    active: bool = false,
    len: usize = 0,

    pub fn start(self: *FilterModel) void {
        self.active = true;
        self.len = 0;
    }

    pub fn cancel(self: *FilterModel) void {
        self.active = false;
        self.len = 0;
    }

    pub fn clearQuery(self: *FilterModel) void {
        self.len = 0;
    }

    pub fn append(self: *FilterModel, buf: []u8, c: u8) void {
        if (!self.active) return;
        if (self.len >= buf.len) return;
        // Printable ASCII only in the pure model (callers can extend).
        if (c < 0x20 or c > 0x7e) return;
        buf[self.len] = c;
        self.len += 1;
    }

    pub fn backspace(self: *FilterModel) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn query(self: FilterModel, buf: []const u8) []const u8 {
        return buf[0..@min(self.len, buf.len)];
    }
};

/// Inputs for the pure browse frame renderer.
pub const FrameInput = struct {
    title: []const u8,
    /// Row labels for the list region (already filtered by the caller).
    items: []const []const u8,
    selected: usize = 0,
    list_scroll: usize = 0,
    /// Max list rows in the viewport (`0` = show all).
    list_rows: usize = 8,
    /// Detail pane lines for the selected item (caller-built).
    detail_lines: []const []const u8 = &.{},
    /// Domain-specific footer fragment, e.g. `"e enable · d disable"`.
    /// Shared nav hints are always appended by `renderFrame`.
    footer_actions: []const u8 = "",
    /// Optional one-line toast (copy/confirm result); empty = none.
    status_msg: []const u8 = "",
    /// When non-null, the frame shows filter-mode chrome with this query.
    filter_query: ?[]const u8 = null,
    /// Paint token for the selected list row (packs uses `.success` mint green).
    selected_token: theme.Token = .text_bright,
    /// When set, replaces the auto `"1-N of M"` / `"0 of 0"` list range label
    /// (e.g. allowlist `"0 permanent entries"` for honest empty counts).
    list_range_override: ?[]const u8 = null,
    /// When false, omit `Enter ·` from the shared nav legend (domain has no
    /// activate action — e.g. allowlist detail is always visible).
    footer_show_enter: bool = true,
    /// When set and same length as `items`, `false` means the row is chrome
    /// (section/empty teach): selected glyph is `·` instead of actionable `›`.
    row_actionable: ?[]const bool = null,
};

/// Pure frame renderer: brand header, list with selection marker, detail region,
/// and action footer. Emits content + theme colour only — **no** alt-screen or
/// cursor controls. Returns lines written so a live loop can re-home the cursor.
pub fn renderFrame(
    io: std.Io,
    stdout: anytype,
    frame: FrameInput,
) !usize {
    return renderFrameWithLineEnding(io, stdout, frame, "\n");
}

pub fn renderFrameWithLineEnding(
    io: std.Io,
    stdout: anytype,
    frame: FrameInput,
    line_ending: []const u8,
) !usize {
    var written: usize = 0;
    const item_count = frame.items.len;
    const sel = clampSelected(frame.selected, item_count);
    const win = listWindow(sel, frame.list_scroll, frame.list_rows, item_count);

    // ── Header ──────────────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .brand, "🛡  ryk");
    try stdout.writeAll(" · ");
    try theme.paintBold(io, stdout, .text_bright, frame.title);
    try stdout.writeAll(line_ending);
    written += 1;

    if (frame.filter_query) |q| {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "filter");
        try stdout.writeAll("  ");
        try theme.paintBold(io, stdout, .text_bright, q);
        try theme.paint(io, stdout, .muted, "█");
        try stdout.writeAll(line_ending);
        written += 1;
    }

    try writeRule(io, stdout, line_ending);
    written += 1;

    // ── List ────────────────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .text_bright, "List");
    try stdout.writeAll("  ");
    var range_buf: [48]u8 = undefined;
    const range: []const u8 = if (frame.list_range_override) |ovr|
        ovr
    else if (item_count == 0)
        "0 of 0"
    else
        std.fmt.bufPrint(&range_buf, "{d}-{d} of {d}", .{
            win.start + 1,
            win.end,
            item_count,
        }) catch "list";
    try theme.paint(io, stdout, .muted, range);
    try stdout.writeAll(line_ending);
    written += 1;

    if (item_count == 0) {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, "(no items)");
        try stdout.writeAll(line_ending);
        written += 1;
    } else {
        if (win.start > 0) {
            try stdout.writeAll("  ");
            try theme.paint(io, stdout, .muted, "… earlier above");
            try stdout.writeAll(line_ending);
            written += 1;
        }
        var i = win.start;
        while (i < win.end) : (i += 1) {
            const is_sel = i == sel;
            const actionable = if (frame.row_actionable) |flags|
                (i < flags.len and flags[i])
            else
                true;
            // Actionable selection: ›. Chrome (section/empty): · so it does not
            // look like Enter will activate something.
            if (is_sel) {
                try stdout.writeAll(if (actionable) " ›" else " ·");
            } else {
                try stdout.writeAll("  ");
            }
            try stdout.writeAll(" ");
            if (is_sel) {
                try theme.paintBold(io, stdout, frame.selected_token, frame.items[i]);
            } else if (std.mem.startsWith(u8, frame.items[i], "●")) {
                // Enabled-pack rows: mint success even when not selected.
                try theme.paint(io, stdout, .success, frame.items[i]);
            } else if (isSectionChromeLabel(frame.items[i])) {
                // Dual-layer section headers: slightly stronger than muted.
                try theme.paintBold(io, stdout, .info, frame.items[i]);
            } else {
                try theme.paint(io, stdout, .muted, frame.items[i]);
            }
            try stdout.writeAll(line_ending);
            written += 1;
        }
        if (win.end < item_count) {
            try stdout.writeAll("  ");
            try theme.paint(io, stdout, .muted, "… more below");
            try stdout.writeAll(line_ending);
            written += 1;
        }
    }

    try writeRule(io, stdout, line_ending);
    written += 1;

    // ── Detail ──────────────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    try theme.paintBold(io, stdout, .text_bright, "Detail");
    try stdout.writeAll(line_ending);
    written += 1;

    if (frame.detail_lines.len == 0) {
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, if (item_count == 0) "(nothing selected)" else "(no detail)");
        try stdout.writeAll(line_ending);
        written += 1;
    } else {
        for (frame.detail_lines) |line| {
            try stdout.writeAll("  ");
            try writeDetailLine(io, stdout, line);
            try stdout.writeAll(line_ending);
            written += 1;
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────────
    try stdout.writeAll("  ");
    if (frame.status_msg.len > 0) {
        try theme.paint(io, stdout, .success, frame.status_msg);
        try stdout.writeAll("  ·  ");
    }
    if (frame.filter_query != null) {
        try theme.paint(io, stdout, .muted, "type to filter · Esc cancel · Enter apply · q quit");
    } else {
        // Shared nav contract always present; domain actions optional prefix.
        if (frame.footer_actions.len > 0) {
            try theme.paint(io, stdout, .muted, frame.footer_actions);
            try stdout.writeAll("  ·  ");
        }
        if (frame.footer_show_enter) {
            try theme.paint(io, stdout, .muted, "↑↓/jk move · g/G top/bot · Enter · / filter · q quit");
        } else {
            try theme.paint(io, stdout, .muted, "↑↓/jk move · g/G top/bot · / filter · q quit");
        }
    }
    try stdout.writeAll(line_ending);
    written += 1;

    return written;
}

/// Section chrome labels (allowlist dual-layer headers) get info-token paint.
fn isSectionChromeLabel(label: []const u8) bool {
    // "── project ──", "── user · 0 ──", ASCII fallback "--- project ---"
    if (label.len >= 2 and label[0] == '-' and label[1] == '-') return true;
    // UTF-8 box-drawing em dash sequence used by writeRule peers (U+2500 = e2 94 80)
    if (label.len >= 3 and label[0] == 0xe2 and label[1] == 0x94 and label[2] == 0x80) return true;
    return false;
}

/// How a detail line is painted (convention-based; keeps FrameInput as plain strings).
pub const DetailPaintKind = enum {
    /// Copy-paste CLI: `ryk allow …` — mint bold.
    command_cta,
    /// `Label: value` with short single-word label — muted label, bright value.
    labeled,
    /// Prose / multi-word prompts — muted.
    prose,
};

/// Classify a detail line for themed paint (pure; unit-tested).
pub fn classifyDetailLine(line: []const u8) DetailPaintKind {
    if (std.mem.startsWith(u8, line, "ryk ")) return .command_cta;
    if (std.mem.indexOf(u8, line, ": ")) |idx| {
        const left = line[0..idx];
        // Single short token labels only ("Layer", "Path", "kind", "reason") —
        // multi-word prompts like "Add a permanent exception (argv):" stay prose.
        if (left.len > 0 and left.len <= 16 and std.mem.indexOfScalar(u8, left, ' ') == null) {
            return .labeled;
        }
    }
    return .prose;
}

/// Paint one detail line: mint CTAs, muted labels + bright values, muted prose.
/// Content is sanitized (no CSI/C0 injection) before paint.
fn writeDetailLine(io: std.Io, stdout: anytype, line: []const u8) !void {
    var safe_buf: [512]u8 = undefined;
    var safe_w: std.Io.Writer = .fixed(&safe_buf);
    terminal_text.write(&safe_w, line, .single_line) catch {
        // Overflow / write error: never paint raw bytes (C0/CSI). Truncate + strip.
        const n = @min(line.len, safe_buf.len);
        var j: usize = 0;
        var i: usize = 0;
        while (i < n and j < safe_buf.len) : (i += 1) {
            const c = line[i];
            if (c < 0x20 or c == 0x7f) continue; // drop C0 / DEL
            if (c == 0x1b) continue; // drop ESC (CSI/OSC introducer)
            safe_buf[j] = c;
            j += 1;
        }
        const kind = classifyDetailLine(safe_buf[0..j]);
        try paintDetailKind(io, stdout, kind, safe_buf[0..j]);
        return;
    };
    const safe = safe_w.buffered();
    try paintDetailKind(io, stdout, classifyDetailLine(safe), safe);
}

fn paintDetailKind(io: std.Io, stdout: anytype, kind: DetailPaintKind, safe: []const u8) !void {
    switch (kind) {
        .command_cta => try theme.paintBold(io, stdout, .success, safe),
        .labeled => {
            const idx = std.mem.indexOf(u8, safe, ": ") orelse {
                try theme.paint(io, stdout, .muted, safe);
                return;
            };
            const split = idx + 2;
            try theme.paint(io, stdout, .muted, safe[0..split]);
            try theme.paint(io, stdout, .text_bright, safe[split..]);
        },
        .prose => try theme.paint(io, stdout, .muted, safe),
    }
}

fn writeRule(io: std.Io, stdout: anytype, line_ending: []const u8) !void {
    try stdout.writeAll("  ");
    const a = theme.active(io, stdout);
    const ch: []const u8 = if (a.supportsUnicode()) "─" else "-";
    var i: usize = 0;
    while (i < 62) : (i += 1) try stdout.writeAll(ch);
    try stdout.writeAll(line_ending);
}

// ── Tests (pure frame / selection / filter / keys; no raw TTY) ──────────────

test "browse keyToAction: scan-compatible nav and enter/filter" {
    const up: vaxis.Key = .{ .codepoint = vaxis.Key.up };
    const down: vaxis.Key = .{ .codepoint = vaxis.Key.down };
    const j_key: vaxis.Key = .{ .codepoint = 'j' };
    const k_key: vaxis.Key = .{ .codepoint = 'k' };
    const g_key: vaxis.Key = .{ .codepoint = 'g' };
    const G_key: vaxis.Key = .{ .codepoint = 'G' };
    const q_key: vaxis.Key = .{ .codepoint = 'q' };
    const esc: vaxis.Key = .{ .codepoint = vaxis.Key.escape };
    const enter: vaxis.Key = .{ .codepoint = vaxis.Key.enter };
    const slash: vaxis.Key = .{ .codepoint = '/' };

    try std.testing.expectEqual(KeyAction.up, keyToAction(up));
    try std.testing.expectEqual(KeyAction.down, keyToAction(down));
    try std.testing.expectEqual(KeyAction.down, keyToAction(j_key));
    try std.testing.expectEqual(KeyAction.up, keyToAction(k_key));
    try std.testing.expectEqual(KeyAction.top, keyToAction(g_key));
    try std.testing.expectEqual(KeyAction.bottom, keyToAction(G_key));
    try std.testing.expectEqual(KeyAction.quit, keyToAction(q_key));
    try std.testing.expectEqual(KeyAction.quit, keyToAction(esc));
    try std.testing.expectEqual(KeyAction.enter, keyToAction(enter));
    try std.testing.expectEqual(KeyAction.start_filter, keyToAction(slash));
}

test "browse keyToAction: c and o reserved as other (no silent steal)" {
    const c_key: vaxis.Key = .{ .codepoint = 'c' };
    const o_key: vaxis.Key = .{ .codepoint = 'o' };
    try std.testing.expectEqual(KeyAction.other, keyToAction(c_key));
    try std.testing.expectEqual(KeyAction.other, keyToAction(o_key));
}

test "browse clampSelected and NavState apply" {
    try std.testing.expectEqual(@as(usize, 0), clampSelected(5, 0));
    try std.testing.expectEqual(@as(usize, 2), clampSelected(99, 3));
    try std.testing.expectEqual(@as(usize, 0), clampSelected(0, 3));

    var nav: NavState = .{ .selected = 0, .list_scroll = 0 };
    nav.apply(.down, 5, 3);
    try std.testing.expectEqual(@as(usize, 1), nav.selected);
    nav.apply(.bottom, 5, 3);
    try std.testing.expectEqual(@as(usize, 4), nav.selected);
    // Selection at end keeps scroll so row is visible (list_rows=3 → start=2).
    try std.testing.expectEqual(@as(usize, 2), nav.list_scroll);
    nav.apply(.top, 5, 3);
    try std.testing.expectEqual(@as(usize, 0), nav.selected);
    try std.testing.expectEqual(@as(usize, 0), nav.list_scroll);
    nav.apply(.up, 5, 3);
    try std.testing.expectEqual(@as(usize, 0), nav.selected);
}

test "browse listWindow keeps selection visible and clamps filter shrink" {
    // 10 items, 3-row viewport, select index 7 → window must include 7.
    const win = listWindow(7, 0, 3, 10);
    try std.testing.expect(win.start <= 7 and 7 < win.end);
    try std.testing.expectEqual(@as(usize, 3), win.end - win.start);

    // After filter shrinks list from 10 → 2, selection 7 clamps to 1.
    const filtered_count: usize = 2;
    const sel = clampSelected(7, filtered_count);
    try std.testing.expectEqual(@as(usize, 1), sel);
    const win2 = listWindow(sel, 99, 3, filtered_count);
    try std.testing.expectEqual(@as(usize, 0), win2.start);
    try std.testing.expectEqual(@as(usize, 2), win2.end);
}

test "browse FilterModel start/append/backspace/cancel" {
    var filt: FilterModel = .{};
    var buf: [32]u8 = undefined;
    filt.start();
    try std.testing.expect(filt.active);
    filt.append(&buf, 'a');
    filt.append(&buf, 'b');
    try std.testing.expectEqualStrings("ab", filt.query(&buf));
    filt.backspace();
    try std.testing.expectEqualStrings("a", filt.query(&buf));
    filt.cancel();
    try std.testing.expect(!filt.active);
    try std.testing.expectEqual(@as(usize, 0), filt.len);
}

test "browse renderFrame: selection marker, detail, footer" {
    theme.resetCache();
    const items = [_][]const u8{ "alpha", "beta", "gamma" };
    const detail = [_][]const u8{ "name: beta", "state: enabled" };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const n = try renderFrame(std.testing.io, &w, .{
        .title = "packs",
        .items = &items,
        .selected = 1,
        .list_rows = 8,
        .detail_lines = &detail,
        .footer_actions = "e enable · d disable",
    });
    const out = w.buffered();
    try std.testing.expect(n > 6);
    try std.testing.expect(std.mem.indexOf(u8, out, "🛡  ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "List") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name: beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "e enable · d disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "↑↓/jk move") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/ filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "q quit") != null);
    // Pure frame: no alt-screen / cursor controls.
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.smcup) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.rmcup) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, vaxis.ctlseqs.hide_cursor) == null);
}

test "browse renderFrame: filter mode chrome and empty list" {
    theme.resetCache();
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, .{
        .title = "allowlist",
        .items = &.{},
        .filter_query = "net",
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(no items)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Esc cancel") != null);
}

test "browse renderFrame: range override, hide enter, chrome selection glyph" {
    theme.resetCache();
    const items = [_][]const u8{ "── project ──", "(0 entries)" };
    const actionable = [_]bool{ false, false };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, .{
        .title = "allowlist",
        .items = &items,
        .selected = 1,
        .list_rows = 8,
        .list_range_override = "0 permanent entries",
        .footer_show_enter = false,
        .row_actionable = &actionable,
        .selected_token = .success,
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "0 permanent entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1-2 of 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Enter ·") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/ filter") != null);
    // Chrome selection uses · not actionable ›
    try std.testing.expect(std.mem.indexOf(u8, out, " · ") != null);
}

test "browse classifyDetailLine: command CTA, labeled, prose" {
    try std.testing.expectEqual(DetailPaintKind.command_cta, classifyDetailLine("ryk allow <rule> -r \"reason\""));
    try std.testing.expectEqual(DetailPaintKind.command_cta, classifyDetailLine("ryk allowlist add-command <cmd> -r \"reason\""));
    try std.testing.expectEqual(DetailPaintKind.labeled, classifyDetailLine("Layer: project  ·  0 permanent entries"));
    try std.testing.expectEqual(DetailPaintKind.labeled, classifyDetailLine("Path:  /ws/.ryk/allowlist.toml"));
    try std.testing.expectEqual(DetailPaintKind.labeled, classifyDetailLine("kind: rule  key: core.git:reset-hard"));
    try std.testing.expectEqual(DetailPaintKind.labeled, classifyDetailLine("reason: recover"));
    try std.testing.expectEqual(DetailPaintKind.prose, classifyDetailLine("Add a permanent exception (argv):"));
    try std.testing.expectEqual(DetailPaintKind.prose, classifyDetailLine("Select an entry for kind, reason, and expiry."));
    try std.testing.expectEqual(DetailPaintKind.prose, classifyDetailLine("(no detail)"));
}

test "browse renderFrame: detail paints command CTAs without losing text" {
    theme.resetCache();
    const items = [_][]const u8{"── project ──"};
    const detail = [_][]const u8{
        "Layer: project  ·  0 permanent entries",
        "Path:  /tmp/allowlist.toml",
        "Add a permanent exception (argv):",
        "ryk allow <rule> -r \"reason\"",
        "ryk allowlist add-command <cmd> -r \"reason\"",
    };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, .{
        .title = "allowlist",
        .items = &items,
        .detail_lines = &detail,
        .selected_token = .success,
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Layer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "project  ·  0 permanent entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk allow <rule>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ryk allowlist add-command") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Add a permanent exception") != null);
}

test "browse renderFrame: list window honour scroll and selection clamp" {
    theme.resetCache();
    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // selected=4 (e), list_rows=2 → window should show d,e not a.
    _ = try renderFrame(std.testing.io, &w, .{
        .title = "browse",
        .items = &items,
        .selected = 4,
        .list_scroll = 0,
        .list_rows = 2,
        .detail_lines = &.{"detail-e"},
    });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "e") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "detail-e") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "4-5 of 5") != null or std.mem.indexOf(u8, out, "3-5 of 5") != null or std.mem.indexOf(u8, out, "of 5") != null);
    // Overflow selection clamps.
    var w2: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w2, .{
        .title = "browse",
        .items = &items,
        .selected = 99,
        .list_rows = 2,
        .detail_lines = &.{"clamped"},
    });
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "clamped") != null);
}

test "browse renderFrame: status toast in footer" {
    theme.resetCache();
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try renderFrame(std.testing.io, &w, .{
        .title = "packs",
        .items = &.{"one"},
        .status_msg = "enabled pack-x",
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "enabled pack-x") != null);
}
