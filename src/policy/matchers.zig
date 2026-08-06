const std = @import("std");

pub fn matchesPattern(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, value)) return true;
    return globMatch(pattern, value);
}

pub fn matchesPath(pattern: []const u8, path: []const u8) bool {
    if (matchesPattern(pattern, path)) return true;

    // Quick-install DX robustness for .git/.ryk (and future user rules).
    // Try combinations of original + stripped forms for both pattern and value.
    // This ensures "./.git/**" matches ".git/config" (and vice-versa) even
    // without dual patterns in every policy.
    const stripped_pattern = stripLeadingDotSlash(pattern);
    const stripped_path = stripLeadingDotSlash(path);

    if (stripped_pattern.ptr != pattern.ptr and matchesPattern(stripped_pattern, path)) return true;
    if (stripped_path.ptr != path.ptr and matchesPattern(pattern, stripped_path)) return true;
    if (stripped_pattern.ptr != pattern.ptr and stripped_path.ptr != path.ptr and matchesPattern(stripped_pattern, stripped_path)) return true;

    if (std.mem.startsWith(u8, pattern, "~/") and std.mem.startsWith(u8, path, "~/")) {
        return globMatch(pattern, path);
    }
    if (std.mem.startsWith(u8, pattern, "~/")) {
        const home_c = std.c.getenv("HOME") orelse return false;
        const home = std.mem.sliceTo(home_c, 0);
        if (std.mem.startsWith(u8, path, home)) {
            const suffix = path[home.len..];
            if (suffix.len == 0) return globMatch(pattern, "~");
            if (std.mem.startsWith(u8, suffix, "/")) {
                var stack_buf: [4096]u8 = undefined;
                if (suffix.len + 1 <= stack_buf.len) {
                    stack_buf[0] = '~';
                    @memcpy(stack_buf[1 .. suffix.len + 1], suffix);
                    return globMatch(pattern, stack_buf[0 .. suffix.len + 1]);
                }
            }
        }
    }
    return false;
}

pub fn matchesCommand(pattern: []const u8, command: []const u8) bool {
    return matchesPattern(pattern, command);
}

pub fn matchesDomain(pattern: []const u8, host: []const u8) bool {
    const normalized_pattern = trimTrailingDot(pattern);
    const normalized_host = trimTrailingDot(host);
    if (std.ascii.eqlIgnoreCase(normalized_pattern, normalized_host)) return true;
    if (std.mem.startsWith(u8, normalized_pattern, "*.")) {
        const suffix = normalized_pattern[1..];
        return normalized_host.len > suffix.len and
            std.ascii.endsWithIgnoreCase(normalized_host, suffix);
    }
    return globMatchAsciiCaseInsensitive(normalized_pattern, normalized_host);
}

pub fn matchesMcpSelector(pattern: []const u8, selector: []const u8) bool {
    return matchesPattern(pattern, selector);
}

fn trimTrailingDot(value: []const u8) []const u8 {
    if (value.len > 0 and value[value.len - 1] == '.') return value[0 .. value.len - 1];
    return value;
}

/// Strip optional leading "./" or ".\" (Windows) for robust matching of
/// workspace-relative paths. This fixes the quick-install DX fragility where
/// hook/plugin callers (Hermes, OpenClaw, raw CLI) pass bare ".git/..." forms
/// while policy rules use "./.git/**".
pub fn stripLeadingDotSlash(p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, "./")) return p[2..];
    if (std.mem.startsWith(u8, p, ".\\")) return p[2..];
    return p;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    return globMatchAt(pattern, 0, value, 0);
}

fn globMatchAt(pattern: []const u8, pattern_index: usize, value: []const u8, value_index: usize) bool {
    var p = pattern_index;
    var v = value_index;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                while (p + 1 < pattern.len and pattern[p + 1] == '*') p += 1;
                if (p + 1 == pattern.len) return true;
                var next = v;
                while (next <= value.len) : (next += 1) {
                    if (globMatchAt(pattern, p + 1, value, next)) return true;
                }
                return false;
            },
            '?' => {
                if (v >= value.len) return false;
                p += 1;
                v += 1;
            },
            else => |char| {
                if (v >= value.len or value[v] != char) return false;
                p += 1;
                v += 1;
            },
        }
    }
    return v == value.len;
}

fn globMatchAsciiCaseInsensitive(pattern: []const u8, value: []const u8) bool {
    return globMatchAsciiCaseInsensitiveAt(pattern, 0, value, 0);
}

fn globMatchAsciiCaseInsensitiveAt(pattern: []const u8, pattern_index: usize, value: []const u8, value_index: usize) bool {
    var p = pattern_index;
    var v = value_index;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                while (p + 1 < pattern.len and pattern[p + 1] == '*') p += 1;
                if (p + 1 == pattern.len) return true;
                var next = v;
                while (next <= value.len) : (next += 1) {
                    if (globMatchAsciiCaseInsensitiveAt(pattern, p + 1, value, next)) return true;
                }
                return false;
            },
            '?' => {
                if (v >= value.len) return false;
                p += 1;
                v += 1;
            },
            else => |char| {
                if (v >= value.len or std.ascii.toLower(value[v]) != std.ascii.toLower(char)) return false;
                p += 1;
                v += 1;
            },
        }
    }
    return v == value.len;
}

test "glob matcher supports exact wildcard and path-ish rules" {
    try std.testing.expect(matchesPattern("git diff *", "git diff src/main.zig"));
    try std.testing.expect(matchesPath("./**", "./src/main.zig"));
    try std.testing.expect(matchesPath("~/.ssh/**", "~/.ssh/id_ed25519"));
    try std.testing.expect(!matchesPath("./.env", "./.env.local"));
}

test "domain and mcp selector matchers support wildcards" {
    try std.testing.expect(matchesDomain("*.github.com", "api.github.com"));
    try std.testing.expect(!matchesDomain("*.github.com", "github.com"));
    try std.testing.expect(matchesDomain("API.GITHUB.COM", "api.github.com"));
    try std.testing.expect(matchesMcpSelector("filesystem.*", "filesystem.read_file"));
}

// Quick-install DX robustness: file path variants for protected directories.
// These protect against hook/plugin callers (Hermes pre_tool_call, OpenClaw, raw CLI)
// that may pass ".git/..." or ".ryk/..." without the leading "./" that the policy strings use.
// The production fix (Phase 2) adds dual explicit patterns + normalization in matchesPath.
test "quick install protected path variants (.git and .ryk, with and without ./)" {
    // Current patterns in quick-install presets use "./.git/**" and "./.ryk/**".
    // Bare forms (no leading ./) must also be denied for real-world DX.
    try std.testing.expect(matchesPath("./.git/**", "./.git/config"));
    try std.testing.expect(matchesPath("./.git/**", ".git/config")); // bare form now works (Phase 2 DX fix)
    try std.testing.expect(matchesPath("./.git/**", ".git/hooks/pre-commit"));

    try std.testing.expect(matchesPath("./.ryk/**", "./.ryk/policy.yaml"));
    try std.testing.expect(matchesPath("./.ryk/**", ".ryk/secret")); // bare form now works (Phase 2 DX fix)

    // Existing ./ forms continue to work (no regression)
    try std.testing.expect(matchesPath("./.git/**", "./.git/HEAD"));
    try std.testing.expect(matchesPath("./.ryk/**", "./.ryk/sessions/abc/audit.log"));

    // Negative: a random .git deeper in tree should not accidentally match the root rule
    // (policy intent is workspace root .git/.ryk; broader protection is a separate concern)
    try std.testing.expect(!matchesPath("./.git/**", "vendor/repo/.git/config"));
}

// Quick-install DX: command allow patterns for bare high-frequency forms + narrow make*.
// "zig build *" already exists in quick-install presets; bare "zig build" (no args) currently
// falls to default ask because the glob "zig build *" requires the literal space before *.
// The DX fix adds the explicit bare form "zig build". make test*/build*/check* are zero-risk
// build-system entrypoints (their globs already match at this layer; the win is adding the strings).
test "quick install command allow patterns (bare zig build glob gap)" {
    // The existing rule "zig build *" does NOT match bare "zig build" (the documented gap).
    // This is the RED signal for adding the explicit bare allow string in common_strict_rules.
    try std.testing.expect(!matchesCommand("zig build *", "zig build"));

    // Suffixed forms work as expected (and will continue to).
    try std.testing.expect(matchesCommand("zig build *", "zig build ."));
    try std.testing.expect(matchesCommand("zig build *", "zig build test"));

    // make test* etc. globs already work at the matcher layer for the intended cases.
    // The DX improvement is simply adding the narrow strings to the preset allow list.
    try std.testing.expect(matchesCommand("make test*", "make test"));
    try std.testing.expect(matchesCommand("make test*", "make test-unit"));

    // Guard: we do not open broad dangerous make neighbors via these patterns.
    try std.testing.expect(!matchesCommand("make test*", "make install"));
    try std.testing.expect(!matchesCommand("make test*", "make deploy"));
}
