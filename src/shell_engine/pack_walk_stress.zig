//! Evaluation-only destructive pack walk stress (not a product surface).
//!
//! When env `DCG_PACK_WALK_CANDIDATES` points at a JSONL of
//! `{pack_id,pattern_name,severity,candidates:[]}` and `DCG_PACK_WALK_OUT`
//! at an output path, the test walks every destructive rule, evaluates each
//! candidate via `evaluateCommand` (default packs + full packs), and writes
//! machine-readable JSONL. Safe: no process spawn of candidate commands.
//!
//! Skip when env is unset so normal `test-shell-engine` is unaffected.

const std = @import("std");
const shell_engine = @import("mod.zig");
const regex_pcre = @import("regex_pcre.zig");

const CandidateRow = struct {
    pack_id: []const u8,
    pattern_name: []const u8,
    severity: []const u8,
    candidates: []const []const u8,
};

test "dcg pack walk stress evaluateCommand matrix" {
    const cand_path_c = std.c.getenv("DCG_PACK_WALK_CANDIDATES") orelse return error.SkipZigTest;
    const out_path_c = std.c.getenv("DCG_PACK_WALK_OUT") orelse return error.SkipZigTest;
    const cand_path = std.mem.span(cand_path_c);
    const out_path = std.mem.span(out_path_c);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const io = std.testing.io;

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, cand_path, gpa, .limited(32 * 1024 * 1024));
    defer gpa.free(raw);

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var total: usize = 0;
    var synth_fail: usize = 0;
    var full_deny: usize = 0;
    var full_allow: usize = 0;
    var default_deny: usize = 0;
    var default_allow: usize = 0;
    var enablement_gap: usize = 0;
    var wrong_rule: usize = 0;
    var crashes: usize = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
            crashes += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            crashes += 1;
            continue;
        }
        const obj = parsed.value.object;
        // Fail closed on malformed rows — never force-unwrap past crash accounting (F218).
        const pack_id_v = obj.get("pack_id") orelse {
            crashes += 1;
            continue;
        };
        const pattern_name_v = obj.get("pattern_name") orelse {
            crashes += 1;
            continue;
        };
        const severity_v = obj.get("severity") orelse {
            crashes += 1;
            continue;
        };
        const cands_v = obj.get("candidates") orelse {
            crashes += 1;
            continue;
        };
        if (pack_id_v != .string or pattern_name_v != .string or severity_v != .string or cands_v != .array) {
            crashes += 1;
            continue;
        }
        const pack_id = pack_id_v.string;
        const pattern_name = pattern_name_v.string;
        const severity = severity_v.string;
        const regex_src = if (obj.get("regex")) |r| (if (r == .string) r.string else "") else "";
        const cands_val = cands_v.array;

        // Validate which candidate actually matches the pack regex (PCRE2).
        var chosen: ?[]const u8 = null;
        var re_opt: ?regex_pcre.Regex = null;
        if (regex_src.len > 0) {
            re_opt = regex_pcre.Regex.compile(regex_src) catch null;
        }
        defer if (re_opt) |*r| r.deinit();

        if (re_opt) |*re| {
            for (cands_val.items) |c| {
                const cmd = c.string;
                const matched = re.isMatch(cmd) catch false;
                if (matched) {
                    chosen = cmd;
                    break;
                }
            }
        } else if (cands_val.items.len > 0) {
            chosen = cands_val.items[0].string;
        }

        total += 1;
        if (chosen == null) {
            synth_fail += 1;
            try writeRow(&out_writer.interface, .{
                .pack_id = pack_id,
                .pattern_name = pattern_name,
                .severity = severity,
                .command = "",
                .default_packs_only = true,
                .decision = "synth_fail",
                .rule_id = null,
                .hit_pack = null,
                .hit_pattern = null,
                .note = "no_candidate_matched_regex",
            });
            try writeRow(&out_writer.interface, .{
                .pack_id = pack_id,
                .pattern_name = pattern_name,
                .severity = severity,
                .command = "",
                .default_packs_only = false,
                .decision = "synth_fail",
                .rule_id = null,
                .hit_pack = null,
                .hit_pattern = null,
                .note = "no_candidate_matched_regex",
            });
            continue;
        }
        const command = chosen.?;

        // Full packs first (source of truth for pack intent).
        const full = evaluateOne(gpa, command, false) catch {
            crashes += 1;
            try writeRow(&out_writer.interface, .{
                .pack_id = pack_id,
                .pattern_name = pattern_name,
                .severity = severity,
                .command = command,
                .default_packs_only = false,
                .decision = "error",
                .rule_id = null,
                .hit_pack = null,
                .hit_pattern = null,
                .note = "evaluate_error",
            });
            continue;
        };
        defer freeEval(gpa, full);

        const def = evaluateOne(gpa, command, true) catch {
            crashes += 1;
            try writeRow(&out_writer.interface, .{
                .pack_id = pack_id,
                .pattern_name = pattern_name,
                .severity = severity,
                .command = command,
                .default_packs_only = true,
                .decision = "error",
                .rule_id = null,
                .hit_pack = null,
                .hit_pattern = null,
                .note = "evaluate_error",
            });
            continue;
        };
        defer freeEval(gpa, def);

        if (full.decision == .deny) full_deny += 1 else full_allow += 1;
        if (def.decision == .deny) default_deny += 1 else default_allow += 1;

        var full_note: []const u8 = "ok";
        if (full.decision != .deny) {
            full_note = "full_pack_allow_false_allow";
        } else if (full.pack_id) |hp| {
            if (!std.mem.eql(u8, hp, pack_id)) {
                full_note = "denied_other_pack";
                wrong_rule += 1;
            } else if (full.pattern_name) |pn| {
                if (!std.mem.eql(u8, pn, pattern_name)) {
                    full_note = "denied_other_pattern_same_pack";
                    wrong_rule += 1;
                }
            }
        }

        var def_note: []const u8 = "ok";
        if (def.decision == .allow and full.decision == .deny) {
            def_note = "enablement_gap_default_allows_full_denies";
            enablement_gap += 1;
        } else if (def.decision != .deny and isDefaultPack(pack_id)) {
            def_note = "default_pack_allow_false_allow";
        }

        try writeRow(&out_writer.interface, .{
            .pack_id = pack_id,
            .pattern_name = pattern_name,
            .severity = severity,
            .command = command,
            .default_packs_only = false,
            .decision = decisionStr(full.decision),
            .rule_id = full.rule_id,
            .hit_pack = full.pack_id,
            .hit_pattern = full.pattern_name,
            .note = full_note,
        });
        try writeRow(&out_writer.interface, .{
            .pack_id = pack_id,
            .pattern_name = pattern_name,
            .severity = severity,
            .command = command,
            .default_packs_only = true,
            .decision = decisionStr(def.decision),
            .rule_id = def.rule_id,
            .hit_pack = def.pack_id,
            .hit_pattern = def.pattern_name,
            .note = def_note,
        });
    }

    try out_writer.interface.flush();

    // Summary line to stderr for the log.
    std.debug.print(
        "dcg-pack-walk: total={d} synth_fail={d} full_deny={d} full_allow={d} default_deny={d} default_allow={d} enablement_gap={d} wrong_rule={d} crashes={d}\n",
        .{ total, synth_fail, full_deny, full_allow, default_deny, default_allow, enablement_gap, wrong_rule, crashes },
    );

    // Hard asserts: no evaluate crashes; every row produced a decision or synth_fail.
    try std.testing.expectEqual(@as(usize, 0), crashes);
    try std.testing.expect(total > 0);
}

const EvalSnap = struct {
    decision: shell_engine.Decision,
    rule_id: ?[]const u8,
    pack_id: ?[]const u8,
    pattern_name: ?[]const u8,
};

fn evaluateOne(allocator: std.mem.Allocator, command: []const u8, default_packs_only: bool) !EvalSnap {
    var eval = try shell_engine.evaluateCommand(allocator, command, .{
        .default_packs_only = default_packs_only,
        // No permanent/allow-once — pure pack path.
    });
    defer eval.deinit(allocator);
    const rule_id = if (eval.rule_id) |s| try allocator.dupe(u8, s) else null;
    errdefer if (rule_id) |s| allocator.free(s);
    const pack_id = if (eval.pack_id) |s| try allocator.dupe(u8, s) else null;
    errdefer if (pack_id) |s| allocator.free(s);
    const pattern_name = if (eval.pattern_name) |s| try allocator.dupe(u8, s) else null;
    return .{
        .decision = eval.decision,
        .rule_id = rule_id,
        .pack_id = pack_id,
        .pattern_name = pattern_name,
    };
}

fn freeEval(allocator: std.mem.Allocator, snap: EvalSnap) void {
    if (snap.rule_id) |s| allocator.free(s);
    if (snap.pack_id) |s| allocator.free(s);
    if (snap.pattern_name) |s| allocator.free(s);
}

fn decisionStr(d: shell_engine.Decision) []const u8 {
    return switch (d) {
        .allow => "allow",
        .deny => "deny",
    };
}

fn isDefaultPack(pack_id: []const u8) bool {
    if (std.mem.startsWith(u8, pack_id, "core.")) return true;
    if (std.mem.eql(u8, pack_id, "system.disk")) return true;
    return false;
}

const Row = struct {
    pack_id: []const u8,
    pattern_name: []const u8,
    severity: []const u8,
    command: []const u8,
    default_packs_only: bool,
    decision: []const u8,
    rule_id: ?[]const u8,
    hit_pack: ?[]const u8,
    hit_pattern: ?[]const u8,
    note: []const u8,
};

fn writeRow(w: *std.Io.Writer, row: Row) !void {
    // Manual JSON to avoid allocator churn / escaping issues on commands.
    try w.writeAll("{\"pack_id\":");
    try writeJsonString(w, row.pack_id);
    try w.writeAll(",\"pattern_name\":");
    try writeJsonString(w, row.pattern_name);
    try w.writeAll(",\"severity\":");
    try writeJsonString(w, row.severity);
    try w.writeAll(",\"command\":");
    try writeJsonString(w, row.command);
    try w.writeAll(",\"default_packs_only\":");
    try w.writeAll(if (row.default_packs_only) "true" else "false");
    try w.writeAll(",\"decision\":");
    try writeJsonString(w, row.decision);
    try w.writeAll(",\"rule_id\":");
    if (row.rule_id) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"hit_pack\":");
    if (row.hit_pack) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"hit_pattern\":");
    if (row.hit_pattern) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"note\":");
    try writeJsonString(w, row.note);
    try w.writeAll("}\n");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
