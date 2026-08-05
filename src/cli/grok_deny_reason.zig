//! Grok PreToolUse deny JSON `reason` text: smart-shrink to a UTF-8 byte budget.
//!
//! Host contract: Grok TUI gray-line surfaces the decoded `reason` field. Keep it
//! scannable (≤ `max_reason_len` bytes after format → redact → re-cap). Brand is
//! never dropped; shrink order is detail → drop Recourse → truncate rule last.

const std = @import("std");

/// Decoded JSON `reason` UTF-8 **bytes** after redact + re-cap.
pub const max_reason_len: usize = 240;

const em_dash_sep = " — "; // U+2014 em dash (3 UTF-8 bytes) between rule and detail
const footer_recourse =
    ". Command did not execute. Recourse: ryk explain \"<command>\"; ryk allow-once <code>.";
const footer_plain = ". Command did not execute.";
const ellipsis = "...";

/// Truncate `text` to at most `max_bytes` UTF-8 bytes on a codepoint boundary.
/// On invalid lead byte, stop before it. Does not allocate.
pub fn truncateUtf8Bytes(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    if (max_bytes == 0) return text[0..0];
    var i: usize = 0;
    while (i < max_bytes and i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + seq_len > max_bytes) break;
        if (i + seq_len > text.len) break;
        i += seq_len;
    }
    return text[0..i];
}

/// Blind re-cap after redaction (which can grow). Caller owns the returned slice.
pub fn recapAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_reason_len) return try allocator.dupe(u8, text);
    return try allocator.dupe(u8, truncateUtf8Bytes(text, max_reason_len));
}

fn firstLineTrimmed(text: []const u8) []const u8 {
    var end = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| end = @min(end, nl);
    if (std.mem.indexOfScalar(u8, text, '\r')) |cr| end = @min(end, cr);
    const line = text[0..end];
    return std.mem.trimEnd(u8, std.mem.trim(u8, line, " \t\r\n"), ".");
}

/// Prefer a substantive first line: message often has pack prose; reason can be terse.
fn pickDetail(message: []const u8, reason: []const u8) []const u8 {
    const msg = firstLineTrimmed(message);
    const why = firstLineTrimmed(reason);
    if (msg.len > why.len + 8) return msg;
    if (why.len > 0) return why;
    if (msg.len > 0) return msg;
    return "blocked by policy";
}

fn stripLeadingBrand(detail: []const u8, brand: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, detail, brand)) return detail;
    return std.mem.trimStart(u8, detail[brand.len..], ": \t");
}

fn fixedOverhead(brand: []const u8, include_brand: bool, rule: ?[]const u8, footer: []const u8) usize {
    var n: usize = footer.len;
    if (include_brand) n += brand.len + 2; // "TAG: "
    if (rule) |r| n += r.len + em_dash_sep.len;
    return n;
}

/// Fit `detail` into `budget` bytes, appending `...` when truncated. Caller frees `owned` if non-null.
fn fitDetail(allocator: std.mem.Allocator, detail: []const u8, budget: usize) !struct { text: []const u8, owned: ?[]u8 } {
    if (detail.len <= budget) return .{ .text = detail, .owned = null };
    if (budget == 0) return .{ .text = detail[0..0], .owned = null };
    if (budget <= ellipsis.len) {
        const cut = truncateUtf8Bytes(detail, budget);
        const owned = try allocator.dupe(u8, cut);
        return .{ .text = owned, .owned = owned };
    }
    const body = truncateUtf8Bytes(detail, budget - ellipsis.len);
    const owned = try std.fmt.allocPrint(allocator, "{s}{s}", .{ body, ellipsis });
    return .{ .text = owned, .owned = owned };
}

fn assemble(
    allocator: std.mem.Allocator,
    brand: []const u8,
    include_brand: bool,
    rule: ?[]const u8,
    detail: []const u8,
    footer: []const u8,
) ![]u8 {
    if (include_brand) {
        if (rule) |r| {
            return std.fmt.allocPrint(
                allocator,
                "{s}: {s}{s}{s}{s}",
                .{ brand, r, em_dash_sep, detail, footer },
            );
        }
        return std.fmt.allocPrint(allocator, "{s}: {s}{s}", .{ brand, detail, footer });
    }
    if (rule) |r| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ r, em_dash_sep, detail, footer });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ detail, footer });
}

/// Compact reason string Grok surfaces in the TUI and feeds back to the model.
/// Smart-shrink toward ≤ `max_reason_len`: detail → drop Recourse → truncate rule.
/// Brand is never dropped. Caller still re-caps after redact via `recapAlloc`.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    brand: []const u8,
    rule_raw: ?[]const u8,
    message: []const u8,
    reason: []const u8,
) ![]u8 {
    var detail = stripLeadingBrand(pickDetail(message, reason), brand);
    const include_brand = std.mem.indexOf(u8, detail, brand) == null;

    const rule_line: ?[]const u8 = blk: {
        if (rule_raw) |r| {
            const line = firstLineTrimmed(r);
            break :blk if (line.len > 0) line else null;
        }
        break :blk null;
    };

    var owned_detail: ?[]u8 = null;
    defer if (owned_detail) |od| allocator.free(od);
    var owned_rule: ?[]u8 = null;
    defer if (owned_rule) |orule| allocator.free(orule);

    var rule = rule_line;
    var detail_use: []const u8 = detail;
    var footer: []const u8 = footer_recourse;

    // Prefer Recourse footer, then plain. First footer whose fixed overhead fits wins;
    // detail is then fitted into the remainder (with "..." when cut).
    const footers = [_][]const u8{ footer_recourse, footer_plain };
    var fitted = false;
    for (footers) |cand| {
        const overhead = fixedOverhead(brand, include_brand, rule, cand);
        if (overhead > max_reason_len) continue;
        if (owned_detail) |od| {
            allocator.free(od);
            owned_detail = null;
        }
        const budget = max_reason_len - overhead;
        const fit = try fitDetail(allocator, detail, budget);
        owned_detail = fit.owned;
        detail_use = fit.text;
        footer = cand;
        fitted = true;
        break;
    }

    if (!fitted) {
        // Brand + rule alone exceed budget even with empty detail and plain footer.
        // Truncate rule on a UTF-8 boundary; keep brand; empty detail is OK.
        detail_use = detail[0..0];
        footer = footer_plain;
        if (owned_detail) |od| {
            allocator.free(od);
            owned_detail = null;
        }
        if (rule) |r| {
            // Fixed bytes with a rule clause present: brand + ": " + sep + footer (+ empty detail).
            const base = fixedOverhead(brand, include_brand, null, footer) + em_dash_sep.len;
            if (base >= max_reason_len) {
                rule = null;
            } else {
                const rule_budget = max_reason_len - base;
                if (r.len > rule_budget) {
                    const cut = truncateUtf8Bytes(r, rule_budget);
                    owned_rule = try allocator.dupe(u8, cut);
                    rule = owned_rule.?;
                }
            }
        }
    }

    const out = try assemble(allocator, brand, include_brand, rule, detail_use, footer);
    if (out.len > max_reason_len) {
        const cut = truncateUtf8Bytes(out, max_reason_len);
        const trimmed = try allocator.dupe(u8, cut);
        allocator.free(out);
        return trimmed;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Unit tests (pure formatter; no redact / host I/O)
// ---------------------------------------------------------------------------

fn countBrand(text: []const u8, brand: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, brand)) |pos| {
        n += 1;
        i = pos + brand.len;
    }
    return n;
}

test "grok deny reason caps at max_reason_len" {
    const allocator = std.testing.allocator;
    const brand = "RYKAN-V-GUARD";
    const long = "x" ** 400;
    const out = try formatAlloc(allocator, brand, "core.filesystem:rm-rf-root-home", long, "short");
    defer allocator.free(out);
    try std.testing.expect(out.len <= max_reason_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqual(@as(usize, 1), countBrand(out, brand));
    try std.testing.expect(std.mem.indexOf(u8, out, "core.filesystem:rm-rf-root-home") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Command did not execute") != null);
}

test "grok deny reason truncates on UTF-8 boundary" {
    const allocator = std.testing.allocator;
    const brand = "RYKAN-V-GUARD";
    const unit = "世";
    var long_buf: [600]u8 = undefined;
    var filled: usize = 0;
    while (filled + unit.len <= long_buf.len) : (filled += unit.len) {
        @memcpy(long_buf[filled..][0..unit.len], unit);
    }
    const out = try formatAlloc(allocator, brand, "pack:rule", long_buf[0..filled], "why");
    defer allocator.free(out);
    try std.testing.expect(out.len <= max_reason_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqual(@as(usize, 1), countBrand(out, brand));
}

test "grok deny reason is single line and sanitizes rule newlines" {
    const allocator = std.testing.allocator;
    const brand = "RYKAN-V-GUARD";
    const out = try formatAlloc(
        allocator,
        brand,
        "core.filesystem:rm-rf-root-home\ninjected-second-line",
        "msg-line-one\nmsg-line-two with extra prose for preference",
        "line-one\nline-two\rline-three",
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\r') == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "core.filesystem:rm-rf-root-home") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "injected-second-line") == null);
    try std.testing.expect(out.len <= max_reason_len);
}

test "grok deny reason without rule stays branded under cap" {
    const allocator = std.testing.allocator;
    const brand = "RYKAN-V-GUARD";
    const long = "y" ** 500;
    const out = try formatAlloc(allocator, brand, null, "short", long);
    defer allocator.free(out);
    try std.testing.expect(out.len <= max_reason_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqual(@as(usize, 1), countBrand(out, brand));
    try std.testing.expect(std.mem.indexOf(u8, out, "Command did not execute") != null);
}

test "grok deny reason recapAlloc preserves UTF-8" {
    const allocator = std.testing.allocator;
    const unit = "世";
    var buf: [300]u8 = undefined;
    var filled: usize = 0;
    while (filled + unit.len <= buf.len) : (filled += unit.len) {
        @memcpy(buf[filled..][0..unit.len], unit);
    }
    const out = try recapAlloc(allocator, buf[0..filled]);
    defer allocator.free(out);
    try std.testing.expect(out.len <= max_reason_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}
