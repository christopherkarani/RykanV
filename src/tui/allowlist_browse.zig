//! Allowlist dual-layer browse model (pure builders + optional TTY loop).
//!
//! Product contract (W2 / U05):
//! - Project section **then** user section
//! - Empty sections teach **permanent** allow path only (`ryk allow` /
//!   `allowlist add-command`) — **never** allow-once
//! - Status line = write target (project vs user path)
//! - Remove uses confirm **default No**; cancel = no write
//! - No add wizard; no allow-once in TUI
//!
//! Uses `tui.browse` for list/detail/footer/filter. Callers gate with
//! `output_policy.shouldEnterTui` before `run`. Alt-screen restore is owned
//! by `run` (same pattern as scan / live_view).
const std = @import("std");
const builtin = @import("builtin");
const browse = @import("browse.zig");
const output_policy = @import("output_policy.zig");
const prompt = @import("prompt.zig");
const vaxis = @import("vaxis");

// ---------------------------------------------------------------------------
// Entry view (caller maps from allowlist_store; no shell_engine dep here)
// ---------------------------------------------------------------------------

pub const Layer = enum { project, user };

pub const EntryView = struct {
    kind: []const u8, // "rule" | "command"
    key: []const u8,
    reason: []const u8,
    layer: Layer,
    expired: bool = false,
    created_at: []const u8 = "",
    expires_at: ?[]const u8 = null,
};

pub const RowKind = enum {
    section_header,
    empty_teach,
    entry,
};

pub const BrowseRow = struct {
    kind: RowKind,
    label: []const u8,
    layer: Layer,
    /// Index into the corresponding layer entry slice; null for chrome rows.
    entry_index: ?usize = null,
    key: []const u8 = "",
    removable: bool = false,
};

/// Empty-section teaching — permanent path only (must not mention allow-once).
pub const empty_teach_line =
    "(empty) permanent: ryk allow <rule> -r \"…\" · allowlist add-command …";

pub const section_project = "── project ──";
pub const section_user = "── user ──";

/// Domain footer fragment for browse kit (shared nav appended by renderFrame).
pub const footer_actions = "r remove";

pub const title = "allowlist";

// ---------------------------------------------------------------------------
// Pure builders
// ---------------------------------------------------------------------------

/// True when list should open the browse TUI (TTY pair + no machine/plain/no-rich).
pub fn shouldEnterAllowlistBrowse(stdin_is_tty: bool, stdout_is_tty: bool, argv: []const []const u8) bool {
    return output_policy.shouldEnterTui(stdin_is_tty, stdout_is_tty, argv);
}

/// Runtime convenience over real stdin/stdout TTYs.
pub fn shouldEnterAllowlistBrowseIo(io: std.Io, argv: []const []const u8) bool {
    return output_policy.shouldEnterTuiIo(io, argv);
}

/// Confirm remove default No: empty / n / anything except y/yes → false.
/// Pure answer parse (no I/O) for cancel = no write fixtures.
pub fn confirmRemoveDefaultNo(answer: []const u8) bool {
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

/// Write-target status line into caller buffer. Returns written slice.
pub fn formatWriteTargetStatus(
    buf: []u8,
    write_layer: Layer,
    project_path: []const u8,
    user_path: []const u8,
) []const u8 {
    const path = switch (write_layer) {
        .project => project_path,
        .user => user_path,
    };
    const layer_name: []const u8 = switch (write_layer) {
        .project => "project",
        .user => "user",
    };
    return std.fmt.bufPrint(buf, "write: {s} → {s}", .{ layer_name, path }) catch {
        return switch (write_layer) {
            .project => "write: project",
            .user => "write: user",
        };
    };
}

/// Format a single entry list label (borrowed key/kind; no alloc).
pub fn formatEntryLabel(buf: []u8, e: EntryView) []const u8 {
    return std.fmt.bufPrint(buf, "{s}  {s}{s}", .{
        e.kind,
        e.key,
        if (e.expired) " [expired]" else "",
    }) catch e.key;
}

pub const DualLayerModel = struct {
    rows: []BrowseRow,
    /// Parallel labels for `browse.FrameInput.items` (points into rows[].label).
    labels: []const []const u8,
    project_path: []const u8,
    user_path: []const u8,
    write_layer: Layer,
    /// Owned label buffers for entry rows (section/empty use static strings).
    owned_labels: [][]u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *DualLayerModel) void {
        for (self.owned_labels) |s| self.gpa.free(s);
        self.gpa.free(self.owned_labels);
        self.gpa.free(self.rows);
        self.gpa.free(@constCast(self.labels));
        self.* = undefined;
    }

    pub fn rowCount(self: DualLayerModel) usize {
        return self.rows.len;
    }

    pub fn selectedRow(self: DualLayerModel, selected: usize) ?BrowseRow {
        if (self.rows.len == 0) return null;
        return self.rows[browse.clampSelected(selected, self.rows.len)];
    }
};

/// Build dual-layer list: project section then user section.
/// Empty sections get a permanent-path teaching row (not allow-once).
pub fn buildDualLayer(
    gpa: std.mem.Allocator,
    project_entries: []const EntryView,
    user_entries: []const EntryView,
    project_path: []const u8,
    user_path: []const u8,
    write_layer: Layer,
) !DualLayerModel {
    var row_list: std.ArrayListUnmanaged(BrowseRow) = .empty;
    errdefer row_list.deinit(gpa);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    try appendSection(gpa, &row_list, &owned, .project, section_project, project_entries);
    try appendSection(gpa, &row_list, &owned, .user, section_user, user_entries);

    const rows = try row_list.toOwnedSlice(gpa);
    errdefer gpa.free(rows);
    const owned_labels = try owned.toOwnedSlice(gpa);
    errdefer {
        for (owned_labels) |s| gpa.free(s);
        gpa.free(owned_labels);
    }

    const labels = try gpa.alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| labels[i] = r.label;

    return .{
        .rows = rows,
        .labels = labels,
        .project_path = project_path,
        .user_path = user_path,
        .write_layer = write_layer,
        .owned_labels = owned_labels,
        .gpa = gpa,
    };
}

fn appendSection(
    gpa: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(BrowseRow),
    owned: *std.ArrayListUnmanaged([]u8),
    layer: Layer,
    header: []const u8,
    entries: []const EntryView,
) !void {
    try rows.append(gpa, .{
        .kind = .section_header,
        .label = header,
        .layer = layer,
    });
    if (entries.len == 0) {
        try rows.append(gpa, .{
            .kind = .empty_teach,
            .label = empty_teach_line,
            .layer = layer,
        });
        return;
    }
    for (entries, 0..) |e, idx| {
        var buf: [256]u8 = undefined;
        const raw = formatEntryLabel(&buf, e);
        const label = try gpa.dupe(u8, raw);
        try owned.append(gpa, label);
        try rows.append(gpa, .{
            .kind = .entry,
            .label = label,
            .layer = layer,
            .entry_index = idx,
            .key = e.key,
            .removable = true,
        });
    }
}

/// Detail lines for the selected row (static + stack buffers owned by caller).
pub const DetailBufs = struct {
    line0: [128]u8 = undefined,
    line1: [256]u8 = undefined,
    line2: [128]u8 = undefined,
    line3: [96]u8 = undefined,
    lines: [4][]const u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *DetailBufs) []const []const u8 {
        return self.lines[0..self.count];
    }
};

pub fn fillDetail(
    detail: *DetailBufs,
    row: BrowseRow,
    project_entries: []const EntryView,
    user_entries: []const EntryView,
) void {
    detail.count = 0;
    switch (row.kind) {
        .section_header => {
            detail.lines[0] = switch (row.layer) {
                .project => "Project layer (.orca/allowlist.toml)",
                .user => "User layer ($XDG_CONFIG_HOME/orca/allowlist.toml)",
            };
            detail.lines[1] = "Permanent pack exceptions only — not allow-once.";
            detail.lines[2] = "Add: ryk allow <rule> -r \"…\" · allowlist add-command …";
            detail.count = 3;
        },
        .empty_teach => {
            detail.lines[0] = "No permanent entries in this layer.";
            detail.lines[1] = empty_teach_line;
            detail.lines[2] = "allow-once is argv-only and never shown here.";
            detail.count = 3;
        },
        .entry => {
            const entries = switch (row.layer) {
                .project => project_entries,
                .user => user_entries,
            };
            const idx = row.entry_index orelse {
                detail.lines[0] = "(missing entry)";
                detail.count = 1;
                return;
            };
            if (idx >= entries.len) {
                detail.lines[0] = "(stale selection)";
                detail.count = 1;
                return;
            }
            const e = entries[idx];
            detail.lines[0] = std.fmt.bufPrint(&detail.line0, "kind: {s}  key: {s}", .{ e.kind, e.key }) catch "entry";
            detail.lines[1] = std.fmt.bufPrint(&detail.line1, "reason: {s}", .{e.reason}) catch e.reason;
            detail.lines[2] = std.fmt.bufPrint(&detail.line2, "layer: {s}{s}", .{
                if (e.layer == .project) "project" else "user",
                if (e.expired) "  [expired]" else "",
            }) catch "layer";
            if (e.expires_at) |exp| {
                detail.lines[3] = std.fmt.bufPrint(&detail.line3, "expires: {s}", .{exp}) catch exp;
                detail.count = 4;
            } else {
                detail.lines[3] = "expires: (none)";
                detail.count = 4;
            }
        },
    }
}

/// Whether teaching / frame text is permanent-only (no allow-once leakage).
pub fn textMentionsAllowOnce(text: []const u8) bool {
    // Deliberate check used by tests: empty teach must not advertise allow-once
    // as a path to fill the list. Detail may mention "never shown" — that is OK
    // for teaching what is out of scope; empty *list* label must stay permanent.
    return std.mem.indexOf(u8, text, "allow-once") != null or
        std.mem.indexOf(u8, text, "allow once") != null or
        std.mem.indexOf(u8, text, "allow_once") != null;
}

/// Apply remove only when confirmed; cancel leaves store untouched.
/// Returns true if a remove write was attempted/performed.
pub fn applyRemoveIfConfirmed(
    confirmed: bool,
    remove_fn: *const fn () anyerror!bool,
) !bool {
    if (!confirmed) return false;
    return try remove_fn();
}

// ---------------------------------------------------------------------------
// TTY run loop (alt-screen; no-op under unit tests)
// ---------------------------------------------------------------------------

pub const RemoveRequest = struct {
    layer: Layer,
    key: []const u8,
};

pub const RunHooks = struct {
    /// Called when user confirms remove; return true if entry was removed.
    remove: *const fn (ctx: *anyopaque, req: RemoveRequest) anyerror!bool,
    ctx: *anyopaque,
};

pub const RunInput = struct {
    project_entries: []const EntryView,
    user_entries: []const EntryView,
    project_path: []const u8,
    user_path: []const u8,
    write_layer: Layer,
    hooks: RunHooks,
};

/// Enter browse TUI. Returns `error.TtyUnavailable` before alt-screen when TTY
/// cannot open. Under `builtin.is_test`, returns immediately (pure tests only).
pub fn run(io: std.Io, gpa: std.mem.Allocator, stdout: anytype, input: RunInput) !void {
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

    try stdout.writeAll(vaxis.ctlseqs.smcup);
    defer {
        stdout.writeAll(vaxis.ctlseqs.show_cursor) catch {};
        stdout.writeAll(vaxis.ctlseqs.rmcup) catch {};
    }
    try stdout.writeAll(vaxis.ctlseqs.hide_cursor);

    const project_entries = input.project_entries;
    const user_entries = input.user_entries;

    var model = try buildDualLayer(
        gpa,
        project_entries,
        user_entries,
        input.project_path,
        input.user_path,
        input.write_layer,
    );
    defer model.deinit();

    var nav: browse.NavState = .{};
    var filter: browse.FilterModel = .{};
    var filter_buf: [64]u8 = undefined;
    var status_buf: [96]u8 = undefined;
    var status_len: usize = 0;
    var write_status_buf: [192]u8 = undefined;
    const write_status = formatWriteTargetStatus(
        &write_status_buf,
        input.write_layer,
        input.project_path,
        input.user_path,
    );

    const list_rows: usize = blk: {
        const ws = tty.getWinsize() catch break :blk 8;
        if (ws.rows < 16) break :blk 4;
        const avail = ws.rows -| 16;
        break :blk if (avail < 4) 4 else @min(avail, 12);
    };

    var decoder: Decoder = .{};
    var frame_lines: usize = 0;
    var first_frame = true;

    // Filtered index map: filtered_labels[i] → model.rows index
    var map_buf: [512]usize = undefined;
    var label_ptrs: [512][]const u8 = undefined;

    while (true) {
        const q = if (filter.active) filter.query(&filter_buf) else null;
        const filt = buildFilteredView(model, q, &map_buf, &label_ptrs);
        const item_count = filt.len;
        nav.selected = browse.clampSelected(nav.selected, item_count);
        nav.list_scroll = browse.scrollToShow(nav.selected, nav.list_scroll, list_rows, item_count);

        var detail_bufs: DetailBufs = .{};
        if (item_count > 0) {
            const row_idx = filt.map[nav.selected];
            fillDetail(&detail_bufs, model.rows[row_idx], project_entries, user_entries);
        }

        // Prefer transient toast; else show write-target as sticky status.
        const status_msg: []const u8 = if (status_len > 0) status_buf[0..status_len] else write_status;

        if (!first_frame and frame_lines > 0) {
            try moveCursorUp(stdout, frame_lines);
            try stdout.writeAll("\x1b[J");
        }
        first_frame = false;

        frame_lines = try browse.renderFrameWithLineEnding(io, stdout, .{
            .title = title,
            .items = filt.labels,
            .selected = nav.selected,
            .list_scroll = nav.list_scroll,
            .list_rows = list_rows,
            .detail_lines = detail_bufs.slice(),
            .footer_actions = footer_actions,
            .status_msg = status_msg,
            .filter_query = q,
        }, "\r\n");
        try flush(stdout);

        const key = readKey(&tty, &decoder) catch break;
        if (filter.active) {
            if (key.matches(vaxis.Key.escape, .{})) {
                filter.cancel();
                status_len = 0;
                continue;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                filter.active = false;
                status_len = 0;
                continue;
            }
            if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.delete, .{})) {
                filter.backspace();
                continue;
            }
            if (key.codepoint >= 0x20 and key.codepoint <= 0x7e and !key.mods.ctrl and !key.mods.alt) {
                filter.append(&filter_buf, @intCast(key.codepoint));
                continue;
            }
            if (key.matches('q', .{})) break;
            continue;
        }

        const action = browse.keyToAction(key);
        switch (action) {
            .quit => break,
            .up, .down, .top, .bottom => {
                status_len = 0;
                nav.apply(action, item_count, list_rows);
            },
            .enter => {
                // Detail already shown; no-op activate.
                status_len = 0;
            },
            .start_filter => {
                filter.start();
                status_len = 0;
            },
            .other => {
                if (key.matches('r', .{})) {
                    if (item_count == 0) continue;
                    const row_idx = filt.map[nav.selected];
                    const row = model.rows[row_idx];
                    if (!row.removable or row.key.len == 0) {
                        const msg = "select an entry to remove";
                        status_len = @min(msg.len, status_buf.len);
                        @memcpy(status_buf[0..status_len], msg[0..status_len]);
                        continue;
                    }
                    // Leave alt-screen for line confirm (default No).
                    stdout.writeAll(vaxis.ctlseqs.show_cursor) catch {};
                    stdout.writeAll(vaxis.ctlseqs.rmcup) catch {};
                    var msg_buf: [160]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Remove allowlist entry '{s}'?", .{row.key}) catch "Remove entry?";
                    const confirmed = prompt.confirm(io, stdout, .normal, msg, null) catch false;
                    // Re-enter alt-screen for continued browsing.
                    stdout.writeAll(vaxis.ctlseqs.smcup) catch {};
                    stdout.writeAll(vaxis.ctlseqs.hide_cursor) catch {};
                    first_frame = true;
                    frame_lines = 0;
                    if (!confirmRemoveDefaultNo(if (confirmed) "y" else "")) {
                        const cmsg = "remove cancelled";
                        status_len = @min(cmsg.len, status_buf.len);
                        @memcpy(status_buf[0..status_len], cmsg[0..status_len]);
                        continue;
                    }
                    const removed = input.hooks.remove(input.hooks.ctx, .{
                        .layer = row.layer,
                        .key = row.key,
                    }) catch false;
                    if (removed) {
                        // Host owns reload; quit so list path can rebuild or exit cleanly.
                        break;
                    } else {
                        const fmsg = "remove failed";
                        status_len = @min(fmsg.len, status_buf.len);
                        @memcpy(status_buf[0..status_len], fmsg[0..status_len]);
                    }
                }
            },
        }
    }
}

const FilteredView = struct {
    labels: []const []const u8,
    map: []const usize,
    len: usize,
};

fn buildFilteredView(
    model: DualLayerModel,
    query: ?[]const u8,
    map_buf: []usize,
    label_buf: [][]const u8,
) FilteredView {
    var n: usize = 0;
    const q = query orelse {
        const cap = @min(model.rows.len, map_buf.len);
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            map_buf[i] = i;
            label_buf[i] = model.labels[i];
        }
        return .{ .labels = label_buf[0..cap], .map = map_buf[0..cap], .len = cap };
    };
    if (q.len == 0) {
        const cap = @min(model.rows.len, map_buf.len);
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            map_buf[i] = i;
            label_buf[i] = model.labels[i];
        }
        return .{ .labels = label_buf[0..cap], .map = map_buf[0..cap], .len = cap };
    }
    for (model.rows, 0..) |row, i| {
        if (n >= map_buf.len) break;
        // Always keep section headers so dual-layer structure remains visible;
        // filter entry/teach rows by substring (case-sensitive ASCII).
        const keep = row.kind == .section_header or
            std.mem.indexOf(u8, row.label, q) != null or
            std.mem.indexOf(u8, row.key, q) != null;
        if (keep) {
            map_buf[n] = i;
            label_buf[n] = row.label;
            n += 1;
        }
    }
    return .{ .labels = label_buf[0..n], .map = map_buf[0..n], .len = n };
}

// ── TTY helpers (mirrors scan/tui_view; keep local to exclusive write set) ──

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
        return null;
    }

    fn interByteTimeout(self: *Decoder) ?vaxis.Key {
        if (self.len == 1 and self.carry[0] == 0x1b) {
            self.len = 0;
            // Synthetic escape key
            return .{ .codepoint = vaxis.Key.escape };
        }
        return null;
    }
};

fn readKey(tty: *vaxis.tty.Tty, decoder: *Decoder) !vaxis.Key {
    if (comptime builtin.os.tag == .windows) {
        while (true) switch (try tty.nextEvent(&decoder.parser, null)) {
            .key_press => |key| return key,
            else => {},
        };
    }
    configureReadTimeout(tty);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.posix.read(tty.fd.handle, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n == 0) {
            if (decoder.interByteTimeout()) |key| return key;
            continue;
        }
        if (try decoder.feed(buf[0..n])) |key| return key;
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

// ---------------------------------------------------------------------------
// Tests (pure; no TTY loop)
// ---------------------------------------------------------------------------

test "s-allowlist browse: dual-layer project section then user" {
    const gpa = std.testing.allocator;
    const project = [_]EntryView{
        .{ .kind = "rule", .key = "core.git:reset-hard", .reason = "recover", .layer = .project },
    };
    const user = [_]EntryView{
        .{ .kind = "command", .key = "git status", .reason = "ci", .layer = .user },
    };
    var model = try buildDualLayer(gpa, &project, &user, "/proj/.orca/allowlist.toml", "/home/u/.config/orca/allowlist.toml", .project);
    defer model.deinit();

    try std.testing.expect(model.rows.len >= 4);
    try std.testing.expectEqual(RowKind.section_header, model.rows[0].kind);
    try std.testing.expectEqual(Layer.project, model.rows[0].layer);
    try std.testing.expectEqualStrings(section_project, model.rows[0].label);

    try std.testing.expectEqual(RowKind.entry, model.rows[1].kind);
    try std.testing.expectEqual(Layer.project, model.rows[1].layer);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[1].label, "core.git:reset-hard") != null);

    // User section after project
    var user_header_idx: ?usize = null;
    for (model.rows, 0..) |r, i| {
        if (r.kind == .section_header and r.layer == .user) {
            user_header_idx = i;
            break;
        }
    }
    try std.testing.expect(user_header_idx != null);
    try std.testing.expect(user_header_idx.? > 1);
    try std.testing.expectEqualStrings(section_user, model.rows[user_header_idx.?].label);

    const after = model.rows[user_header_idx.? + 1];
    try std.testing.expectEqual(RowKind.entry, after.kind);
    try std.testing.expect(std.mem.indexOf(u8, after.label, "git status") != null);
}

test "s-allowlist browse: empty sections teach permanent path not allow-once" {
    const gpa = std.testing.allocator;
    var model = try buildDualLayer(gpa, &.{}, &.{}, "p.toml", "u.toml", .user);
    defer model.deinit();

    var saw_empty = false;
    for (model.rows) |r| {
        if (r.kind == .empty_teach) {
            saw_empty = true;
            try std.testing.expectEqualStrings(empty_teach_line, r.label);
            try std.testing.expect(!textMentionsAllowOnce(r.label));
            try std.testing.expect(std.mem.indexOf(u8, r.label, "ryk allow") != null);
            try std.testing.expect(std.mem.indexOf(u8, r.label, "add-command") != null);
        }
    }
    try std.testing.expect(saw_empty);
    // Both layers empty → two teach rows
    var teach_count: usize = 0;
    for (model.rows) |r| {
        if (r.kind == .empty_teach) teach_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), teach_count);
}

test "s-allowlist browse: write-target status reflects layer path" {
    var buf: [192]u8 = undefined;
    const proj = formatWriteTargetStatus(&buf, .project, "/ws/.orca/allowlist.toml", "/u/allowlist.toml");
    try std.testing.expect(std.mem.indexOf(u8, proj, "project") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj, "/ws/.orca/allowlist.toml") != null);

    const user = formatWriteTargetStatus(&buf, .user, "/ws/.orca/allowlist.toml", "/u/allowlist.toml");
    try std.testing.expect(std.mem.indexOf(u8, user, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, user, "/u/allowlist.toml") != null);
}

test "s-allowlist browse: remove confirm default No; cancel skips write" {
    try std.testing.expect(!confirmRemoveDefaultNo(""));
    try std.testing.expect(!confirmRemoveDefaultNo("   "));
    try std.testing.expect(!confirmRemoveDefaultNo("n"));
    try std.testing.expect(!confirmRemoveDefaultNo("N"));
    try std.testing.expect(!confirmRemoveDefaultNo("no"));
    try std.testing.expect(!confirmRemoveDefaultNo("maybe"));
    try std.testing.expect(confirmRemoveDefaultNo("y"));
    try std.testing.expect(confirmRemoveDefaultNo("Y"));
    try std.testing.expect(confirmRemoveDefaultNo("yes"));
    try std.testing.expect(confirmRemoveDefaultNo("YES"));

    var wrote = false;
    const remove_fn = struct {
        var flag: *bool = undefined;
        fn call() anyerror!bool {
            flag.* = true;
            return true;
        }
    };
    remove_fn.flag = &wrote;

    const cancelled = try applyRemoveIfConfirmed(false, remove_fn.call);
    try std.testing.expect(!cancelled);
    try std.testing.expect(!wrote);

    const ok = try applyRemoveIfConfirmed(true, remove_fn.call);
    try std.testing.expect(ok);
    try std.testing.expect(wrote);
}

test "s-allowlist browse: shouldEnter mirrors output_policy gate" {
    try std.testing.expect(shouldEnterAllowlistBrowse(true, true, &.{ "allowlist", "list" }));
    try std.testing.expect(shouldEnterAllowlistBrowse(true, true, &.{}));
    try std.testing.expect(!shouldEnterAllowlistBrowse(false, true, &.{"list"}));
    try std.testing.expect(!shouldEnterAllowlistBrowse(true, false, &.{"list"}));
    try std.testing.expect(!shouldEnterAllowlistBrowse(true, true, &.{ "list", "--json" }));
    try std.testing.expect(!shouldEnterAllowlistBrowse(true, true, &.{ "list", "--plain" }));
    try std.testing.expect(!shouldEnterAllowlistBrowse(true, true, &.{ "list", "--no-rich" }));
    try std.testing.expect(!shouldEnterAllowlistBrowse(true, true, &.{ "list", "--robot" }));
}

test "s-allowlist browse: frame shows dual-layer and write status without alt-screen" {
    const gpa = std.testing.allocator;
    const project = [_]EntryView{
        .{ .kind = "rule", .key = "core.git:clean-fdx", .reason = "wipe", .layer = .project },
    };
    var model = try buildDualLayer(gpa, &project, &.{}, "P.toml", "U.toml", .project);
    defer model.deinit();

    var detail: DetailBufs = .{};
    fillDetail(&detail, model.rows[1], &project, &.{});

    var status_buf: [128]u8 = undefined;
    const status = formatWriteTargetStatus(&status_buf, .project, "P.toml", "U.toml");

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const lines = try browse.renderFrame(std.testing.io, &out, .{
        .title = title,
        .items = model.labels,
        .selected = 1,
        .list_rows = 8,
        .detail_lines = detail.slice(),
        .footer_actions = footer_actions,
        .status_msg = status,
    });
    try std.testing.expect(lines > 0);
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, section_project) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, section_user) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "core.git:clean-fdx") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, empty_teach_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "write: project") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "r remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, vaxis.ctlseqs.smcup) == null);
    // List empty-teach label never advertises allow-once
    try std.testing.expect(!textMentionsAllowOnce(empty_teach_line));
}
