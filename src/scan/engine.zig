//! Orchestrate discovery → extract → danger/secrets → rank → result.
const std = @import("std");
const types = @import("types.zig");
const time_window = @import("time_window.zig");
const discover = @import("discover.zig");
const jsonl = @import("jsonl.zig");
const danger = @import("danger.zig");
const secrets = @import("secrets.zig");
const rank = @import("rank.zig");

/// Optional host-level progress for TTY spinners (scan is otherwise silent).
pub const ProgressPhase = enum { host_start, host_done };
pub const ProgressFn = *const fn (ctx: ?*anyopaque, host: types.Host, phase: ProgressPhase, sessions: usize) void;

pub const ScanOptions = struct {
    home: []const u8,
    xdg_data_home: ?[]const u8 = null,
    days: ?u32 = null,
    all_time: bool = false,
    show_all: bool = false,
    only_host: ?types.Host = null,
    now_secs: ?i64 = null,
    list_cap: usize = types.default_list_cap,
    progress: ?ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

pub fn runScan(io: std.Io, allocator: std.mem.Allocator, options: ScanOptions) !types.ScanResult {
    const now = options.now_secs orelse std.Io.Timestamp.now(io, .real).toSeconds();
    const window = time_window.resolveWindow(now, options.days, options.all_time);

    var scorecard: types.Scorecard = .{
        .window_days = window.days,
        .all_time = window.all_time,
    };

    const hosts = try discover.discoverAll(io, allocator, .{
        .home = options.home,
        .xdg_data_home = options.xdg_data_home,
        .window = window,
        .only_host = options.only_host,
    });
    defer discover.freeDiscoveries(allocator, hosts);

    var findings: std.ArrayList(types.Finding) = .empty;
    errdefer {
        for (findings.items) |*f| f.deinit(allocator);
        findings.deinit(allocator);
    }

    for (hosts) |h| {
        if (options.progress) |pf| pf(options.progress_ctx, h.host, .host_start, 0);
        scorecard.setHost(h.host, h.status, h.files.items.len, h.note);
        for (h.files.items) |file| {
            scorecard.sessions_scanned += 1;
            var parsed = jsonl.parseJsonlFile(io, allocator, file.path, file.mtime_secs) catch continue;
            defer parsed.deinit(allocator);

            // Prefer JSON timestamp if newer window check needed — already filtered by mtime.
            // Prefer content timestamp when present; drop out-of-window sessions.
            const ts = if (parsed.timestamp_secs != 0) parsed.timestamp_secs else file.mtime_secs;
            if (!time_window.inWindow(ts, window)) continue;

            for (parsed.commands.items) |cmd| {
                try processCommand(allocator, &findings, &scorecard, h.host, file.session_id, file.path, ts, cmd);
            }
            // Dedup material by fingerprint/label within this session file.
            var seen_material: std.ArrayList([]const u8) = .empty;
            defer {
                for (seen_material.items) |s| allocator.free(s);
                seen_material.deinit(allocator);
            }
            for (parsed.text_blobs.items) |blob| {
                try processMaterialDedup(allocator, &findings, &scorecard, &seen_material, h.host, file.session_id, file.path, ts, blob);
            }
        }
        if (options.progress) |pf| pf(options.progress_ctx, h.host, .host_done, h.files.items.len);
    }

    rank.sortFindings(findings.items);
    // Collapse repeated secret fingerprints so the list is scannable (scorecard
    // still reflects raw material_count from discovery).
    rank.collapseSecretFingerprints(allocator, &findings);
    const total = findings.items.len;
    const shown_slice = rank.applyCap(findings.items, options.show_all, options.list_cap);

    // Shrink list to shown when capped (free the tail).
    if (shown_slice.len < findings.items.len) {
        var i = shown_slice.len;
        while (i < findings.items.len) : (i += 1) {
            findings.items[i].deinit(allocator);
        }
        findings.shrinkRetainingCapacity(shown_slice.len);
    }

    const owned = try findings.toOwnedSlice(allocator);
    return .{
        .scorecard = scorecard,
        .findings = owned,
        .total_findings = total,
        .shown_cap = if (options.show_all) total else options.list_cap,
        .allocator = allocator,
    };
}

fn processCommand(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(types.Finding),
    scorecard: *types.Scorecard,
    host: types.Host,
    session_id: []const u8,
    path: []const u8,
    ts: i64,
    cmd: []const u8,
) !void {
    // secret_access first — may dual-tag with danger; prefer secret_access only for secret paths.
    if (secrets.isSecretAccessCommand(cmd)) {
        const detail = try secrets.safeDetail(allocator, cmd);
        errdefer allocator.free(detail);
        const title = try allocator.dupe(u8, "Secret-access command");
        errdefer allocator.free(title);
        try pushFinding(allocator, findings, .{
            .kind = .secret_access,
            .severity = .high,
            .host = host,
            .session_id = session_id,
            .path = path,
            .timestamp_secs = ts,
            .title = title,
            .detail = detail,
            .evidence_ref = path,
        });
        scorecard.secret_access_count += 1;
        return; // prefer secret_access over generic danger for same command
    }

    if (try danger.evaluateDanger(allocator, cmd)) |hit_const| {
        var hit = hit_const;
        defer hit.deinit(allocator);
        const detail = try secrets.safeDetail(allocator, cmd);
        errdefer allocator.free(detail);
        const title = try std.fmt.allocPrint(allocator, "Dangerous command ({s})", .{hit.severity.toString()});
        errdefer allocator.free(title);
        try pushFinding(allocator, findings, .{
            .kind = .danger,
            .severity = hit.severity,
            .host = host,
            .session_id = session_id,
            .path = path,
            .timestamp_secs = ts,
            .title = title,
            .detail = detail,
            .evidence_ref = path,
        });
        scorecard.danger_count += 1;
    }
}

fn processMaterialDedup(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(types.Finding),
    scorecard: *types.Scorecard,
    seen: *std.ArrayList([]const u8),
    host: types.Host,
    session_id: []const u8,
    path: []const u8,
    ts: i64,
    blob: []const u8,
) !void {
    const hit_opt = try secrets.classifyMaterial(allocator, blob);
    const hit = hit_opt orelse return;
    var material = hit;
    defer material.deinit(allocator);

    const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ material.label, material.fingerprint_hex });
    for (seen.items) |s| {
        if (std.mem.eql(u8, s, key)) {
            allocator.free(key);
            return;
        }
    }
    seen.append(allocator, key) catch |err| {
        allocator.free(key);
        return err;
    };

    // Title/detail stay free of nested REDACTED blobs — present layer maps label.
    const title = try allocator.dupe(u8, "Secret-like value in session");
    errdefer allocator.free(title);
    const detail = try allocator.dupe(u8, "Value hidden");
    errdefer allocator.free(detail);
    const label = try allocator.dupe(u8, material.label);
    errdefer allocator.free(label);
    const fp = try allocator.dupe(u8, material.fingerprint_hex);
    errdefer allocator.free(fp);

    try pushFinding(allocator, findings, .{
        .kind = .secret_material,
        .severity = .high,
        .host = host,
        .session_id = session_id,
        .path = path,
        .timestamp_secs = ts,
        .title = title,
        .detail = detail,
        .secret_label = label,
        .secret_fingerprint = fp,
        .evidence_ref = path,
    });
    scorecard.secret_material_count += 1;
}

const FindingSeed = struct {
    kind: types.FindingKind,
    severity: types.Severity,
    host: types.Host,
    session_id: []const u8,
    path: []const u8,
    timestamp_secs: i64,
    title: []u8,
    detail: []u8,
    secret_label: ?[]u8 = null,
    secret_fingerprint: ?[]u8 = null,
    evidence_ref: []const u8,
};

fn pushFinding(allocator: std.mem.Allocator, findings: *std.ArrayList(types.Finding), seed: FindingSeed) !void {
    const session_id = try allocator.dupe(u8, seed.session_id);
    errdefer allocator.free(session_id);
    const path = try allocator.dupe(u8, seed.path);
    errdefer allocator.free(path);
    const evidence = try allocator.dupe(u8, seed.evidence_ref);
    errdefer allocator.free(evidence);

    try findings.append(allocator, .{
        .kind = seed.kind,
        .severity = seed.severity,
        .host = seed.host,
        .session_id = session_id,
        .path = path,
        .timestamp_secs = seed.timestamp_secs,
        .title = seed.title,
        .detail = seed.detail,
        .secret_label = seed.secret_label,
        .secret_fingerprint = seed.secret_fingerprint,
        .evidence_ref = evidence,
    });
}

test "engine empty home produces empty scorecard exit-success path data" {
    const io = std.testing.io;
    const home = try std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp-scan-engine-empty-{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer std.testing.allocator.free(home);
    try std.Io.Dir.cwd().createDirPath(io, home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var result = try runScan(io, std.testing.allocator, .{ .home = home });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
    try std.testing.expectEqual(@as(usize, 0), result.total_findings);
    try std.testing.expectEqual(@as(usize, 0), result.scorecard.sessions_scanned);
}

test "engine claude fixture yields danger and redacted secret_material" {
    const io = std.testing.io;
    const home = try std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp-scan-engine-claude-{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer std.testing.allocator.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const proj = try std.fs.path.join(std.testing.allocator, &.{ home, ".claude", "projects", "demo" });
    defer std.testing.allocator.free(proj);
    try std.Io.Dir.cwd().createDirPath(io, proj);
    const sess = try std.fs.path.join(std.testing.allocator, &.{ proj, "sess1.jsonl" });
    defer std.testing.allocator.free(sess);

    // Include high danger + secret material + secret access + low-noise allow.
    const body =
        \\{"type":"assistant","timestamp":"2026-07-28T12:00:00Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf /"}}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat .env"}}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
        \\{"type":"user","message":{"content":[{"type":"text","text":"deploy key ghp_fakeSyntheticTokenValue1234567890abcd"}]}}
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sess, .data = body });

    var result = try runScan(io, std.testing.allocator, .{
        .home = home,
        .all_time = true,
        .only_host = .claude,
    });
    defer result.deinit();

    try std.testing.expect(result.total_findings >= 2);

    var saw_danger = false;
    var saw_access = false;
    var saw_material = false;
    for (result.findings) |f| {
        try std.testing.expect(std.mem.indexOf(u8, f.detail, "ghp_fake") == null);
        try std.testing.expect(std.mem.indexOf(u8, f.title, "ghp_fake") == null);
        switch (f.kind) {
            .danger => saw_danger = true,
            .secret_access => saw_access = true,
            .secret_material => saw_material = true,
        }
    }
    try std.testing.expect(saw_danger);
    try std.testing.expect(saw_access);
    try std.testing.expect(saw_material);

    // git status must not appear as danger
    for (result.findings) |f| {
        if (f.kind == .danger) {
            try std.testing.expect(std.mem.indexOf(u8, f.detail, "git status") == null);
        }
    }
}
