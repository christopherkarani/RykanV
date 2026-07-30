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
        .ryk => std.fmt.bufPrint(buf, "Next: ryk replay --session {s}", .{shortId(session_id)}) catch "Next: ryk replay",
        .codex => "Next: open the Codex session file (path below) if you need context",
        .claude => "Next: open the Claude Code transcript (path below) if you need context",
        .grok => "Next: open the Grok session chat_history (path below) if you need context",
        .pi => "Next: open the Pi session.jsonl (path below) if you need context",
        .opencode => "Next: open the OpenCode session in the OpenCode app if you need full context",
    };
}

/// Prefer a short trailing id for long session names.
pub fn shortId(id: []const u8) []const u8 {
    if (id.len <= 28) return id;
    // Prefer last 20 chars (often the UUID tail).
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
