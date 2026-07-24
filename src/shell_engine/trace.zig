//! Opt-in evaluation trace collector for `ryk explain`.
//!
//! Mirrors DCG's TraceCollector model: real timings + typed step details.
//! Pass `?*TraceCollector` into evaluateCommand; hooks/run leave it null
//! so the hot path pays nothing.

const std = @import("std");
const types = @import("types.zig");

pub const Decision = types.Decision;

/// Typed details for a pipeline stage (DCG TraceDetails subset mapped to ryk).
pub const TraceDetails = union(enum) {
    /// Outer full evaluation outcome (pack scan / keyword-shaped summary).
    pack_evaluation: struct {
        matched_pack: ?[]const u8 = null,
        matched_pattern: ?[]const u8 = null,
        packs_scanned: usize = 0,
    },
    /// Candidate prep (segments / embeds / heredoc mask).
    candidate_prep: struct {
        candidates: usize = 0,
        embeds: usize = 0,
        heredoc_masked: bool = false,
    },
    /// Allowlist short-circuit.
    allowlist: struct {
        matched: bool = false,
    },
    /// Generic message (static preferred).
    message: []const u8,
};

/// One timed pipeline step. `name` is typically a static string.
/// `detail` is the nested details summary child (owned when taken from collector).
pub const TraceStep = struct {
    name: []const u8,
    duration_us: u64 = 0,
    /// Nested details summary for this step (DCG nest rule child).
    detail: ?[]const u8 = null,
};

/// Match information for the sibling Match section (not a pipeline step).
pub const MatchInfo = struct {
    rule_id: ?[]const u8 = null,
    pack_id: ?[]const u8 = null,
    pattern_name: ?[]const u8 = null,
    severity: ?types.Severity = null,
    reason: []const u8 = "",
    match_start: ?usize = null,
    match_end: ?usize = null,
    matched_text_preview: ?[]const u8 = null,
    explanation: ?[]const u8 = null,
};

/// Finished explain payload (optional; Evaluation remains the CLI surface).
pub const ExplainTrace = struct {
    decision: Decision,
    total_duration_us: u64,
    steps: []TraceStep,
    match_info: ?MatchInfo = null,
    /// When true, free steps slice and each owned detail.
    owned: bool = false,

    pub fn deinit(self: *ExplainTrace, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.steps) |step| {
            if (step.detail) |d| allocator.free(d);
        }
        if (self.steps.len > 0) allocator.free(self.steps);
        self.* = undefined;
    }
};

/// Opt-in collector. Create for `ryk explain`; leave null on hooks/run.
pub const TraceCollector = struct {
    allocator: std.mem.Allocator,
    start_us: u64,
    step_start_us: u64,
    steps: std.ArrayList(TraceStep),
    match_info: ?MatchInfo = null,

    pub fn init(allocator: std.mem.Allocator) TraceCollector {
        const now = monotonicUs();
        return .{
            .allocator = allocator,
            .start_us = now,
            .step_start_us = now,
            .steps = .empty,
            .match_info = null,
        };
    }

    pub fn deinit(self: *TraceCollector) void {
        for (self.steps.items) |step| {
            if (step.detail) |d| self.allocator.free(d);
        }
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginStep(self: *TraceCollector) void {
        self.step_start_us = monotonicUs();
    }

    /// End the current step, owning a details summary string when needed.
    pub fn endStep(self: *TraceCollector, name: []const u8, details: TraceDetails) !void {
        const now = monotonicUs();
        const duration_us = if (now > self.step_start_us) now - self.step_start_us else 0;
        const summary = try detailsSummaryAlloc(self.allocator, details);
        errdefer if (summary) |s| self.allocator.free(s);
        try self.steps.append(self.allocator, .{
            .name = name,
            .duration_us = duration_us,
            .detail = summary,
        });
    }

    pub fn recordStep(self: *TraceCollector, name: []const u8, duration_us: u64, details: TraceDetails) !void {
        const summary = try detailsSummaryAlloc(self.allocator, details);
        errdefer if (summary) |s| self.allocator.free(s);
        try self.steps.append(self.allocator, .{
            .name = name,
            .duration_us = duration_us,
            .detail = summary,
        });
    }

    pub fn setMatch(self: *TraceCollector, info: MatchInfo) void {
        self.match_info = info;
    }

    /// Transfer owned steps into a heap slice for Evaluation (empties collector steps).
    pub fn takeSteps(self: *TraceCollector) ![]TraceStep {
        const out = try self.steps.toOwnedSlice(self.allocator);
        self.steps = .empty;
        return out;
    }

    pub fn finish(self: *TraceCollector, decision: Decision) !ExplainTrace {
        const total = if (monotonicUs() > self.start_us) monotonicUs() - self.start_us else 0;
        const steps = try self.takeSteps();
        return .{
            .decision = decision,
            .total_duration_us = total,
            .steps = steps,
            .match_info = self.match_info,
            .owned = true,
        };
    }

    pub fn totalDurationUs(self: *const TraceCollector) u64 {
        const now = monotonicUs();
        if (now <= self.start_us) return 0;
        return now - self.start_us;
    }
};

/// Format duration for display (DCG-style, ms with 2 decimals when ≥1ms).
pub fn formatDurationMs(us: u64, buf: []u8) []const u8 {
    if (us == 0) return "0ms";
    if (us < 1000) {
        return std.fmt.bufPrint(buf, "{d}us", .{us}) catch "0us";
    }
    // hundredths of a millisecond
    const whole_ms = us / 1000;
    const frac = (us % 1000) / 10;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}ms", .{ whole_ms, frac }) catch "0ms";
}

/// Static / stack-friendly summary when allocation is not needed.
pub fn detailsSummaryStatic(details: TraceDetails) []const u8 {
    return switch (details) {
        .message => |m| m,
        .allowlist => |a| if (a.matched) "matched" else "no match",
        .candidate_prep => "candidate prep",
        .pack_evaluation => |p| if (p.matched_pack != null)
            "matched pack"
        else
            "no destructive pack matched",
    };
}

fn detailsSummaryAlloc(allocator: std.mem.Allocator, details: TraceDetails) !?[]const u8 {
    return switch (details) {
        .message => |m| try allocator.dupe(u8, m),
        .allowlist => |a| try allocator.dupe(u8, if (a.matched) "matched" else "no match"),
        .candidate_prep => |c| try std.fmt.allocPrint(
            allocator,
            "candidates={d}, embeds={d}, heredoc_masked={s}",
            .{ c.candidates, c.embeds, if (c.heredoc_masked) "true" else "false" },
        ),
        .pack_evaluation => |p| blk: {
            if (p.matched_pack) |pack| {
                if (p.matched_pattern) |pat| {
                    break :blk try std.fmt.allocPrint(allocator, "matched: {s} ({s})", .{ pack, pat });
                }
                break :blk try std.fmt.allocPrint(allocator, "matched: {s}", .{pack});
            }
            if (p.packs_scanned > 0) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "no destructive pack matched ({d} packs scanned)",
                    .{p.packs_scanned},
                );
            }
            break :blk try allocator.dupe(u8, "no destructive pack matched");
        },
    };
}

pub fn monotonicUs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000 +
        @divTrunc(@as(u64, @intCast(ts.nsec)), 1000);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "TraceCollector begin/end records duration and detail; deinit leak-clean" {
    var collector = TraceCollector.init(std.testing.allocator);
    defer collector.deinit();

    collector.beginStep();
    try collector.endStep("full_evaluation", .{
        .pack_evaluation = .{
            .matched_pack = "core.filesystem",
            .matched_pattern = "rm-rf-general",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), collector.steps.items.len);
    try std.testing.expectEqualStrings("full_evaluation", collector.steps.items[0].name);
    try std.testing.expect(collector.steps.items[0].detail != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.steps.items[0].detail.?, "core.filesystem") != null);
    // duration may be 0 on very fast clocks; just ensure field is settable
    _ = collector.steps.items[0].duration_us;
}

test "TraceCollector takeSteps transfers ownership leak-clean" {
    var collector = TraceCollector.init(std.testing.allocator);
    defer collector.deinit();

    try collector.recordStep("full_evaluation", 1500, .{
        .message = "no destructive pack matched",
    });
    const steps = try collector.takeSteps();
    defer {
        for (steps) |s| if (s.detail) |d| std.testing.allocator.free(d);
        std.testing.allocator.free(steps);
    }
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqual(@as(u64, 1500), steps[0].duration_us);
    try std.testing.expectEqual(@as(usize, 0), collector.steps.items.len);
}

test "TraceCollector finish produces owned ExplainTrace" {
    var collector = TraceCollector.init(std.testing.allocator);
    defer collector.deinit();
    collector.beginStep();
    try collector.endStep("full_evaluation", .{ .message = "ok" });
    var finished = try collector.finish(.allow);
    defer finished.deinit(std.testing.allocator);
    try std.testing.expect(finished.decision == .allow);
    try std.testing.expectEqual(@as(usize, 1), finished.steps.len);
    try std.testing.expect(finished.owned);
}

test "formatDurationMs formats micros and millis" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0ms", formatDurationMs(0, &buf));
    const us = formatDurationMs(42, &buf);
    try std.testing.expect(std.mem.indexOf(u8, us, "us") != null or std.mem.indexOf(u8, us, "ms") != null);
    const ms = formatDurationMs(20_000, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ms, "ms") != null);
}

test "detailsSummaryAlloc pack match and miss" {
    const match = try detailsSummaryAlloc(std.testing.allocator, .{
        .pack_evaluation = .{ .matched_pack = "core.git", .matched_pattern = "reset-hard" },
    });
    defer if (match) |s| std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, match.?, "core.git") != null);

    const miss = try detailsSummaryAlloc(std.testing.allocator, .{
        .pack_evaluation = .{ .packs_scanned = 3 },
    });
    defer if (miss) |s| std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, miss.?, "no destructive pack matched") != null);
}
