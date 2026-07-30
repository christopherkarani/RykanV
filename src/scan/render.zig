//! Human and JSON renderers for scan results.
const std = @import("std");
const types = @import("types.zig");
const risk = @import("risk.zig");
const present = @import("present.zig");
const theme = @import("../tui/theme.zig");
const tui_render = @import("../tui/render.zig");
const terminal_text = @import("../tui/terminal_text.zig");

/// Linear rich human output (non-TUI path: pipes, `--plain`, colourless terminals).
pub fn writeHuman(io: std.Io, writer: anytype, result: types.ScanResult) !void {
    const sc = result.scorecard;
    const level = risk.riskLevel(sc);
    var win_buf: [32]u8 = undefined;
    const window = risk.windowLabel(sc, &win_buf);

    // Entry banner is painted by cli/mod; this is the feature scorecard block.
    try writer.writeAll("  ");
    try theme.paintBold(io, writer, .text_bright, "session scan");
    try writer.writeAll("  ·  ");
    try theme.paint(io, writer, .muted, window);
    try writer.writeAll("\n\n");

    try writer.writeAll("  ");
    try theme.paintBold(io, writer, riskToken(level), level.headline());
    try writer.writeAll("\n");
    try writer.writeAll("  ");
    try theme.paint(io, writer, .text, level.blurb());
    try writer.writeAll("\n\n");

    try writer.writeAll("  ");
    try writeMetric(io, writer, "sessions", sc.sessions_scanned, .info);
    try writer.writeAll("   ");
    try writeMetric(io, writer, "danger", sc.danger_count, if (sc.danger_count > 0) .danger else .muted);
    try writer.writeAll("   ");
    try writeMetric(io, writer, "secret access", sc.secret_access_count, if (sc.secret_access_count > 0) .warn else .muted);
    try writer.writeAll("   ");
    try writeMetric(io, writer, "secret material", sc.secret_material_count, if (sc.secret_material_count > 0) .warn else .muted);
    try writer.writeAll("\n\n");

    try theme.paintBold(io, writer, .text_bright, "  Hosts");
    try writer.writeAll("\n");
    for (sc.hosts) |h| {
        try writer.writeAll("    ");
        try theme.paint(io, writer, hostToken(h.status), h.host.toString());
        try writer.writeAll("  ");
        try theme.paint(io, writer, hostToken(h.status), risk.hostStatusGlyph(h.status));
        if (h.sessions_seen > 0) {
            try writer.print(" ({d})", .{h.sessions_seen});
        }
        if (h.note.len > 0) {
            try writer.writeAll("  ");
            try theme.paint(io, writer, .muted, h.note);
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("\n");

    if (result.total_findings == 0) {
        const kind: tui_render.CalloutKind = switch (level) {
            .clear => .success,
            .no_data => .info,
            else => .warn,
        };
        const title = if (level == .clear)
            "No risky findings in this window"
        else
            "No findings to list";
        try tui_render.callout(io, writer, kind, title, "Use an agent, then re-run ryk scan. Existing ryk users: ryk replay.");
        for (sc.hosts) |h| {
            if (h.host == .opencode and (h.status == .unsupported or h.status == .unreadable)) {
                const oc_title = if (h.status == .unreadable) "OpenCode unreadable" else "OpenCode not parsed";
                try tui_render.callout(io, writer, .warn, oc_title, if (h.note.len > 0) h.note else "OpenCode session store not available");
                break;
            }
        }
        return;
    }

    try writer.print("  Findings (showing {d} of {d}", .{ result.findings.len, result.total_findings });
    if (result.total_findings > result.findings.len) {
        try writer.writeAll("; use --all for full list");
    }
    try writer.writeAll(")\n\n");

    for (result.findings, 0..) |f, i| {
        var sentence_buf: [200]u8 = undefined;
        var why_buf: [160]u8 = undefined;
        var next_buf: [120]u8 = undefined;
        var title_buf: [96]u8 = undefined;

        try writer.print("  {d}. ", .{i + 1});
        try theme.paintBold(io, writer, severityToken(f.severity), risk.severityShort(f.severity));
        try writer.writeAll(" ");
        try theme.paint(io, writer, .text, present.kindHuman(f.kind));
        try writer.writeAll("  ");
        try theme.paint(io, writer, .info, f.host.toString());
        if (f.occurrence_count > 1) {
            try writer.print("  ×{d}", .{f.occurrence_count});
        }
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try terminal_text.write(writer, present.plainSentence(f, &sentence_buf), .single_line);
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try theme.paint(io, writer, severityToken(f.severity), present.severityWords(f.severity));
        try writer.writeAll("  ·  ");
        try theme.paint(io, writer, .muted, present.listTitle(f, &title_buf));
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try theme.paint(io, writer, .warn, "Do: ");
        try terminal_text.write(writer, present.actionLine(f), .single_line);
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try theme.paint(io, writer, .muted, "Why: ");
        try terminal_text.write(writer, present.whyFired(f, &why_buf), .single_line);
        try writer.writeAll("\n");

        if (f.secret_label) |label| {
            try writer.writeAll("     ");
            try theme.paint(io, writer, .muted, "Type: ");
            try theme.paint(io, writer, .warn, present.humanSecretLabel(label));
            if (f.secret_fingerprint) |fp| {
                try writer.writeAll("  ");
                try theme.paint(io, writer, .muted, "id=");
                try theme.paint(io, writer, .muted, fp);
            }
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("     ");
            try theme.paint(io, writer, .muted, "Cmd: ");
            try terminal_text.write(writer, present.cleanHiddenDisplay(f.detail), .single_line);
            try writer.writeAll("\n");
        }

        try writer.writeAll("     ");
        try theme.paint(io, writer, .muted, "Session: ");
        try terminal_text.write(writer, present.shortId(f.session_id), .single_line);
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try theme.paint(io, writer, .muted, "File: ");
        try terminal_text.write(writer, f.evidence_ref, .single_line);
        try writer.writeAll("\n");

        try writer.writeAll("     ");
        try theme.paint(io, writer, .info, present.hostNextStep(f.host, f.session_id, &next_buf));
        try writer.writeAll("\n\n");
    }
}

fn writeMetric(io: std.Io, writer: anytype, label: []const u8, n: usize, tok: theme.Token) !void {
    var buf: [24]u8 = undefined;
    const ns = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
    try theme.paintBold(io, writer, tok, ns);
    try writer.writeAll(" ");
    try theme.paint(io, writer, .muted, label);
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
        .empty, .not_found => .muted,
        .unreadable => .danger,
        .unsupported => .warn,
    };
}

pub fn writeJson(writer: anytype, result: types.ScanResult) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"schema_version\": 1,\n");
    try writer.writeAll("  \"command\": \"scan\",\n");
    if (result.scorecard.all_time) {
        try writer.writeAll("  \"window\": {\"all_time\": true},\n");
    } else if (result.scorecard.window_days) |d| {
        try writer.print("  \"window\": {{\"days\": {d}}},\n", .{d});
    } else {
        try writer.writeAll("  \"window\": {},\n");
    }
    try writer.print(
        "  \"scorecard\": {{\"sessions_scanned\": {d}, \"danger\": {d}, \"secret_access\": {d}, \"secret_material\": {d}, \"total_findings\": {d}, \"shown\": {d}}},\n",
        .{
            result.scorecard.sessions_scanned,
            result.scorecard.danger_count,
            result.scorecard.secret_access_count,
            result.scorecard.secret_material_count,
            result.total_findings,
            result.findings.len,
        },
    );

    try writer.writeAll("  \"hosts\": [\n");
    for (result.scorecard.hosts, 0..) |h, i| {
        try writer.writeAll("    {");
        try writer.print("\"host\": \"{s}\", \"status\": \"{s}\", \"sessions_seen\": {d}, \"note\": ", .{
            h.host.toString(),
            h.status.toString(),
            h.sessions_seen,
        });
        try writeJsonString(writer, h.note);
        try writer.writeAll("}");
        if (i + 1 < result.scorecard.hosts.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ],\n");

    try writer.writeAll("  \"findings\": [\n");
    for (result.findings, 0..) |f, i| {
        try writer.writeAll("    {\n");
        try writer.print("      \"kind\": \"{s}\",\n", .{f.kind.toString()});
        try writer.print("      \"severity\": \"{s}\",\n", .{f.severity.toString()});
        try writer.print("      \"host\": \"{s}\",\n", .{f.host.toString()});
        try writer.writeAll("      \"session_id\": ");
        try writeJsonString(writer, f.session_id);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"title\": ");
        try writeJsonString(writer, f.title);
        try writer.writeAll(",\n");
        try writer.writeAll("      \"detail\": ");
        try writeJsonString(writer, f.detail);
        try writer.writeAll(",\n");
        if (f.secret_label) |label| {
            try writer.writeAll("      \"secret_label\": ");
            try writeJsonString(writer, label);
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("      \"secret_label\": null,\n");
        }
        if (f.secret_fingerprint) |fp| {
            try writer.writeAll("      \"secret_fingerprint\": ");
            try writeJsonString(writer, fp);
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("      \"secret_fingerprint\": null,\n");
        }
        try writer.writeAll("      \"evidence_ref\": ");
        try writeJsonString(writer, f.evidence_ref);
        try writer.writeAll(",\n");
        try writer.print("      \"timestamp_secs\": {d}\n", .{f.timestamp_secs});
        try writer.writeAll("    }");
        if (i + 1 < result.findings.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "json render has kind severity host and no raw secret" {
    var findings = try std.testing.allocator.alloc(types.Finding, 1);
    findings[0] = .{
        .kind = .secret_material,
        .severity = .high,
        .host = .claude,
        .session_id = try std.testing.allocator.dupe(u8, "s1"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/x"),
        .timestamp_secs = 100,
        .title = try std.testing.allocator.dupe(u8, "Secret material"),
        .detail = try std.testing.allocator.dupe(u8, "[REDACTED:secret:github_pat:sha256:deadbeef]"),
        .secret_label = try std.testing.allocator.dupe(u8, "secret:github_pat"),
        .secret_fingerprint = try std.testing.allocator.dupe(u8, "deadbeef"),
        .evidence_ref = try std.testing.allocator.dupe(u8, "/tmp/x"),
    };
    var result: types.ScanResult = .{
        .scorecard = .{
            .window_days = 30,
            .all_time = false,
            .sessions_scanned = 1,
            .secret_material_count = 1,
        },
        .findings = findings,
        .total_findings = 1,
        .shown_cap = 20,
        .allocator = std.testing.allocator,
    };
    defer result.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, result);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\": \"secret_material\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"severity\": \"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"host\": \"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ghp_") == null);
}

test "human render guided empty for no sessions" {
    theme.resetCache();
    var result: types.ScanResult = .{
        .scorecard = .{
            .window_days = 30,
            .all_time = false,
            .sessions_scanned = 0,
        },
        .findings = &.{},
        .total_findings = 0,
        .shown_cap = 20,
        .allocator = std.testing.allocator,
    };
    result.scorecard.setHost(.opencode, .unsupported, 0, "sqlite3 CLI not available; OpenCode DB not parsed");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeHuman(std.testing.io, &aw.writer, result);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Nothing to scan yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "session scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OpenCode") != null);
}

test "human render risk headline for danger findings" {
    theme.resetCache();
    var findings = try std.testing.allocator.alloc(types.Finding, 1);
    findings[0] = .{
        .kind = .danger,
        .severity = .high,
        .host = .claude,
        .session_id = try std.testing.allocator.dupe(u8, "s1"),
        .path = try std.testing.allocator.dupe(u8, "/p"),
        .timestamp_secs = 1,
        .title = try std.testing.allocator.dupe(u8, "Dangerous command (high)"),
        .detail = try std.testing.allocator.dupe(u8, "curl | sh"),
        .evidence_ref = try std.testing.allocator.dupe(u8, "/p"),
    };
    var result: types.ScanResult = .{
        .scorecard = .{
            .window_days = 7,
            .all_time = false,
            .sessions_scanned = 2,
            .danger_count = 1,
        },
        .findings = findings,
        .total_findings = 1,
        .shown_cap = 20,
        .allocator = std.testing.allocator,
    };
    defer result.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeHuman(std.testing.io, &aw.writer, result);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Attention needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "HIGH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Risky command") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Do:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Worth reviewing") != null or std.mem.indexOf(u8, out, "Urgent") != null);
}
