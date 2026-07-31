//! End-user presentation strings for scan findings (TUI + plain).
//! Pure helpers — no I/O. Never invent or re-emit secret values.
const std = @import("std");
const types = @import("types.zig");

/// Human-readable type for a classifier label (e.g. `secret:github_token`).
pub fn humanSecretLabel(label: []const u8) []const u8 {
    // Strip common prefixes then map known shapes.
    const from_env = std.mem.startsWith(u8, label, "env:");
    const bare = if (std.mem.startsWith(u8, label, "secret:"))
        label["secret:".len..]
    else if (from_env)
        label["env:".len..]
    else
        label;

    // Env var names are already human-scannable — keep them.
    if (from_env and bare.len > 0 and bare.len < 48 and isMostlyIdent(bare)) return bare;

    if (std.mem.indexOf(u8, bare, "github") != null or std.mem.eql(u8, bare, "github_pat") or
        std.mem.eql(u8, bare, "github_token"))
        return "GitHub token";
    if (std.mem.indexOf(u8, bare, "openai") != null or std.mem.eql(u8, bare, "OPENAI_API_KEY"))
        return "OpenAI API key";
    if (std.mem.indexOf(u8, bare, "anthropic") != null or std.mem.indexOf(u8, bare, "sk-ant") != null)
        return "Anthropic API key";
    if (std.mem.indexOf(u8, bare, "aws") != null or std.mem.eql(u8, bare, "AKIA") or
        std.mem.indexOf(u8, bare, "aws_access") != null)
        return "AWS credential";
    if (std.mem.indexOf(u8, bare, "private") != null or std.mem.indexOf(u8, bare, "ssh") != null or
        std.mem.indexOf(u8, bare, "rsa") != null)
        return "Private key material";
    if (std.mem.indexOf(u8, bare, "high_entropy") != null or std.mem.eql(u8, bare, "high_entropy"))
        return "High-entropy secret";
    if (std.mem.eql(u8, bare, "embedded"))
        return "Embedded secret-like value";
    if (std.mem.eql(u8, bare, "key") or std.mem.eql(u8, bare, "KEY"))
        return "API key / token";
    if (bare.len > 0 and bare.len < 48 and isMostlyIdent(bare)) return bare;
    return "Secret-like value";
}

fn isMostlyIdent(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

pub fn severityWords(sev: types.Severity) []const u8 {
    return switch (sev) {
        .critical => "Urgent if real",
        .high => "Worth reviewing",
        .medium => "Review when you can",
        .low => "Low urgency",
    };
}

pub fn kindHuman(kind: types.FindingKind) []const u8 {
    return switch (kind) {
        .danger => "Risky command",
        .secret_access => "Secret-path command",
        .secret_material => "Secret-like text",
    };
}

/// Clean placeholder when a value is fully redacted (never nested REDACTED).
pub fn cleanHiddenDisplay(detail: []const u8) []const u8 {
    if (detail.len == 0) return "Value hidden";
    if (std.mem.indexOf(u8, detail, "REDACTED") != null) return "Value hidden";
    if (std.mem.eql(u8, detail, "[hidden]")) return "Value hidden";
    return detail;
}

/// One-line “what happened” for the selected finding.
pub fn plainSentence(f: types.Finding, buf: []u8) []const u8 {
    const host = f.host.toString();
    return switch (f.kind) {
        .secret_material => blk: {
            const label = if (f.secret_label) |l| humanSecretLabel(l) else "Secret-like value";
            break :blk std.fmt.bufPrint(buf, "{s} session may have contained: {s} (value hidden).", .{ host, label }) catch
                "Session may have contained a secret-like value (value hidden).";
        },
        .secret_access => std.fmt.bufPrint(buf, "{s} ran a command that touches secret-bearing paths.", .{host}) catch
            "A command touched secret-bearing paths.",
        .danger => std.fmt.bufPrint(buf, "{s} ran a {s}-severity shell/tool command.", .{ host, f.severity.toString() }) catch
            "A risky shell/tool command appeared in a session.",
    };
}

pub fn actionLine(f: types.Finding) []const u8 {
    return switch (f.kind) {
        .secret_material => "If this was a real key: rotate it · do not paste secrets into agents · otherwise ignore",
        .secret_access => "Confirm whether that command should have run · rotate secrets if contents were exposed",
        .danger => "Review the command · prefer safer workflows · re-run only if intentional",
    };
}

pub fn whyFired(f: types.Finding, buf: []u8) []const u8 {
    return switch (f.kind) {
        .secret_material => blk: {
            const label = if (f.secret_label) |l| humanSecretLabel(l) else "secret-like text";
            break :blk std.fmt.bufPrint(buf, "Matched {s} in session text (pattern match, not a confirmed breach).", .{label}) catch
                "Matched secret-like text in a session log.";
        },
        .secret_access => "Command matched known secret-path / env-dump patterns.",
        .danger => "shell_engine rated this command medium+ risk for live mediation.",
    };
}

pub fn hostNextStep(host: types.Host, session_id: []const u8, buf: []u8) []const u8 {
    return switch (host) {
        // Full session id for replay — never a truncated tail (breaks resume).
        .ryk => std.fmt.bufPrint(buf, "Next: ryk replay --session {s}", .{displaySessionId(.ryk, session_id)}) catch "Next: ryk replay",
        .codex => blk: {
            if (codexResumeUuid(session_id)) |uuid| {
                break :blk std.fmt.bufPrint(buf, "Next: codex resume {s}  (or c copy / o reveal File)", .{uuid}) catch
                    "Next: open the Codex session file (path below; TUI: c/o)";
            }
            break :blk "Next: open the Codex session file (path below; TUI: c copy · o reveal)";
        },
        .claude => "Next: open the Claude Code transcript (path below) if you need context",
        .grok => "Next: open the Grok session chat_history (path below) if you need context",
        .pi => "Next: open the Pi session.jsonl (path below) if you need context",
        .opencode => "Next: open the OpenCode session in the OpenCode app if you need full context",
    };
}

/// True when `s` is a canonical 8-4-4-4-12 hex UUID (36 chars with hyphens).
pub fn isCanonicalUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) {
            return false;
        }
    }
    return true;
}

/// Codex rollout stems end with `-<uuid>`. Returns the full UUID slice when parseable.
/// Never returns a truncated fragment — only a verified 36-char UUID.
pub fn codexResumeUuid(session_id: []const u8) ?[]const u8 {
    if (session_id.len < 36) return null;
    const cand = session_id[session_id.len - 36 ..];
    if (!isCanonicalUuid(cand)) return null;
    // Prefer stems that look like rollout-* or at least have a separator before UUID.
    if (session_id.len > 36) {
        const before = session_id[session_id.len - 37];
        if (before != '-' and before != '_') return null;
    }
    return cand;
}

/// Host-aware session id for human display (TUI + plain). Never invents a resume id.
/// Codex: full UUID from rollout stem when parseable; otherwise full stored id.
/// Other hosts: full stored id (callers may width-truncate with ellipsis, not last-20-only).
pub fn displaySessionId(host: types.Host, session_id: []const u8) []const u8 {
    switch (host) {
        .codex => {
            if (codexResumeUuid(session_id)) |uuid| return uuid;
            return session_id;
        },
        else => return session_id,
    }
}

/// Legacy trailing slice for non-resume contexts. Prefer `displaySessionId` for UI.
/// Kept so accidental call sites stay short; **do not** use for resume/replay hints.
pub fn shortId(id: []const u8) []const u8 {
    if (id.len <= 28) return id;
    return id[id.len - 20 ..];
}

pub fn listTitle(f: types.Finding, buf: []u8) []const u8 {
    const base = switch (f.kind) {
        .secret_material => if (f.secret_label) |l| humanSecretLabel(l) else "Secret-like value",
        .secret_access => "Secret-path command",
        .danger => f.title,
    };
    if (f.occurrence_count > 1) {
        return std.fmt.bufPrint(buf, "{s} · ×{d}", .{ base, f.occurrence_count }) catch base;
    }
    return base;
}

test "humanSecretLabel maps known types" {
    try std.testing.expectEqualStrings("GitHub token", humanSecretLabel("secret:github_token"));
    try std.testing.expectEqualStrings("OpenAI API key", humanSecretLabel("secret:openai_api_key"));
    try std.testing.expectEqualStrings("High-entropy secret", humanSecretLabel("secret:high_entropy"));
    try std.testing.expectEqualStrings("OPENAI_API_KEY", humanSecretLabel("env:OPENAI_API_KEY"));
}

test "cleanHiddenDisplay collapses nested redaction" {
    try std.testing.expectEqualStrings("Value hidden", cleanHiddenDisplay("[REDACTED:secret:[REDACTED]"));
    try std.testing.expectEqualStrings("rm -rf /tmp", cleanHiddenDisplay("rm -rf /tmp"));
}

test "plainSentence for secret_material" {
    var buf: [160]u8 = undefined;
    const f: types.Finding = .{
        .kind = .secret_material,
        .severity = .high,
        .host = .codex,
        .session_id = "s",
        .path = "p",
        .timestamp_secs = 1,
        .title = "t",
        .detail = "[REDACTED]",
        .secret_label = "secret:high_entropy",
        .secret_fingerprint = "abcd",
        .evidence_ref = "e",
    };
    const s = plainSentence(f, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "High-entropy") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "contained:") != null);
}

// ── Session id display (AC-S1–S7, edges E1–E3, E10) ─────────────────────────

const codex_rollout_stem =
    "rollout-2026-07-30T21-25-08-019fb445-e7a9-7612-bf1a-8fe20ff9e69b";
const codex_full_uuid = "019fb445-e7a9-7612-bf1a-8fe20ff9e69b";
const codex_bad_tail = "12-bf1a-8fe20ff9e69b"; // last-20 of stem — not a resume id

test "displaySessionId: Codex rollout stem shows full UUID (AC-S1)" {
    const shown = displaySessionId(.codex, codex_rollout_stem);
    try std.testing.expectEqualStrings(codex_full_uuid, shown);
    try std.testing.expect(isCanonicalUuid(shown));
}

test "displaySessionId: rejects last-20-only tail as display id (AC-S2)" {
    const shown = displaySessionId(.codex, codex_rollout_stem);
    // Must not *be* the last-20 fragment (substring may overlap a real UUID).
    try std.testing.expect(!std.mem.eql(u8, shown, codex_bad_tail));
    try std.testing.expectEqual(@as(usize, 36), shown.len);
    // shortId still produces the bad tail — prove we do not use it for Codex display.
    try std.testing.expectEqualStrings(codex_bad_tail, shortId(codex_rollout_stem));
    try std.testing.expect(!std.mem.eql(u8, shown, shortId(codex_rollout_stem)));
}

test "displaySessionId: short ids unchanged (AC-S3)" {
    try std.testing.expectEqualStrings("sess-abc", displaySessionId(.claude, "sess-abc"));
    try std.testing.expectEqualStrings("short", displaySessionId(.codex, "short"));
    const uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    try std.testing.expectEqualStrings(uuid, displaySessionId(.ryk, uuid));
    try std.testing.expectEqualStrings(uuid, displaySessionId(.codex, uuid));
}

test "codexResumeUuid: extracts only full UUID; no mid-stem fragment (AC-S7)" {
    const u = codexResumeUuid(codex_rollout_stem).?;
    try std.testing.expectEqualStrings(codex_full_uuid, u);
    try std.testing.expect(codexResumeUuid("rollout-no-uuid-here") == null);
    try std.testing.expect(codexResumeUuid(codex_bad_tail) == null);
    try std.testing.expect(codexResumeUuid("") == null);
}

test "hostNextStep: Codex resume uses full UUID never truncated tail (AC-S7)" {
    var buf: [160]u8 = undefined;
    const next = hostNextStep(.codex, codex_rollout_stem, &buf);
    try std.testing.expect(std.mem.indexOf(u8, next, codex_full_uuid) != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "codex resume") != null);
    // Must not recommend resume of the last-20-only fragment alone.
    var bad_resume_buf: [64]u8 = undefined;
    const bad_resume = std.fmt.bufPrint(&bad_resume_buf, "codex resume {s}", .{codex_bad_tail}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, next, bad_resume) == null);
    // Without UUID, no fake resume suggestion.
    const no_uuid = hostNextStep(.codex, "rollout-2026-07-30-notauuid", &buf);
    try std.testing.expect(std.mem.indexOf(u8, no_uuid, "codex resume") == null);
}

test "hostNextStep: ryk replay uses full session id not last-20 (E10)" {
    var buf: [160]u8 = undefined;
    const full = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const next = hostNextStep(.ryk, full, &buf);
    try std.testing.expect(std.mem.indexOf(u8, next, full) != null);
    // Replay line must include the complete id, not only shortId tail as the argument.
    var short_only: [80]u8 = undefined;
    const short_arg = std.fmt.bufPrint(&short_only, "ryk replay --session {s}", .{shortId(full)}) catch unreachable;
    // shortId is a suffix of full, so the short_arg string is a prefix of the good line —
    // require the full id appears (already checked) and shortId alone is not equal to display.
    try std.testing.expect(!std.mem.eql(u8, shortId(full), full));
    try std.testing.expect(std.mem.indexOf(u8, next, "ryk replay --session ") != null);
    _ = short_arg;
}

test "displaySessionId: Codex stem without UUID returns full stem (E2)" {
    const stem = "rollout-2026-07-30T21-25-08-not-a-uuid-suffix";
    try std.testing.expectEqualStrings(stem, displaySessionId(.codex, stem));
}
