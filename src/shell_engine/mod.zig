//! In-process Zig shell command evaluator.
//!
//! Owns security decisions for `orca hook` / `orca run` / shims.
//! Pack patterns are the frozen orca-rs oracle set (embedded JSON + PCRE2).
//! Evaluator errors fail closed with deny.
//!
//! Phase 1 hard fence (Mode A default packs: core.* + system.disk): structure
//! smart checks (segments, wrappers, assignment masking, embeds) plus reliable
//! filesystem/git/disk catastrophe denials. Not YOLO/Strict policy or FM.

const std = @import("std");

pub const types = @import("types.zig");
pub const allowlist = @import("allowlist.zig");
pub const registry = @import("registry.zig");
pub const segments = @import("segments.zig");
pub const normalize = @import("normalize.zig");
pub const sanitize = @import("sanitize.zig");
pub const suggestions = @import("suggestions.zig");
pub const trace = @import("trace.zig");

pub const Decision = types.Decision;
pub const Severity = types.Severity;
pub const TraceCollector = trace.TraceCollector;
pub const TraceStep = trace.TraceStep;
pub const TraceDetails = trace.TraceDetails;

pub const Evaluation = struct {
    decision: Decision,
    rule_id: ?[]const u8 = null,
    pack_id: ?[]const u8 = null,
    pattern_name: ?[]const u8 = null,
    severity: Severity = .high,
    reason: []const u8,
    explanation: ?[]const u8 = null,
    regex_source: ?[]const u8 = null,
    match_start: ?usize = null,
    match_end: ?usize = null,
    matched_text: ?[]const u8 = null,
    /// Candidate string the span applies to when it differs from the input command.
    matched_candidate: ?[]const u8 = null,
    /// Static tip lines (not freed).
    tips: []const []const u8 = &.{},
    /// Pipeline steps: each is `name (duration)` with nested `detail` child.
    /// Owned when `trace_owned` (explain path with collector).
    trace: []const TraceStep = &.{},
    latency_ms: u64 = 0,
    owned: bool = false,
    /// When true, `trace` slice and each owned `detail` were allocated.
    trace_owned: bool = false,

    pub fn deinit(self: *Evaluation, allocator: std.mem.Allocator) void {
        // Trace ownership is independent of metadata ownership so hooks can
        // attach an empty trace without free paths, and explain can free steps
        // even if other fields are static.
        if (self.trace_owned) {
            for (self.trace) |step| {
                if (step.detail) |d| allocator.free(d);
            }
            if (self.trace.len > 0) allocator.free(self.trace);
            self.trace = &.{};
            self.trace_owned = false;
        }
        if (!self.owned) return;
        if (self.rule_id) |s| allocator.free(s);
        if (self.pack_id) |s| allocator.free(s);
        if (self.pattern_name) |s| allocator.free(s);
        allocator.free(self.reason);
        if (self.explanation) |s| allocator.free(s);
        if (self.regex_source) |s| allocator.free(s);
        if (self.matched_text) |s| allocator.free(s);
        if (self.matched_candidate) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const EvaluateOptions = struct {
    cwd: ?[]const u8 = null,
    allowlists: ?allowlist.Layered = null,
    /// When true (default), only core.* + system.disk (Rust Config::default),
    /// plus any IDs in `extra_enabled`. When false, evaluate the full registry
    /// (still honoring `disabled`).
    default_packs_only: bool = true,
    /// Opt-in pack IDs from cwd-scoped config (`[packs] enabled = [...]`).
    extra_enabled: []const []const u8 = &.{},
    /// Pack IDs from cwd-scoped config (`[packs] disabled = [...]`).
    disabled: []const []const u8 = &.{},
    /// Opt-in explain instrumentation. Null on hooks/run (zero cost).
    trace: ?*TraceCollector = null,
};

/// Evaluate a shell command line.
/// Empty command is a no-op allow (matches oracle). Registry init failure → deny.
/// When `options.trace` is non-null, records real timed pipeline steps for explain.
pub fn evaluateCommand(allocator: std.mem.Allocator, command: []const u8, options: EvaluateOptions) !Evaluation {
    const started_ms = monotonicMs();
    if (options.trace) |t| t.beginStep();

    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) {
        try endOuterStep(options.trace, .{ .message = "empty command no-op" });
        return try finalizeEval(allocator, options.trace, allowStatic("Empty command is a no-op."), elapsedMs(started_ms));
    }

    if (options.allowlists) |lists| {
        if (lists.allows(trimmed)) {
            try endOuterStep(options.trace, .{ .allowlist = .{ .matched = true } });
            return try finalizeEval(allocator, options.trace, allowStatic("Command allowed by allowlist."), elapsedMs(started_ms));
        }
    }

    registry.ensureInit() catch {
        try endOuterStep(options.trace, .{ .message = "registry init failure (fail-closed)" });
        return try finalizeEval(
            allocator,
            options.trace,
            denyStatic("zig.shell:init", "zig.shell", "init-failure", .critical, "Shell pack registry failed to initialize (fail-closed)."),
            elapsedMs(started_ms),
        );
    };

    const match_opts = registry.MatchOptions{
        .default_packs_only = options.default_packs_only,
        .extra_enabled = options.extra_enabled,
        .disabled = options.disabled,
    };

    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(allocator);

    // Non-executing heredocs (cat/tee/grep <<EOF …): mask bodies and do NOT
    // segment-split on newlines (body lines would otherwise be evaluated as
    // free-standing commands).
    const has_heredoc = std.mem.indexOf(u8, trimmed, "<<") != null;
    const is_herestring_only = std.mem.indexOf(u8, trimmed, "<<<") != null and
        std.mem.indexOf(u8, trimmed, "<<") == std.mem.indexOf(u8, trimmed, "<<<");
    var masked_storage: ?[]u8 = null;
    defer if (masked_storage) |m| allocator.free(m);
    // Embed buffers must outlive the candidate list (slices point into them).
    var embeds_owned: [][]const u8 = &.{};
    defer if (embeds_owned.len > 0) normalize.freeEmbeds(allocator, embeds_owned);

    // Non-executing heredocs: mask body only when a real terminator is found
    // (oracle `mask_non_executing_heredocs`). If the delimiter form cannot be
    // closed (e.g. `<<\EOF` vs terminator `EOF`), leave the body visible and
    // segment-split so free-standing destructive lines still deny (fail closed).
    if (has_heredoc and !is_herestring_only and !isExecutingContext(trimmed)) {
        masked_storage = try maskNonExecutingHeredoc(allocator, trimmed);
        const working = masked_storage.?;
        try candidates.append(allocator, working);
        try appendSegments(allocator, &candidates, working);
    } else {
        // Prefer per-segment evaluation so assignment values and safe prefixes
        // cannot poison a full-string regex match. Also keep the full command
        // for patterns that legitimately span segments (after sanitize).
        try appendSegments(allocator, &candidates, trimmed);
        if (candidates.items.len <= 1) {
            // No separators — evaluate the whole line.
            if (candidates.items.len == 0) try candidates.append(allocator, trimmed);
        } else {
            // Multi-segment: still include a sanitized full-string candidate for
            // spanning patterns, with assignment RHS masked.
            const masked_assign = try maskAssignmentValues(allocator, trimmed);
            if (masked_storage == null) {
                masked_storage = masked_assign;
                try candidates.append(allocator, masked_storage.?);
            } else {
                allocator.free(masked_assign);
            }
        }

        if (isExecutingContext(trimmed)) {
            embeds_owned = try normalize.extractEmbeds(allocator, trimmed);
            for (embeds_owned) |e| {
                try candidates.append(allocator, e);
                try appendSegments(allocator, &candidates, e);
            }
        }
    }

    // DCG collapses to one outer timed step; we record real pack outcome only.

    for (candidates.items) |cand| {
        if (try evalOne(allocator, cand, match_opts, .{})) |hit| {
            try endOuterStep(options.trace, .{
                .pack_evaluation = .{
                    .matched_pack = hit.pack_id,
                    .matched_pattern = hit.pattern_name,
                },
            });
            return try finalizeEval(
                allocator,
                options.trace,
                try denyFromHit(allocator, hit, cand, elapsedMs(started_ms)),
                elapsedMs(started_ms),
            );
        }
    }

    // Data-only | shell/interpreter: sanitize masks LHS payload, bare bash RHS has
    // no pack hit. Re-evaluate pipeline prefixes that feed an executor without
    // data-only sanitize so `echo 'rm -rf /' | bash` denies.
    var pipe_payloads: std.ArrayList([]const u8) = .empty;
    defer pipe_payloads.deinit(allocator);
    try appendPipelinePrefixesToExecutor(trimmed, allocator, &pipe_payloads);
    for (pipe_payloads.items) |cand| {
        if (try evalOne(allocator, cand, match_opts, .{ .skip_data_sanitize = true })) |hit| {
            try endOuterStep(options.trace, .{
                .pack_evaluation = .{
                    .matched_pack = hit.pack_id,
                    .matched_pattern = hit.pattern_name,
                },
            });
            return try finalizeEval(
                allocator,
                options.trace,
                try denyFromHit(allocator, hit, cand, elapsedMs(started_ms)),
                elapsedMs(started_ms),
            );
        }
    }

    _ = options.cwd;
    try endOuterStep(options.trace, .{
        .pack_evaluation = .{
            .matched_pack = null,
            .matched_pattern = null,
            .packs_scanned = 0,
        },
    });
    var allow = allowStatic("No destructive pack matched.");
    allow.latency_ms = elapsedMs(started_ms);
    allow.tips = &.{};
    return try finalizeEval(allocator, options.trace, allow, elapsedMs(started_ms));
}

fn endOuterStep(collector: ?*TraceCollector, details: TraceDetails) !void {
    if (collector) |t| try t.endStep("full_evaluation", details);
}

/// Attach collector steps to Evaluation when tracing; leave empty on null (hooks).
fn finalizeEval(
    allocator: std.mem.Allocator,
    collector: ?*TraceCollector,
    eval_in: Evaluation,
    latency_ms: u64,
) !Evaluation {
    var eval = eval_in;
    errdefer eval.deinit(allocator);
    eval.latency_ms = latency_ms;
    if (collector) |t| {
        // Steps already recorded via endOuterStep; take ownership into Evaluation.
        if (t.steps.items.len > 0) {
            const steps = try t.takeSteps();
            eval.trace = steps;
            eval.trace_owned = true;
        }
    }
    // Null collector → empty trace (zero cost; no fake peer steps).
    return eval;
}

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn elapsedMs(started_ms: i64) u64 {
    const now = monotonicMs();
    if (now <= started_ms) return 0;
    return @intCast(now - started_ms);
}

fn denyFromHit(
    allocator: std.mem.Allocator,
    hit: registry.Hit,
    candidate: []const u8,
    latency_ms: u64,
) !Evaluation {
    // Match metadata only — pipeline steps come from TraceCollector (or empty).
    // Never invent peer steps named `matched`.
    const rule_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ hit.pack_id, hit.pattern_name });
    errdefer allocator.free(rule_id);
    const pack_copy = try allocator.dupe(u8, hit.pack_id);
    errdefer allocator.free(pack_copy);
    const pattern_copy = try allocator.dupe(u8, hit.pattern_name);
    errdefer allocator.free(pattern_copy);
    const reason_copy = try allocator.dupe(u8, hit.reason);
    errdefer allocator.free(reason_copy);

    const explanation = try std.fmt.allocPrint(
        allocator,
        "Matched destructive pattern {s}:{s}.",
        .{ hit.pack_id, hit.pattern_name },
    );
    errdefer allocator.free(explanation);

    var regex_copy: ?[]const u8 = null;
    errdefer if (regex_copy) |s| allocator.free(s);
    if (hit.regex_source) |rx| regex_copy = try allocator.dupe(u8, rx);

    var matched_text: ?[]const u8 = null;
    errdefer if (matched_text) |s| allocator.free(s);
    var match_start = hit.match_start;
    var match_end = hit.match_end;
    if (match_start) |s| {
        if (match_end) |e| {
            if (e >= s and e <= candidate.len) {
                matched_text = try allocator.dupe(u8, candidate[s..e]);
            } else {
                match_start = null;
                match_end = null;
            }
        }
    }

    const cand_copy = try allocator.dupe(u8, candidate);
    errdefer allocator.free(cand_copy);

    return .{
        .decision = .deny,
        .rule_id = rule_id,
        .pack_id = pack_copy,
        .pattern_name = pattern_copy,
        .severity = hit.severity,
        .reason = reason_copy,
        .explanation = explanation,
        .regex_source = regex_copy,
        .match_start = match_start,
        .match_end = match_end,
        .matched_text = matched_text,
        .matched_candidate = cand_copy,
        .tips = suggestions.forPattern(hit.pack_id, hit.pattern_name),
        .trace = &.{},
        .latency_ms = latency_ms,
        .owned = true,
        .trace_owned = false,
    };
}

/// True when the outer command is an executing shell/interpreter (not cat/tee/grep data sinks).
fn isExecutingContext(cmd: []const u8) bool {
    const has_c_or_e = std.mem.indexOf(u8, cmd, " -c ") != null or
        std.mem.indexOf(u8, cmd, " -c'") != null or
        std.mem.indexOf(u8, cmd, " -c\"") != null or
        std.mem.indexOf(u8, cmd, "\t-c ") != null or
        std.mem.indexOf(u8, cmd, " -e ") != null or
        std.mem.indexOf(u8, cmd, " -e'") != null or
        std.mem.indexOf(u8, cmd, " -e\"") != null or
        // glued forms: python.exe -c"..." / -c'...'
        std.mem.indexOf(u8, cmd, " -c\"") != null or
        std.mem.indexOf(u8, cmd, "-c \"") != null or
        std.mem.indexOf(u8, cmd, "-c '") != null or
        std.mem.indexOf(u8, cmd, "-c\"") != null or
        std.mem.indexOf(u8, cmd, "-c'") != null or
        std.mem.indexOf(u8, cmd, "-e \"") != null or
        std.mem.indexOf(u8, cmd, "-e'") != null;

    if (has_c_or_e) {
        // First command word: accept python.exe / python3.11.exe / /usr/bin/python3
        if (firstArgv0LooksLikeExecutor(cmd)) return true;
        if (std.mem.indexOf(u8, cmd, "/bash") != null or std.mem.indexOf(u8, cmd, "/python") != null or
            std.mem.indexOf(u8, cmd, "/ruby") != null or std.mem.indexOf(u8, cmd, "/node") != null or
            std.mem.indexOf(u8, cmd, "/perl") != null)
            return true;
    }
    // Heredoc into shell/interpreter — including attached forms like `/bin/bash<<'EOF'`.
    if (std.mem.indexOf(u8, cmd, "<<") != null) {
        if (heredocReceiverIsExecuting(cmd)) return true;
        return false;
    }
    if (std.mem.indexOf(u8, cmd, "<<<") != null) {
        // here-string often on shell
        return true;
    }
    return false;
}

fn commandWordBasename(word: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |idx| {
        if (idx + 1 < word.len) return word[idx + 1 ..];
    }
    return word;
}

fn isInterpreterBasename(base: []const u8) bool {
    const names = [_][]const u8{
        "bash", "sh", "zsh", "ksh", "dash", "fish",
        "ruby", "perl", "node",
    };
    for (names) |n| {
        if (std.mem.eql(u8, base, n)) return true;
    }
    // python / python3 / python3.14 (versioned suffixes)
    return interpreterBasenameLoose(base);
}

fn isDataSinkBasename(base: []const u8) bool {
    const sinks = [_][]const u8{
        "cat",  "tee",  "grep",   "egrep", "fgrep",  "sed",       "awk",  "wc",   "sort",
        "head", "tail", "base64", "md5",   "md5sum", "sha256sum", "curl", "less", "more",
    };
    for (sinks) |s| {
        if (std.mem.eql(u8, base, s)) return true;
    }
    return false;
}

/// True when a `<<` heredoc (not `<<<`) is received by a shell/interpreter path.
/// Handles whitespace, attached forms (`/bin/bash<<'EOF'`), and options before
/// the redirect (`bash -s <<'EOF'`) by resolving argv0 of the simple command.
fn heredocReceiverIsExecuting(cmd: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < cmd.len) : (i += 1) {
        if (cmd[i] != '<' or cmd[i + 1] != '<') continue;
        // Skip here-string `<<<`.
        if (i + 2 < cmd.len and cmd[i + 2] == '<') {
            i += 2;
            continue;
        }
        const segment = simpleCommandPrefixBefore(cmd, i);
        if (segmentArgv0Kind(segment)) |kind| {
            return switch (kind) {
                .executing => true,
                .data_sink => false,
            };
        }
    }
    return false;
}

/// Slice of `cmd[0..redirect_at]` that is the current simple command (after the
/// last `|`, `;`, `&`, newline, or `&&` / `||`).
fn simpleCommandPrefixBefore(cmd: []const u8, redirect_at: usize) []const u8 {
    var seg_start: usize = 0;
    var k: usize = 0;
    while (k < redirect_at) : (k += 1) {
        const c = cmd[k];
        if (c == '\n' or c == ';' or c == '|') {
            if (c == '|' and k + 1 < redirect_at and cmd[k + 1] == '|') {
                seg_start = k + 2;
                k += 1;
                continue;
            }
            seg_start = k + 1;
            continue;
        }
        if (c == '&') {
            if (k + 1 < redirect_at and cmd[k + 1] == '&') {
                seg_start = k + 2;
                k += 1;
            } else {
                seg_start = k + 1;
            }
        }
    }
    while (seg_start < redirect_at and std.ascii.isWhitespace(cmd[seg_start])) : (seg_start += 1) {}
    return cmd[seg_start..redirect_at];
}

const ReceiverKind = enum { executing, data_sink };

/// Resolve argv0 of a simple-command prefix (options and env assigns stripped).
fn segmentArgv0Kind(segment: []const u8) ?ReceiverKind {
    var i: usize = 0;
    while (i < segment.len) {
        while (i < segment.len and std.ascii.isWhitespace(segment[i])) : (i += 1) {}
        if (i >= segment.len) break;

        // Skip env assignments NAME=value (unquoted simple form).
        var j = i;
        while (j < segment.len and (std.ascii.isAlphanumeric(segment[j]) or segment[j] == '_')) : (j += 1) {}
        if (j > i and j < segment.len and segment[j] == '=') {
            while (j < segment.len and !std.ascii.isWhitespace(segment[j])) : (j += 1) {}
            i = j;
            continue;
        }

        const word = nextShellWord(segment, &i);
        if (word.len == 0) break;

        // Strip surrounding quotes before basename so `"/bin/bash"` → bash.
        var bare = word;
        if (bare.len >= 2 and (bare[0] == '\'' or bare[0] == '"') and bare[bare.len - 1] == bare[0]) {
            bare = bare[1 .. bare.len - 1];
        }
        var base = commandWordBasename(bare);
        if (base.len >= 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) {
            base = base[0 .. base.len - 4];
        }

        // Known wrappers: keep scanning for the real receiver.
        if (isHeredocWrapperBasename(base)) {
            // Consume following option tokens (+ operands for options that take one).
            while (i < segment.len) {
                var peek = i;
                while (peek < segment.len and std.ascii.isWhitespace(segment[peek])) : (peek += 1) {}
                if (peek >= segment.len) break;
                if (segment[peek] != '-') break;
                const opt = nextShellWord(segment, &i);
                if (wrapperOptionTakesOperand(base, opt)) {
                    // Consume the operand unless already attached via `=`.
                    var peek2 = i;
                    while (peek2 < segment.len and std.ascii.isWhitespace(segment[peek2])) : (peek2 += 1) {}
                    if (peek2 < segment.len and segment[peek2] != '-') {
                        _ = nextShellWord(segment, &i);
                    }
                }
            }
            continue;
        }

        // Shell reserved words are syntax, not receivers (`then bash <<EOF`).
        if (isShellReservedWord(base)) continue;

        if (isDataSinkBasename(base)) return .data_sink;
        if (isInterpreterBasename(base) or interpreterBasenameLoose(base)) return .executing;

        // Leading option without argv0 yet → keep scanning (rare).
        if (base.len > 0 and base[0] == '-') continue;

        // Unknown command word is not an executing shell receiver.
        return null;
    }
    return null;
}

fn isShellReservedWord(base: []const u8) bool {
    const words = [_][]const u8{
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "in", "!", "{", "}", "[[", "]]", "function", "select", "coproc",
    };
    for (words) |w| {
        if (std.mem.eql(u8, base, w)) return true;
    }
    return false;
}

fn wrapperOptionTakesOperand(wrapper: []const u8, opt: []const u8) bool {
    if (opt.len == 0) return false;
    if (std.mem.indexOfScalar(u8, opt, '=')) |_| return false; // --unset=NAME
    if (std.mem.eql(u8, wrapper, "env")) {
        return std.mem.eql(u8, opt, "-u") or std.mem.eql(u8, opt, "--unset") or
            std.mem.eql(u8, opt, "-C") or std.mem.eql(u8, opt, "--chdir") or
            std.mem.eql(u8, opt, "-S") or std.mem.eql(u8, opt, "--split-string");
    }
    if (std.mem.eql(u8, wrapper, "sudo") or std.mem.eql(u8, wrapper, "doas")) {
        return std.mem.eql(u8, opt, "-u") or std.mem.eql(u8, opt, "-g") or
            std.mem.eql(u8, opt, "-h") or std.mem.eql(u8, opt, "-C") or
            std.mem.eql(u8, opt, "-D") or std.mem.eql(u8, opt, "-R") or
            std.mem.eql(u8, opt, "-T") or std.mem.eql(u8, opt, "-p") or
            std.mem.eql(u8, opt, "-r") or std.mem.eql(u8, opt, "-t");
    }
    if (std.mem.eql(u8, wrapper, "nice")) {
        return std.mem.eql(u8, opt, "-n") or std.mem.eql(u8, opt, "--adjustment");
    }
    if (std.mem.eql(u8, wrapper, "stdbuf")) {
        return std.mem.eql(u8, opt, "-i") or std.mem.eql(u8, opt, "-o") or std.mem.eql(u8, opt, "-e") or
            std.mem.eql(u8, opt, "--input") or std.mem.eql(u8, opt, "--output") or std.mem.eql(u8, opt, "--error");
    }
    return false;
}

fn isHeredocWrapperBasename(base: []const u8) bool {
    const wrappers = [_][]const u8{ "sudo", "doas", "env", "nice", "nohup", "command", "time", "stdbuf" };
    for (wrappers) |w| {
        if (std.mem.eql(u8, base, w)) return true;
    }
    return false;
}

fn interpreterBasenameLoose(base: []const u8) bool {
    // python3.11, python3, bash.exe already stripped
    if (std.mem.startsWith(u8, base, "python")) {
        const rest = base["python".len..];
        if (rest.len == 0) return true;
        for (rest) |c| {
            if (!std.ascii.isDigit(c) and c != '.') return false;
        }
        return true;
    }
    return false;
}

/// Advance `idx` past the next shell word in `s`; return the word slice.
fn nextShellWord(s: []const u8, idx: *usize) []const u8 {
    while (idx.* < s.len and std.ascii.isWhitespace(s[idx.*])) : (idx.* += 1) {}
    if (idx.* >= s.len) return s[idx.*..idx.*];
    const start = idx.*;
    const quote = s[start];
    if (quote == '\'' or quote == '"') {
        idx.* = start + 1;
        while (idx.* < s.len and s[idx.*] != quote) : (idx.* += 1) {}
        if (idx.* < s.len) idx.* += 1;
        return s[start..idx.*];
    }
    while (idx.* < s.len and !std.ascii.isWhitespace(s[idx.*])) : (idx.* += 1) {}
    return s[start..idx.*];
}

/// Basename of argv0 with optional `.exe` stripped; true for shells/interpreters.
fn firstArgv0LooksLikeExecutor(cmd: []const u8) bool {
    const t = std.mem.trim(u8, cmd, " \t\r\n");
    if (t.len == 0) return false;
    var i: usize = 0;
    // skip leading env assignments: NAME=val
    while (i < t.len) {
        var j = i;
        while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) : (j += 1) {}
        if (j > i and j < t.len and t[j] == '=') {
            while (j < t.len and !std.ascii.isWhitespace(t[j])) : (j += 1) {}
            while (j < t.len and std.ascii.isWhitespace(t[j])) : (j += 1) {}
            i = j;
            continue;
        }
        break;
    }
    var end = i;
    while (end < t.len and !std.ascii.isWhitespace(t[end])) : (end += 1) {}
    var word = t[i..end];
    // basename
    if (std.mem.lastIndexOfScalar(u8, word, '/')) |slash| {
        word = word[slash + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, word, '\\')) |slash| {
        word = word[slash + 1 ..];
    }
    // strip .exe
    if (word.len >= 4 and std.ascii.eqlIgnoreCase(word[word.len - 4 ..], ".exe")) {
        word = word[0 .. word.len - 4];
    }
    // python / python3 / python3.11
    if (std.mem.startsWith(u8, word, "python")) {
        const rest = word["python".len..];
        if (rest.len == 0) return true;
        // version-only suffix
        var all_ver = true;
        for (rest) |c| {
            if (!std.ascii.isDigit(c) and c != '.') {
                all_ver = false;
                break;
            }
        }
        if (all_ver) return true;
    }
    const exact = [_][]const u8{ "bash", "sh", "zsh", "ksh", "dash", "ruby", "perl", "node" };
    for (exact) |e| {
        if (std.mem.eql(u8, word, e)) return true;
    }
    return false;
}

fn appendSegments(allocator: std.mem.Allocator, candidates: *std.ArrayList([]const u8), cmd: []const u8) !void {
    const segs = try segments.splitCommandSegments(cmd, allocator);
    defer segments.freeSegments(allocator, segs);
    for (segs) |s| {
        try candidates.append(allocator, s);
    }
}

const EvalOneOptions = struct {
    /// When true, skip data-only sanitize masking (LHS of pipe-to-shell is executing).
    skip_data_sanitize: bool = false,
};

/// Collect pipeline prefixes that feed a shell/interpreter via `|` / `|&`.
/// Items are borrowed slices into `cmd` (caller must keep `cmd` alive).
fn appendPipelinePrefixesToExecutor(
    cmd: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
) !void {
    var pipeline_start: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;

    while (i < cmd.len) {
        const b = cmd[i];
        if (b == '\\' and !in_single and i + 1 < cmd.len) {
            i += 2;
            continue;
        }
        if (b == '\'' and !in_double) {
            in_single = !in_single;
            i += 1;
            continue;
        }
        if (b == '"' and !in_single) {
            in_double = !in_double;
            i += 1;
            continue;
        }
        if (in_single or in_double) {
            i += 1;
            continue;
        }

        // Non-pipe separators end the current pipeline group.
        if (b == ';' or b == '\n') {
            pipeline_start = i + 1;
            i += 1;
            continue;
        }
        if (b == '&') {
            // `>&` / `&>` redirections are not command separators.
            if (i > 0 and cmd[i - 1] == '>') {
                i += 1;
                continue;
            }
            if (i + 1 < cmd.len and cmd[i + 1] == '>') {
                i += 1;
                continue;
            }
            if (i + 1 < cmd.len and cmd[i + 1] == '&') {
                pipeline_start = i + 2;
                i += 2;
                continue;
            }
            pipeline_start = i + 1;
            i += 1;
            continue;
        }
        if (b == '|') {
            if (i + 1 < cmd.len and cmd[i + 1] == '|') {
                pipeline_start = i + 2;
                i += 2;
                continue;
            }
            var w: usize = 1;
            if (i + 1 < cmd.len and cmd[i + 1] == '&') w = 2; // |&
            const rhs_start = i + w;
            if (firstArgv0LooksLikeExecutor(cmd[rhs_start..])) {
                const prefix = std.mem.trim(u8, cmd[pipeline_start..i], " \t\r\n");
                if (prefix.len > 0) try out.append(allocator, prefix);
            }
            // Continue scanning; later stages may also be executors.
            i = rhs_start;
            continue;
        }
        i += 1;
    }
}

fn evalOne(allocator: std.mem.Allocator, cand: []const u8, match_opts: registry.MatchOptions, opts: EvalOneOptions) !?registry.Hit {
    const trimmed = std.mem.trim(u8, cand, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Pure assignment segment (VAR=value) — not executed as a command word.
    if (isAssignmentOnly(trimmed)) return null;

    // Mask non-executing heredoc bodies (cat/tee/grep <<EOF …) so data cannot trigger packs.
    // When skip_data_sanitize (pipe-to-shell LHS), leave bodies visible — stdin is executing.
    const masked_hd = if (opts.skip_data_sanitize)
        try allocator.dupe(u8, trimmed)
    else
        try maskNonExecutingHeredoc(allocator, trimmed);
    defer allocator.free(masked_hd);

    const sanitized = if (opts.skip_data_sanitize)
        try allocator.dupe(u8, masked_hd)
    else
        try sanitize.sanitizeForMatching(allocator, masked_hd);
    defer allocator.free(sanitized);

    // Language-runtime destructive APIs inside -c/-e bodies (no pack regex covers these).
    if (matchLangDestruct(sanitized)) |h| return h;

    // ${TMPDIR:-/tmp}/… is a temp-family path (bash default expansion).
    const for_match = try rewriteTempDefault(allocator, sanitized);
    defer allocator.free(for_match);

    if (matchDeny(for_match, match_opts)) |h| return h;

    // Wrapper strip only on the sanitized form so false-positive data stays masked.
    var norm = try normalize.normalizeCommand(allocator, for_match);
    defer norm.deinit(allocator);
    if (matchDeny(norm.normalized, match_opts)) |h| return h;

    return null;
}

fn isAssignmentOnly(cmd: []const u8) bool {
    // NAME=VALUE with no leading command word.
    if (cmd.len == 0 or std.ascii.isDigit(cmd[0])) return false;
    var i: usize = 0;
    while (i < cmd.len and (std.ascii.isAlphanumeric(cmd[i]) or cmd[i] == '_')) : (i += 1) {}
    if (i == 0 or i >= cmd.len or cmd[i] != '=') return false;
    // Reject if there is another word that looks like a command after the value.
    // Simple: if the line is a single assignment token (possibly quoted value), treat as assignment.
    // `VAR=x cmd` is not assignment-only.
    var j = i + 1;
    if (j < cmd.len and (cmd[j] == '\'' or cmd[j] == '"')) {
        const q = cmd[j];
        j += 1;
        while (j < cmd.len and cmd[j] != q) : (j += 1) {}
        if (j < cmd.len) j += 1;
    } else {
        while (j < cmd.len and !std.ascii.isWhitespace(cmd[j])) : (j += 1) {}
    }
    while (j < cmd.len and std.ascii.isWhitespace(cmd[j])) : (j += 1) {}
    return j >= cmd.len;
}

fn matchLangDestruct(cmd: []const u8) ?registry.Hit {
    // shutil.rmtree / os.remove / FileUtils.rm_rf on sensitive paths.
    const apis = [_][]const u8{ "rmtree(", "os.remove(", "os.unlink(", "FileUtils.rm_rf(", "FileUtils.rm_r(", "Path.rmtree(" };
    var hit_api = false;
    for (apis) |a| {
        if (std.mem.indexOf(u8, cmd, a) != null) {
            hit_api = true;
            break;
        }
    }
    if (!hit_api) return null;
    // Any path-like argument or bare call → treat as destructive filesystem op.
    const sensitive = [_][]const u8{ "/home", "/etc", "/usr", "/var", "/root", "/tmp", "~", "$HOME", "'/'", "\"/\"" };
    for (sensitive) |s| {
        if (std.mem.indexOf(u8, cmd, s) != null) {
            return .{
                .pack_id = "core.filesystem",
                .pattern_name = "rm-rf-general",
                .severity = .high,
                .reason = "Language-runtime recursive delete (rmtree/remove) is destructive and requires human approval.",
            };
        }
    }
    // Even without sensitive path literal, rmtree/rm_rf is high risk.
    return .{
        .pack_id = "core.filesystem",
        .pattern_name = "rm-rf-general",
        .severity = .high,
        .reason = "Language-runtime recursive delete is destructive and requires human approval.",
    };
}

/// Mask `NAME=value` / `NAME='...'` / `NAME="..."` RHS so assignment text cannot
/// trigger pack regexes when evaluating a multi-segment full command.
fn maskAssignmentValues(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, cmd);
    var i: usize = 0;
    while (i < out.len) {
        // start of potential NAME=
        if (i == 0 or out[i - 1] == ';' or out[i - 1] == '\n' or std.ascii.isWhitespace(out[i - 1]) or out[i - 1] == '&' or out[i - 1] == '|') {
            var j = i;
            if (j < out.len and (std.ascii.isAlphabetic(out[j]) or out[j] == '_')) {
                while (j < out.len and (std.ascii.isAlphanumeric(out[j]) or out[j] == '_')) : (j += 1) {}
                if (j < out.len and out[j] == '=') {
                    j += 1;
                    if (j < out.len and (out[j] == '\'' or out[j] == '"')) {
                        const q = out[j];
                        j += 1;
                        while (j < out.len and out[j] != q) : (j += 1) {
                            if (!std.ascii.isWhitespace(out[j])) out[j] = 'x';
                        }
                        i = if (j < out.len) j + 1 else j;
                        continue;
                    } else {
                        while (j < out.len and !std.ascii.isWhitespace(out[j]) and out[j] != ';' and out[j] != '&' and out[j] != '|') : (j += 1) {
                            out[j] = 'x';
                        }
                        i = j;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
    return out;
}

fn rewriteTempDefault(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
    // Map ${TMPDIR:-/tmp} and ${TMPDIR:=/tmp} to $TMPDIR for safe-pattern matching.
    var out = try allocator.dupe(u8, cmd);
    errdefer allocator.free(out);
    const needles = [_][]const u8{ "${TMPDIR:-/tmp}", "${TMPDIR:=/tmp}", "${TMPDIR-:/tmp}" };
    for (needles) |n| {
        while (std.mem.indexOf(u8, out, n)) |idx| {
            // replace with $TMPDIR (shorter) — rebuild
            const new_len = out.len - n.len + "$TMPDIR".len;
            const rebuilt = try allocator.alloc(u8, new_len);
            @memcpy(rebuilt[0..idx], out[0..idx]);
            @memcpy(rebuilt[idx .. idx + 7], "$TMPDIR");
            @memcpy(rebuilt[idx + 7 ..], out[idx + n.len ..]);
            allocator.free(out);
            out = rebuilt;
        }
    }
    return out;
}

/// True when a non-executing heredoc was present but its body was not blanked
/// (missing/mismatched terminator). Used to enable fail-closed segment split.
fn heredocBodyLikelyUnmasked(masked: []const u8, original: []const u8) bool {
    // If masking blanked body bytes to 'x', non-ws content length drops.
    // Unmasked: original and masked share the same non-trivial payload.
    if (masked.len != original.len) return true;
    return std.mem.eql(u8, masked, original);
}

/// Blank out heredoc bodies when the receiver is a data sink (cat/tee/…), matching
/// Rust `mask_non_executing_heredocs` intent.
///
/// Only masks when a matching terminator line is found for the delimiter token
/// as written (including a leading `\` in unquoted forms). That matches the
/// oracle mask path: `<<\EOF` uses delimiter `\EOF` which does not match a
/// closing `EOF` line, so the body stays visible and pack matching fails closed.
fn maskNonExecutingHeredoc(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, cmd);
    if (std.mem.indexOf(u8, cmd, "<<") == null) return out;
    if (isExecutingContext(cmd)) return out;

    // Find first << (not <<<)
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) {
        if (out[i] == '<' and out[i + 1] == '<' and !(i + 2 < out.len and out[i + 2] == '<')) {
            var p = i + 2;
            // optional <<- / <<~ marker adjacent to <<
            if (p < out.len and (out[p] == '-' or out[p] == '~')) p += 1;
            while (p < out.len and (out[p] == ' ' or out[p] == '\t')) : (p += 1) {}

            // Parse delimiter token (quoted or bare, including leading `\`).
            // Only quoted delimiters disable shell expansion of the body — safe to mask.
            var delim: []const u8 = "";
            var delim_quoted = false;
            if (p < out.len and (out[p] == '\'' or out[p] == '"')) {
                delim_quoted = true;
                const q = out[p];
                p += 1;
                const start = p;
                while (p < out.len and out[p] != q) : (p += 1) {}
                delim = out[start..p];
                if (p < out.len) p += 1; // closing quote
            } else {
                const start = p;
                while (p < out.len and out[p] != ' ' and out[p] != '\t' and out[p] != '\n' and out[p] != '\r' and
                    out[p] != ';' and out[p] != '&' and out[p] != '|') : (p += 1)
                {}
                delim = out[start..p];
            }
            if (delim.len == 0) break;

            // Body starts after the newline following the delimiter token.
            while (p < out.len and out[p] != '\n') : (p += 1) {}
            if (p >= out.len) break;
            const body_start = p + 1;

            // Find terminator line equal to delim (oracle: exact line match).
            var search = body_start;
            var found_end: ?usize = null;
            while (search <= out.len) {
                const line_end = if (std.mem.indexOfScalar(u8, out[search..], '\n')) |n|
                    search + n
                else
                    out.len;
                const line = out[search..line_end];
                const line_trim = std.mem.trim(u8, line, " \t\r");
                if (std.mem.eql(u8, line_trim, delim)) {
                    found_end = search;
                    break;
                }
                if (line_end >= out.len) break;
                search = line_end + 1;
            }

            if (found_end) |body_end| {
                const body = out[body_start..body_end];
                // Unquoted delimiters expand $(...) / `...` — leave those bodies matchable.
                // Literal bodies (no expansions) remain safe to mask for data sinks.
                if (!delim_quoted and bodyHasShellExpansion(body)) {
                    // Still scan later << redirects on this command.
                    i += 1;
                    continue;
                }
                // Mask body only (preserve newlines / whitespace structure).
                var q = body_start;
                while (q < body_end) : (q += 1) {
                    if (out[q] != '\n' and out[q] != '\r' and !std.ascii.isWhitespace(out[q])) {
                        out[q] = 'x';
                    }
                }
                // Resume just after this `<<` so same-line stacked redirects are found
                // (`cat <<A <<B` …).
                i += 1;
                continue;
            }
            // If terminator not found, leave body unmasked (fail closed) and keep scanning.
            i += 1;
            continue;
        }
    }
    return out;
}

fn bodyHasShellExpansion(body: []const u8) bool {
    // Conservative: any unquoted-ish $(, $`, or backtick may expand under unquoted heredoc.
    if (std.mem.indexOf(u8, body, "$(") != null) return true;
    if (std.mem.indexOfScalar(u8, body, '`') != null) return true;
    // ${...} parameter expansion can nest command substitution; treat as expansion surface.
    if (std.mem.indexOf(u8, body, "${") != null) return true;
    return false;
}

fn matchDeny(cmd: []const u8, match_opts: registry.MatchOptions) ?registry.Hit {
    return switch (registry.matchCommandDetailedOpts(cmd, match_opts)) {
        .deny => |h| h,
        .allow_safe, .allow_miss => null,
    };
}

fn allowStatic(reason: []const u8) Evaluation {
    return .{
        .decision = .allow,
        .severity = .low,
        .reason = reason,
        .owned = false,
    };
}

fn denyStatic(
    rule_id: []const u8,
    pack_id: []const u8,
    pattern_name: []const u8,
    severity: Severity,
    reason: []const u8,
) Evaluation {
    return .{
        .decision = .deny,
        .rule_id = rule_id,
        .pack_id = pack_id,
        .pattern_name = pattern_name,
        .severity = severity,
        .reason = reason,
        .owned = false,
    };
}

pub const CorpusCase = struct {
    command: []const u8,
    expected: []const u8,
    rule_id: ?[]const u8 = null,
    deferred: bool = false,
};

pub fn decisionMatches(eval: Evaluation, expected: []const u8) bool {
    return std.mem.eql(u8, eval.decision.toString(), expected);
}

test "evaluateCommand denies rm -rf root" {
    var eval = try evaluateCommand(std.testing.allocator, "rm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expect(eval.rule_id != null);
    try std.testing.expect(std.mem.indexOf(u8, eval.rule_id.?, "rm-rf") != null);
}

test "evaluateCommand deny carries explain metadata span regex tips and trace" {
    var eval = try evaluateCommand(std.testing.allocator, "rm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expect(eval.regex_source != null);
    try std.testing.expect(eval.regex_source.?.len > 0);
    try std.testing.expect(eval.match_start != null);
    try std.testing.expect(eval.match_end != null);
    try std.testing.expect(eval.matched_text != null);
    try std.testing.expect(eval.matched_text.?.len > 0);
    try std.testing.expect(eval.explanation != null);
    try std.testing.expect(eval.tips.len > 0);
    // Without collector, trace stays empty (hooks zero-cost path).
    try std.testing.expectEqual(@as(usize, 0), eval.trace.len);
    try std.testing.expect(eval.matched_candidate != null);
}

test "evaluateCommand with TraceCollector records nested full_evaluation step not peer matched" {
    var collector = TraceCollector.init(std.testing.allocator);
    defer collector.deinit();
    var eval = try evaluateCommand(std.testing.allocator, "rm -rf /", .{ .trace = &collector });
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expectEqual(@as(usize, 1), eval.trace.len);
    try std.testing.expectEqualStrings("full_evaluation", eval.trace[0].name);
    try std.testing.expect(eval.trace[0].detail != null);
    try std.testing.expect(std.mem.indexOf(u8, eval.trace[0].detail.?, "core.filesystem") != null);
    // No fake peer step named "matched"
    for (eval.trace) |step| {
        try std.testing.expect(!std.mem.eql(u8, step.name, "matched"));
    }
}

test "evaluateCommand with TraceCollector allow path has details child" {
    var collector = TraceCollector.init(std.testing.allocator);
    defer collector.deinit();
    var eval = try evaluateCommand(std.testing.allocator, "git status", .{ .trace = &collector });
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
    try std.testing.expectEqual(@as(usize, 1), eval.trace.len);
    try std.testing.expectEqualStrings("full_evaluation", eval.trace[0].name);
    try std.testing.expect(eval.trace[0].detail != null);
    try std.testing.expect(std.mem.indexOf(u8, eval.trace[0].detail.?, "no destructive pack matched") != null);
}

test "evaluateCommand allows git status" {
    var eval = try evaluateCommand(std.testing.allocator, "git status", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand denies git reset --hard" {
    var eval = try evaluateCommand(std.testing.allocator, "git reset --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expect(std.mem.indexOf(u8, eval.rule_id.?, "reset-hard") != null);
}

test "evaluateCommand denies compound safe then destructive" {
    var eval = try evaluateCommand(std.testing.allocator, "git status; rm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies sudo wrapper" {
    var eval = try evaluateCommand(std.testing.allocator, "sudo git reset --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies quoted subcommand git \"reset\"" {
    var eval = try evaluateCommand(std.testing.allocator, "git \"reset\" --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expect(std.mem.indexOf(u8, eval.rule_id.?, "reset-hard") != null);
}

test "evaluateCommand denies complex quoted sudo git" {
    var eval = try evaluateCommand(std.testing.allocator, "sudo \"/usr/bin/git\" \"reset\" --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
    try std.testing.expect(std.mem.indexOf(u8, eval.rule_id.?, "reset-hard") != null);
}

test "evaluateCommand denies internal backslash g\\it reset" {
    var eval = try evaluateCommand(std.testing.allocator, "g\\it reset --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies mixed quoting g'i't reset" {
    var eval = try evaluateCommand(std.testing.allocator, "g'i't reset --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies line-continued reset" {
    var eval = try evaluateCommand(std.testing.allocator, "git re\\\nset --hard", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies mkfs" {
    var eval = try evaluateCommand(std.testing.allocator, "mkfs.ext4 /dev/sda1", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand empty allows (no-op)" {
    var eval = try evaluateCommand(std.testing.allocator, "   ", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand allows git add under default packs" {
    var eval = try evaluateCommand(std.testing.allocator, "git add .", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand allows destructive text in shell comment" {
    var eval = try evaluateCommand(std.testing.allocator, "ls -la # rm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand allows echo unquoted rm -rf data" {
    var eval = try evaluateCommand(std.testing.allocator, "echo rm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand denies rm after newline following git commit -m" {
    var eval = try evaluateCommand(std.testing.allocator, "git commit -m\nrm -rf /", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies multi-arg rm with sensitive target" {
    var eval = try evaluateCommand(std.testing.allocator, "rm -rf /tmp/safe /etc/passwd", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies cat heredoc with backslash-escaped delimiter" {
    const cmd =
        \\
        \\cat <<\EOF
        \\rm -rf /
        \\EOF
        \\
    ;
    var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies attached redirection git>/dev/null reset" {
    const cases = [_][]const u8{
        "\"git\">/dev/null reset --hard",
        "\"git\"&>/dev/null reset --hard",
        "\"git\"&>>/dev/null reset --hard",
        "git>/dev/null reset --hard",
        "git>>/dev/null reset --hard",
        "git&>/dev/null reset --hard",
        "git&>>/dev/null reset --hard",
        "git >/dev/null reset --hard",
        "command >>/dev/null git reset --hard",
    };
    for (cases) |cmd| {
        var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
    }
}

test "evaluateCommand allows command builtin pure append redirect" {
    var eval = try evaluateCommand(std.testing.allocator, "command >> /usr/local/log", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand denies python.exe -c shutil.rmtree" {
    const cases = [_][]const u8{
        "python.exe -c \"import shutil; shutil.rmtree('/')\"",
        "python3.11.exe -c \"import shutil; shutil.rmtree('/')\"",
        "python3.exe -c \"import shutil; shutil.rmtree('/tmp/x')\"",
    };
    for (cases) |cmd| {
        var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
    }
}

test "evaluateCommand denies data-only pipe to shell interpreter" {
    const cases = [_][]const u8{
        "echo 'rm -rf /' | bash",
        "echo 'rm -rf /' | bash -s",
        "printf 'rm -rf /\\n' | sh",
        "echo \"rm -rf /\" | zsh",
        "echo 'rm -rf /' | /bin/bash",
        "echo 'rm -rf /' | cat | bash",
    };
    for (cases) |cmd| {
        var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
    }
}

test "evaluateCommand still allows echo data without pipe to shell" {
    var eval = try evaluateCommand(std.testing.allocator, "echo 'rm -rf /'", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand allows harmless pipe to shell" {
    var eval = try evaluateCommand(std.testing.allocator, "echo hello | bash", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand denies git add with full packs" {
    var eval = try evaluateCommand(std.testing.allocator, "git add .", .{ .default_packs_only = false });
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies cross-pack safe plus destructive" {
    var eval = try evaluateCommand(std.testing.allocator, "rm -rf / $(git checkout -b x)", .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .deny);
}

test "evaluateCommand denies echo payload piped to shell" {
    const cases = [_][]const u8{
        "echo rm -rf / | sh",
        "echo 'rm -rf /' | bash",
        "printf 'rm -rf /' | /bin/sh",
    };
    for (cases) |cmd| {
        var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
    }
}

test "evaluateCommand denies attached heredoc on qualified shell" {
    const cases = [_][]const u8{
        "/bin/bash<<'EOF'\nrm -rf /\nEOF",
        "/bin/sh<<EOF\nrm -rf /\nEOF",
        "bash<<EOF\ngit reset --hard\nEOF",
        // Options before redirect: argv0 is bash, not -s.
        "bash -s <<'EOF'\nrm -rf /\nEOF",
        "/bin/bash -s <<EOF\nrm -rf /\nEOF",
        "sudo bash -s <<'EOF'\ngit reset --hard\nEOF",
    };
    for (cases) |cmd| {
        var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
    }
}

test "evaluateCommand still allows cat attached heredoc data" {
    const cmd = "cat<<EOF\nrm -rf /\nEOF";
    var eval = try evaluateCommand(std.testing.allocator, cmd, .{});
    defer eval.deinit(std.testing.allocator);
    try std.testing.expect(eval.decision == .allow);
}

test "evaluateCommand opt-in pack denies docker prune" {
    var allow_baseline = try evaluateCommand(std.testing.allocator, "docker system prune", .{});
    defer allow_baseline.deinit(std.testing.allocator);
    try std.testing.expect(allow_baseline.decision == .allow);

    var deny_opt_in = try evaluateCommand(std.testing.allocator, "docker system prune", .{
        .extra_enabled = &.{"containers.docker"},
    });
    defer deny_opt_in.deinit(std.testing.allocator);
    try std.testing.expect(deny_opt_in.decision == .deny);
    try std.testing.expect(deny_opt_in.pack_id != null);
    try std.testing.expectEqualStrings("containers.docker", deny_opt_in.pack_id.?);
}

// Phase 1 WP2 — structure smart checks on Mode A (default packs).
// Executed compounds/wrappers/embeds deny; assignment/quote data-only allows.
// Deny rows pin pack-qualified rule_id (mvp_corpus attribution).
test "phase1 structure smart checks Mode A" {
    const Case = struct {
        cmd: []const u8,
        expect_deny: bool,
        /// Pack-qualified rule_id when expect_deny (mvp_corpus form).
        rule_id: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .cmd = "git status; rm -rf /", .expect_deny = true, .rule_id = "core.filesystem:rm-rf-root-home" },
        .{ .cmd = "sudo git reset --hard", .expect_deny = true, .rule_id = "core.git:reset-hard" },
        .{ .cmd = "VAR='rm -rf /'; echo \"$VAR\"", .expect_deny = false },
        .{ .cmd = "echo 'rm -rf /'", .expect_deny = false },
        .{ .cmd = "bash -c 'rm -rf /'", .expect_deny = true, .rule_id = "core.filesystem:rm-rf-root-home" },
    };
    for (cases) |c| {
        var eval = try evaluateCommand(std.testing.allocator, c.cmd, .{});
        defer eval.deinit(std.testing.allocator);
        if (c.expect_deny) {
            try std.testing.expect(eval.decision == .deny);
            try std.testing.expect(eval.rule_id != null);
            if (c.rule_id) |want| {
                try std.testing.expectEqualStrings(want, eval.rule_id.?);
            }
        } else {
            try std.testing.expect(eval.decision == .allow);
        }
    }
}

// Phase 1 WP3 — hard-fence catastrophe table (Mode A): deny + pack-qualified rule_id.
test "phase1 hard-fence catastrophe table Mode A" {
    const Case = struct {
        cmd: []const u8,
        /// Full pack:pattern rule_id (mvp_corpus).
        rule_id: []const u8,
    };
    const cases = [_]Case{
        .{ .cmd = "rm -rf /", .rule_id = "core.filesystem:rm-rf-root-home" },
        .{ .cmd = "rm -rf ~", .rule_id = "core.filesystem:rm-rf-root-home" },
        .{ .cmd = "git reset --hard", .rule_id = "core.git:reset-hard" },
        .{ .cmd = "git push --force origin main", .rule_id = "core.git:push-force-long" },
        .{ .cmd = "mkfs.ext4 /dev/sda1", .rule_id = "system.disk:mkfs" },
        .{ .cmd = "dd if=/dev/zero of=/dev/sda", .rule_id = "system.disk:dd-device" },
    };
    for (cases) |c| {
        var eval = try evaluateCommand(std.testing.allocator, c.cmd, .{});
        defer eval.deinit(std.testing.allocator);
        try std.testing.expect(eval.decision == .deny);
        try std.testing.expect(eval.rule_id != null);
        try std.testing.expectEqualStrings(c.rule_id, eval.rule_id.?);
    }
}

test {
    _ = allowlist;
    _ = registry;
    _ = segments;
    _ = normalize;
    _ = sanitize;
    _ = @import("corpus_test.zig");
    _ = @import("regex_pcre.zig");
    _ = @import("suggestions.zig");
}
