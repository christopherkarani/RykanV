//! Memorable session-start shield card for OS sandbox posture.
//!
//! Human-first visual language. Machine tokens (`OS sandbox: active`,
//! `seatbelt_profile=<grade>`, `Posture: …`) stay greppable in a dim receipt
//! footer so scripts and tests keep working.

const std = @import("std");
const builtin = @import("builtin");
const theme = @import("theme.zig");
const tui_render = @import("render.zig");

/// Live OS sandbox posture for presentation only (mirrors posture.SessionPosture tags).
pub const PostureKind = enum {
    active,
    prepared,
    unavailable,
    failed,
    disabled,

    pub fn parse(tag: []const u8) PostureKind {
        if (std.mem.eql(u8, tag, "active")) return .active;
        if (std.mem.eql(u8, tag, "prepared")) return .prepared;
        if (std.mem.eql(u8, tag, "unavailable")) return .unavailable;
        if (std.mem.eql(u8, tag, "failed")) return .failed;
        return .disabled;
    }

    /// True when session start shows the dramatic shield card (not the compact disabled line).
    pub fn isDramatic(self: PostureKind) bool {
        return switch (self) {
            .active, .prepared, .unavailable, .failed => true,
            .disabled => false,
        };
    }
};

/// Minimum on-screen dwell for the shield card so humans can read it (interactive TTY only).
pub const hold_ns: u64 = 2 * std.time.ns_per_s;

/// Pure decision: should we pause after rendering the shield card?
///
/// Hold only for dramatic postures on a real interactive terminal. Skip tests,
/// pipes, `TERM=dumb`, and when `hold_disabled` (e.g. `ORCA_SHIELD_HOLD=0`).
pub fn shouldHold(posture: PostureKind, is_tty: bool, term_dumb: bool, hold_disabled: bool) bool {
    if (hold_disabled) return false;
    if (!is_tty or term_dumb) return false;
    return posture.isDramatic();
}

/// Block for `hold_ns` when `shouldHold` is true. No-op in tests and when hold is skipped.
pub fn holdIfNeeded(io: std.Io, posture: PostureKind, is_tty: bool, term_dumb: bool, hold_disabled: bool) void {
    if (builtin.is_test) return;
    if (!shouldHold(posture, is_tty, term_dumb, hold_disabled)) return;
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(hold_ns), .awake) catch {};
}

/// Inputs for the shield card. All slices are borrowed for the call.
pub const CardInput = struct {
    posture: PostureKind,
    /// Raw fs_scope from the attach receipt (shown humanized + kept in receipt).
    fs_scope: []const u8,
    network_scope: []const u8,
    /// Optional residual grade token value, e.g. `hardened` (not the full key=value).
    seatbelt_profile: ?[]const u8 = null,
    secretless: bool,
    with_host_secrets: bool,
    network_mode: []const u8,
    gateway_label: []const u8,
    /// Full greppable posture line including trailing newline, e.g. `Posture: …\n`.
    machine_posture_line: []const u8,
    /// Full greppable OS sandbox banner line (no trailing newline required).
    machine_os_line: []const u8,
};

const CardLook = struct {
    token: theme.Token,
    title: []const u8,
    tagline: []const u8,
};

fn lookFor(kind: PostureKind) CardLook {
    return switch (kind) {
        .active => .{
            .token = .success,
            .title = "SHIELD UP",
            .tagline = "  Agent fenced · files, secrets, and tools under watch",
        },
        .prepared => .{
            .token = .info,
            .title = "SHIELD ARMING",
            .tagline = "  Sandbox prepared · attach pending on the child",
        },
        .unavailable => .{
            .token = .warn,
            .title = "SHIELD UNAVAILABLE",
            .tagline = "  OS sandbox not available · credentials retained",
        },
        .failed => .{
            .token = .danger,
            .title = "SHIELD FAILED",
            .tagline = "  OS sandbox failed to attach · credentials retained",
        },
        .disabled => .{
            .token = .muted,
            .title = "SHIELD OFF",
            .tagline = "  OS sandbox disabled for this session",
        },
    };
}

/// Human-friendly filesystem line derived from machine `fs_scope` tokens.
/// Writes into `buf`; returns a slice of `buf` or a static fallback.
pub fn humanizeFsScope(buf: []u8, fs_scope: []const u8) []const u8 {
    if (fs_scope.len == 0 or std.mem.eql(u8, fs_scope, "none")) return "none";

    var parts: [6][]const u8 = undefined;
    var n: usize = 0;

    const add = struct {
        fn push(list: *[6][]const u8, count: *usize, s: []const u8) void {
            if (count.* >= list.len) return;
            list[count.*] = s;
            count.* += 1;
        }
    }.push;

    if (std.mem.indexOf(u8, fs_scope, "workspace") != null and
        (std.mem.indexOf(u8, fs_scope, "RW") != null or std.mem.indexOf(u8, fs_scope, "write") != null))
        add(&parts, &n, "workspace write");
    if (std.mem.indexOf(u8, fs_scope, "system RO") != null or std.mem.indexOf(u8, fs_scope, "system read") != null)
        add(&parts, &n, "system read-only");
    if (std.mem.indexOf(u8, fs_scope, "host-config") != null)
        add(&parts, &n, "agent config narrow");
    if (std.mem.indexOf(u8, fs_scope, "no bare home") != null or std.mem.indexOf(u8, fs_scope, "no home") != null)
        add(&parts, &n, "home locked");
    if (std.mem.indexOf(u8, fs_scope, "env secret") != null)
        add(&parts, &n, "env secrets blocked");
    if (std.mem.indexOf(u8, fs_scope, "platform tmp") != null)
        add(&parts, &n, "tmp allowed");

    if (n == 0) {
        // Unknown shape: keep raw, truncated to buffer.
        if (fs_scope.len <= buf.len) {
            @memcpy(buf[0..fs_scope.len], fs_scope);
            return buf[0..fs_scope.len];
        }
        const keep = buf.len;
        if (keep == 0) return "";
        if (keep <= 3) {
            const take = @min(keep, fs_scope.len);
            @memcpy(buf[0..take], fs_scope[0..take]);
            return buf[0..take];
        }
        @memcpy(buf[0 .. keep - 3], fs_scope[0 .. keep - 3]);
        @memcpy(buf[keep - 3 .. keep], "...");
        return buf[0..keep];
    }

    var out: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) out.writeAll(" · ") catch break;
        out.writeAll(parts[i]) catch break;
    }
    return out.buffered();
}

fn secretsLabel(with_host_secrets: bool, secretless: bool) []const u8 {
    if (with_host_secrets) return "host secrets retained (escape)";
    if (secretless) return "stripped · agent logins kept";
    return "launch allowlist · secrets stripped";
}

fn profileLabel(grade: ?[]const u8) []const u8 {
    return grade orelse "default";
}

/// Render the memorable shield card + dim machine receipt footer.
pub fn render(io: std.Io, stdout: anytype, input: CardInput) !void {
    const look = lookFor(input.posture);
    const a = theme.active(io, stdout);
    const use_unicode = a.supportsUnicode();

    // Box geometry (double-line when unicode — more memorable "armor" feel).
    const tl: []const u8 = if (use_unicode) "╔" else "+";
    const tr: []const u8 = if (use_unicode) "╗" else "+";
    const bl: []const u8 = if (use_unicode) "╚" else "+";
    const br: []const u8 = if (use_unicode) "╝" else "+";
    const h: []const u8 = if (use_unicode) "═" else "=";
    const v: []const u8 = if (use_unicode) "║" else "|";

    var fs_buf: [160]u8 = undefined;
    const files_human = humanizeFsScope(&fs_buf, input.fs_scope);

    // Build body lines into fixed storage (no allocator).
    // Live rows use a filled bullet when active; hollow otherwise.
    const bullet: []const u8 = if (input.posture == .active)
        (if (use_unicode) "●" else "*")
    else
        (if (use_unicode) "○" else "o");

    var line_files: [112]u8 = undefined;
    const files_line = std.fmt.bufPrint(&line_files, "  {s} Files     {s}", .{ bullet, files_human }) catch "  * Files     (see receipt)";

    var line_net: [112]u8 = undefined;
    const net_line = std.fmt.bufPrint(&line_net, "  {s} Network   {s}", .{ bullet, input.network_scope }) catch "  * Network   (see receipt)";

    var line_sec: [112]u8 = undefined;
    const sec_line = std.fmt.bufPrint(&line_sec, "  {s} Secrets   {s}", .{ bullet, secretsLabel(input.with_host_secrets, input.secretless) }) catch "  * Secrets   (see receipt)";

    var line_grade: [80]u8 = undefined;
    const grade_line = std.fmt.bufPrint(&line_grade, "  {s} Profile   {s}", .{ bullet, profileLabel(input.seatbelt_profile) }) catch "  * Profile   default";

    var line_footer: [128]u8 = undefined;
    const footer_line = std.fmt.bufPrint(
        &line_footer,
        "  {s} · gateway {s} · escape {s} · network {s}",
        .{
            if (input.secretless) "boundary on" else "boundary off",
            input.gateway_label,
            if (input.with_host_secrets) "host-secrets" else "none",
            input.network_mode,
        },
    ) catch "  (see receipt)";

    // Title row: shield + SHIELD UP (and greppable OS sandbox status inside card).
    const status_word: []const u8 = switch (input.posture) {
        .active => "active",
        .prepared => "prepared",
        .unavailable => "unavailable",
        .failed => "failed",
        .disabled => "disabled",
    };
    var title_buf: [48]u8 = undefined;
    const title_plain = std.fmt.bufPrint(&title_buf, "  🛡  {s}", .{look.title}) catch look.title;

    var status_buf: [40]u8 = undefined;
    // Greppable: "OS sandbox: active" (and siblings) live in the card header area.
    const status_plain = std.fmt.bufPrint(&status_buf, "  OS sandbox: {s}", .{status_word}) catch "  OS sandbox:";

    const body = [_][]const u8{
        title_plain,
        status_plain,
        "",
        look.tagline,
        "",
        files_line,
        net_line,
        sec_line,
        grade_line,
        "",
        footer_line,
    };

    // Interior width from widest body line + padding.
    var content_width: usize = 0;
    for (body) |line| {
        const w = tui_render.displayWidth(line);
        if (w > content_width) content_width = w;
    }
    // Floor so short states still look like a solid card.
    if (content_width < 48) content_width = 48;
    const inner = content_width + 2; // side padding

    try stdout.writeAll("\n");

    // Top border
    try theme.paint(io, stdout, look.token, tl);
    {
        var i: usize = 0;
        while (i < inner) : (i += 1) try theme.paint(io, stdout, look.token, h);
    }
    try theme.paint(io, stdout, look.token, tr);
    try stdout.writeAll("\n");

    for (body) |line| {
        try theme.paint(io, stdout, look.token, v);
        try stdout.writeAll(" ");
        // Emphasize title / status; mute blank and footer; normal for rows.
        if (std.mem.startsWith(u8, line, "  🛡")) {
            try theme.paintBold(io, stdout, look.token, line);
        } else if (std.mem.startsWith(u8, line, "  OS sandbox:")) {
            try theme.paintBold(io, stdout, .text_bright, line);
        } else if (line.len == 0) {
            // empty interior
        } else if (std.mem.eql(u8, line, look.tagline)) {
            try theme.paint(io, stdout, .muted, line);
        } else if (std.mem.indexOf(u8, line, "Files") != null or
            std.mem.indexOf(u8, line, "Network") != null or
            std.mem.indexOf(u8, line, "Secrets") != null or
            std.mem.indexOf(u8, line, "Profile") != null)
        {
            // Instrument rows: success when live, muted when not.
            const row_token: theme.Token = if (input.posture == .active) .success else .text;
            try theme.paint(io, stdout, row_token, line);
        } else {
            try theme.paint(io, stdout, .muted, line);
        }
        const lw = tui_render.displayWidth(line);
        var pad: usize = lw;
        while (pad < content_width) : (pad += 1) try stdout.writeAll(" ");
        try stdout.writeAll(" ");
        try theme.paint(io, stdout, look.token, v);
        try stdout.writeAll("\n");
    }

    // Bottom border
    try theme.paint(io, stdout, look.token, bl);
    {
        var i: usize = 0;
        while (i < inner) : (i += 1) try theme.paint(io, stdout, look.token, h);
    }
    try theme.paint(io, stdout, look.token, br);
    try stdout.writeAll("\n");

    // Dim machine receipt: preserves exact greppable tokens for scripts/tests.
    try stdout.writeAll("\n");
    try theme.paint(io, stdout, .muted, "  receipt");
    try stdout.writeAll("\n");
    // posture line may include trailing newline when from formatSessionPostureLine.
    if (input.machine_posture_line.len > 0) {
        const posture_trimmed = std.mem.trim(u8, input.machine_posture_line, "\r\n");
        try stdout.writeAll("  ");
        try theme.paint(io, stdout, .muted, posture_trimmed);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("  ");
    try theme.paint(io, stdout, .muted, input.machine_os_line);
    try stdout.writeAll("\n");

    // Optional grade token on its own when present (some greps look for key=value).
    if (input.seatbelt_profile) |grade| {
        var token_buf: [48]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "seatbelt_profile={s}", .{grade}) catch null;
        if (token) |t| {
            // Only emit standalone if not already in the machine OS line.
            if (std.mem.indexOf(u8, input.machine_os_line, t) == null) {
                try stdout.writeAll("  ");
                try theme.paint(io, stdout, .muted, t);
                try stdout.writeAll("\n");
            }
        }
    }

    try stdout.writeAll("\n");
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

test "humanizeFsScope: common active macOS tokens" {
    var buf: [160]u8 = undefined;
    const raw =
        \\workspace RW (env secret forms denied), system RO, narrow host-config RW, no bare home, control write-deny (readable), mach-lookup residual
    ;
    const human = humanizeFsScope(&buf, raw);
    try std.testing.expect(std.mem.indexOf(u8, human, "workspace write") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "system read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "agent config narrow") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "home locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "env secrets blocked") != null);
}

test "humanizeFsScope: none and empty" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("none", humanizeFsScope(&buf, "none"));
    try std.testing.expectEqualStrings("none", humanizeFsScope(&buf, ""));
}

test "render active card: greppable tokens + SHIELD UP" {
    var out_buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    try render(std.testing.io, &writer, .{
        .posture = .active,
        .fs_scope = "workspace RW, system RO, no home",
        .network_scope = "unrestricted",
        .seatbelt_profile = "hardened",
        .secretless = true,
        .with_host_secrets = false,
        .network_mode = "ask",
        .gateway_label = "off",
        .machine_posture_line = "Posture: secret-boundary=on sandbox=active gateway=off escape=none network=ask\n",
        .machine_os_line = "OS sandbox: active (filesystem: workspace RW, system RO, no home; network: unrestricted; seatbelt_profile=hardened; credentials: launch-allowlist (secrets stripped; agent sockets/certs may remain); tools: wrapper-mediated)",
    });
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "SHIELD UP") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OS sandbox: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "seatbelt_profile=hardened") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret-boundary=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sandbox=active") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "network: unrestricted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "workspace write") != null);
    // Mechanism names stay out of the human surface (S-GLO-03).
    try std.testing.expect(std.mem.indexOf(u8, out, "Seatbelt") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Landlock") == null);
}

test "render disabled card: SHIELD OFF" {
    var out_buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    try render(std.testing.io, &writer, .{
        .posture = .disabled,
        .fs_scope = "none",
        .network_scope = "unrestricted",
        .seatbelt_profile = null,
        .secretless = false,
        .with_host_secrets = false,
        .network_mode = "ask",
        .gateway_label = "off",
        .machine_posture_line = "Posture: secret-boundary=off sandbox=disabled gateway=off escape=none network=ask\n",
        .machine_os_line = "OS sandbox: disabled",
    });
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "SHIELD OFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OS sandbox: disabled") != null);
}

test "PostureKind.parse maps tags" {
    try std.testing.expectEqual(PostureKind.active, PostureKind.parse("active"));
    try std.testing.expectEqual(PostureKind.disabled, PostureKind.parse("disabled"));
    try std.testing.expectEqual(PostureKind.disabled, PostureKind.parse("unknown"));
}

test "shouldHold: active on interactive TTY only" {
    try std.testing.expect(shouldHold(.active, true, false, false));
    try std.testing.expect(shouldHold(.prepared, true, false, false));
    try std.testing.expect(shouldHold(.unavailable, true, false, false));
    try std.testing.expect(shouldHold(.failed, true, false, false));
    try std.testing.expect(!shouldHold(.disabled, true, false, false));
    try std.testing.expect(!shouldHold(.active, false, false, false)); // pipe
    try std.testing.expect(!shouldHold(.active, true, true, false)); // TERM=dumb
    try std.testing.expect(!shouldHold(.active, true, false, true)); // hold disabled
}

test "holdIfNeeded is a no-op under tests even when shouldHold would be true" {
    // Must not sleep 2s in the unit suite.
    holdIfNeeded(std.testing.io, .active, true, false, false);
}
