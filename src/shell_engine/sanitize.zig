//! Lightweight false-positive immunity: mask known-safe string arguments
//! (rg patterns, git commit messages, echo data) so destructive substrings
//! inside data do not trigger pack matches.
const std = @import("std");

/// Return a heap-owned command with safe data arguments replaced by spaces.
pub fn sanitizeForMatching(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const needs = containsAnyWord(command, &[_][]const u8{
        "rg", "grep", "egrep", "fgrep", "ag", "ack", "echo", "printf",
        "git", "sed", "awk", "cat", "head", "tail", "wc", "sort", "tee",
    }) or std.mem.indexOfScalar(u8, command, '#') != null;
    if (!needs) return try allocator.dupe(u8, command);

    const out = try allocator.dupe(u8, command);
    errdefer allocator.free(out);

    maskComments(out);

    // Data-only commands: mask all quoted spans and, for echo/printf, mask
    // unquoted argv after the command word — but NOT when the data is piped
    // into an interpreter (`echo rm -rf / | sh`), where the payload executes.
    if (isDataOnlyCommand(out) and !pipesIntoInterpreter(out)) {
        maskAllQuoted(out);
        maskArgsAfterCommand(out);
        return out;
    }

    // Search tools: first non-flag arg is often the pattern.
    if (isSearchCommand(out)) {
        maskAllQuoted(out);
        return out;
    }

    // git commit -m / --message: mask message strings.
    if (containsWord(out, "git") and (std.mem.indexOf(u8, out, "commit") != null)) {
        maskAllQuoted(out);
        return out;
    }

    // Long padding lines used in regex_worst_case corpus: if command is mostly
    // filler around a destructive phrase as data, leave as-is only for real exec.
    // Echo-with-padding is already handled by isDataOnlyCommand.

    return out;
}

fn isDataOnlyCommand(cmd: []const u8) bool {
    const t = std.mem.trim(u8, cmd, " \t");
    // first word
    var i: usize = 0;
    while (i < t.len and !std.ascii.isWhitespace(t[i])) : (i += 1) {}
    const word = basename(t[0..i]);
    const data = [_][]const u8{ "echo", "printf", "cat", "tee", "head", "tail", "wc", "sort", "base64", "md5sum", "sha256sum", "less", "more" };
    for (data) |d| {
        if (std.mem.eql(u8, word, d)) return true;
    }
    return false;
}

fn isInterpreterBasename(base: []const u8) bool {
    const names = [_][]const u8{
        "sh", "bash", "zsh", "ksh", "dash", "fish",
        "python", "python3", "ruby", "perl", "node",
    };
    for (names) |n| {
        if (std.mem.eql(u8, base, n)) return true;
    }
    return false;
}

/// True when an unquoted `|` feeds a shell/interpreter (payload becomes executable).
fn pipesIntoInterpreter(cmd: []const u8) bool {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (c == '\\' and !in_single and i + 1 < cmd.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;
        if (c != '|') continue;
        // Skip `||`
        if (i + 1 < cmd.len and cmd[i + 1] == '|') {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < cmd.len and std.ascii.isWhitespace(cmd[j])) : (j += 1) {}
        // Optional env/command wrappers before the interpreter word.
        while (j < cmd.len) {
            var end = j;
            while (end < cmd.len and !std.ascii.isWhitespace(cmd[end]) and cmd[end] != '|' and
                cmd[end] != ';' and cmd[end] != '&' and cmd[end] != '<' and cmd[end] != '>')
                : (end += 1)
            {}
            if (end == j) break;
            const word = cmd[j..end];
            const base = basename(word);
            if (isInterpreterBasename(base)) return true;
            // Skip common wrappers and keep scanning the pipe RHS first word chain.
            if (std.mem.eql(u8, base, "env") or std.mem.eql(u8, base, "command") or
                std.mem.eql(u8, base, "exec") or std.mem.eql(u8, base, "nice") or
                std.mem.eql(u8, base, "nohup") or std.mem.eql(u8, base, "sudo"))
            {
                j = end;
                while (j < cmd.len and std.ascii.isWhitespace(cmd[j])) : (j += 1) {}
                // Skip ENV=val for env
                while (j < cmd.len) {
                    var k = j;
                    while (k < cmd.len and !std.ascii.isWhitespace(cmd[k])) : (k += 1) {}
                    const tok = cmd[j..k];
                    if (std.mem.indexOfScalar(u8, tok, '=') != null) {
                        j = k;
                        while (j < cmd.len and std.ascii.isWhitespace(cmd[j])) : (j += 1) {}
                        continue;
                    }
                    break;
                }
                continue;
            }
            break;
        }
    }
    return false;
}

fn isSearchCommand(cmd: []const u8) bool {
    const t = std.mem.trim(u8, cmd, " \t");
    var i: usize = 0;
    while (i < t.len and !std.ascii.isWhitespace(t[i])) : (i += 1) {}
    const word = basename(t[0..i]);
    const search = [_][]const u8{ "rg", "grep", "egrep", "fgrep", "ag", "ack" };
    for (search) |d| {
        if (std.mem.eql(u8, word, d)) return true;
    }
    return false;
}

fn maskComments(buf: []u8) void {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == '\\' and !in_single and i + 1 < buf.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (!in_single and !in_double and c == '#') {
            while (i < buf.len and buf[i] != '\n') : (i += 1) {
                buf[i] = ' ';
            }
            if (i < buf.len) i -= 1;
        }
    }
}

fn maskAllQuoted(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const c = buf[i];
        if (c == '"' or c == '\'') {
            const q = c;
            i += 1;
            while (i < buf.len and buf[i] != q) : (i += 1) {
                if (buf[i] == '\\' and q == '"' and i + 1 < buf.len) {
                    buf[i] = 'x';
                    i += 1;
                    buf[i] = 'x';
                    continue;
                }
                if (!std.ascii.isWhitespace(buf[i])) buf[i] = 'x';
            }
            if (i < buf.len) i += 1;
            continue;
        }
        // ANSI C $'...'
        if (c == '$' and i + 1 < buf.len and buf[i + 1] == '\'') {
            i += 2;
            while (i < buf.len and buf[i] != '\'') : (i += 1) {
                if (!std.ascii.isWhitespace(buf[i])) buf[i] = 'x';
            }
            if (i < buf.len) i += 1;
            continue;
        }
        i += 1;
    }
}

fn maskArgsAfterCommand(buf: []u8) void {
    // Skip first word, then mask data args — but preserve redirect operators and
    // their targets so `echo x > /etc/passwd` still matches redirect packs while
    // `echo rm -rf /` (data only, no redirect) stays masked.
    var i: usize = 0;
    while (i < buf.len and std.ascii.isWhitespace(buf[i])) : (i += 1) {}
    while (i < buf.len and !std.ascii.isWhitespace(buf[i])) : (i += 1) {}
    while (i < buf.len) {
        if (std.ascii.isWhitespace(buf[i])) {
            i += 1;
            continue;
        }
        if (redirectOperatorEnd(buf, i)) |op_end| {
            // Leave operator bytes intact; advance past them.
            i = op_end;
            while (i < buf.len and std.ascii.isWhitespace(buf[i])) : (i += 1) {}
            // Preserve the redirect target token (path / fd / word).
            while (i < buf.len and !std.ascii.isWhitespace(buf[i])) {
                // Stop if another redirect starts mid-stream (rare glued forms).
                if (redirectOperatorEnd(buf, i) != null) break;
                i += 1;
            }
            continue;
        }
        // Mask one data character (quotes already handled by maskAllQuoted).
        if (buf[i] != '"' and buf[i] != '\'') {
            buf[i] = 'x';
        }
        i += 1;
    }
}

/// If `buf[i..]` starts a shell redirect operator (optional fd digits + `>`/`<`/`&>`/…),
/// return the exclusive end index of the operator; otherwise null.
fn redirectOperatorEnd(buf: []const u8, i: usize) ?usize {
    if (i >= buf.len) return null;
    var j = i;
    // Optional leading fd digits (`2>`, `1>>`, …).
    while (j < buf.len and std.ascii.isDigit(buf[j])) : (j += 1) {}
    if (j < buf.len and buf[j] == '&' and j + 1 < buf.len and buf[j + 1] == '>') {
        return j + 2; // &>
    }
    if (j >= buf.len or (buf[j] != '>' and buf[j] != '<')) {
        // Digits alone are not a redirect.
        return null;
    }
    const op = buf[j];
    j += 1;
    if (j < buf.len and buf[j] == op) j += 1; // >> or <<
    if (j < buf.len and op == '<' and buf[j] == '<') j += 1; // <<<
    if (j < buf.len and buf[j] == '&') {
        j += 1; // >& or <&
        while (j < buf.len and std.ascii.isDigit(buf[j])) : (j += 1) {} // >&1
    }
    if (j < buf.len and op == '>' and buf[j] == '|') j += 1; // >|
    // Require a real operator char was consumed beyond optional digits.
    if (j == i) return null;
    // Pure digits with no operator → not a redirect (already handled above).
    if (j > i and buf[i] != '>' and buf[i] != '<' and buf[i] != '&') {
        // Started with digits; ensure we actually saw an angle/amp operator.
        var saw_op = false;
        var k = i;
        while (k < j) : (k += 1) {
            if (buf[k] == '>' or buf[k] == '<' or buf[k] == '&') {
                saw_op = true;
                break;
            }
        }
        if (!saw_op) return null;
    }
    return j;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx + 1 < path.len) return path[idx + 1 ..];
    }
    return path;
}

fn containsAnyWord(hay: []const u8, words: []const []const u8) bool {
    for (words) |w| {
        if (containsWord(hay, w)) return true;
    }
    return false;
}

fn containsWord(hay: []const u8, word: []const u8) bool {
    if (hay.len < word.len) return false;
    var i: usize = 0;
    while (i + word.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + word.len], word)) {
            const before_ok = i == 0 or !isWordChar(hay[i - 1]);
            const after_ok = i + word.len == hay.len or !isWordChar(hay[i + word.len]);
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

test "sanitize masks rg pattern" {
    const s = try sanitizeForMatching(std.testing.allocator, "rg -n \"rm -rf\" README.md");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}

test "sanitize masks echo data" {
    const s = try sanitizeForMatching(std.testing.allocator, "echo 'rm -rf /'");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}

test "sanitize masks echo unquoted destructive text" {
    const s = try sanitizeForMatching(std.testing.allocator, "echo rm -rf /");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}

test "sanitize masks shell comment body" {
    const s = try sanitizeForMatching(std.testing.allocator, "ls -la # rm -rf /");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}

test "sanitize preserves payload piped into interpreter" {
    const cases = [_][]const u8{
        "echo rm -rf / | sh",
        "echo 'rm -rf /' | bash",
        "printf 'rm -rf /\\n' | /bin/sh",
        "echo rm -rf / | sudo bash",
    };
    for (cases) |cmd| {
        const s = try sanitizeForMatching(std.testing.allocator, cmd);
        defer std.testing.allocator.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") != null);
    }
}

test "sanitize still masks echo data without interpreter sink" {
    const s = try sanitizeForMatching(std.testing.allocator, "echo rm -rf / | cat");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}

test "sanitize preserves redirect operator and sensitive target" {
    const cases = [_][]const u8{
        "echo x > /etc/passwd",
        "printf x > /etc/passwd",
        "cat > /etc/passwd",
        "echo x >/etc/passwd",
        "echo x 2> /etc/shadow",
    };
    for (cases) |cmd| {
        const s = try sanitizeForMatching(std.testing.allocator, cmd);
        defer std.testing.allocator.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, ">") != null);
        // Target path must remain visible for pack matching.
        try std.testing.expect(std.mem.indexOf(u8, s, "/etc/") != null);
    }
}

test "sanitize still masks data-only echo without redirect" {
    const s = try sanitizeForMatching(std.testing.allocator, "echo rm -rf /");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf") == null);
}
