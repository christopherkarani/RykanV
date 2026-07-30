//! OpenCode SQLite session store reader (read-only via system `sqlite3` CLI).
//!
//! Opens `$XDG_DATA_HOME/opencode/opencode.db` (or `~/.local/share/opencode/opencode.db`)
//! with URI `mode=ro` only. Never writes, never deletes WAL/SHM, never mines auth tables.
const std = @import("std");
const types = @import("types.zig");
const time_window = @import("time_window.zig");
const extract = @import("extract.zig");
const jsonl = @import("jsonl.zig");

/// Cap part rows loaded per session (real DBs can have tens of thousands of parts).
/// Kept low enough that max_parts * max_data_bytes stays under max_query_stdout_bytes.
pub const max_parts_per_session: usize = 200;
/// Cap message rows loaded per session for text/secret scanning.
pub const max_messages_per_session: usize = 100;
/// Max bytes of a single `data` JSON field accepted into memory / SQL substr.
/// 16 KiB × 200 parts ≈ 3.2 MiB < 4 MiB stdout budget (JSON overhead headroom).
pub const max_data_bytes: usize = 16 * 1024;
/// Bound total stdout captured from a single sqlite3 invocation.
pub const max_query_stdout_bytes: usize = 4 * 1024 * 1024;
/// Bound total sessions listed per discovery (aligns with host cap).
pub const max_list_sessions: usize = types.max_sessions_per_host;

comptime {
    // Aggregate bound: row cap × field cap must not exceed stdout limit (blocking review).
    if (max_parts_per_session * max_data_bytes > max_query_stdout_bytes) {
        @compileError("opencode_db: max_parts_per_session * max_data_bytes exceeds max_query_stdout_bytes");
    }
    if (max_messages_per_session * max_data_bytes > max_query_stdout_bytes) {
        @compileError("opencode_db: max_messages_per_session * max_data_bytes exceeds max_query_stdout_bytes");
    }
}

pub const SessionRef = struct {
    id: []u8,
    timestamp_secs: i64,

    pub fn deinit(self: *SessionRef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub const ProbeResult = enum {
    ok,
    no_sqlite,
    unreadable,
    schema_mismatch,
};

/// Convert OpenCode millisecond timestamps to Unix seconds (integer divide).
pub fn msToUnixSecs(ms: i64) i64 {
    if (ms < 0) return 0;
    return @divTrunc(ms, 1000);
}

/// Session ids from OpenCode look like `ses_<alnum>`; reject anything unsafe for SQL quoting.
pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Build a stable evidence ref without embedding secret material.
pub fn evidenceRef(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "opencode.db#session/{s}", .{session_id});
}

/// True when `sqlite3` is on PATH and responds to a version probe.
pub fn sqlite3Available(io: std.Io, allocator: std.mem.Allocator) bool {
    const out = runSqlite3(io, allocator, &.{ "sqlite3", "-version" }, 16 * 1024) catch return false;
    defer allocator.free(out);
    return out.len > 0;
}

/// Probe DB readability + required tables (session, part). Read-only.
pub fn probeDb(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) ProbeResult {
    if (!sqlite3Available(io, allocator)) return .no_sqlite;
    if (db_path.len == 0 or db_path.len > 4096 or std.mem.indexOfScalar(u8, db_path, 0) != null) {
        return .unreadable;
    }
    const uri = buildRoUri(allocator, db_path) catch return .unreadable;
    defer allocator.free(uri);

    // Schema probe: required tables must exist.
    const sql =
        \\SELECT name FROM sqlite_master WHERE type='table' AND name IN ('session','part','message') ORDER BY name;
    ;
    const out = runSqlite3(io, allocator, &.{ "sqlite3", "-readonly", "-noheader", uri, sql }, 64 * 1024) catch {
        return .unreadable;
    };
    defer allocator.free(out);

    var has_session = false;
    var has_part = false;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, out, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "session")) has_session = true;
        if (std.mem.eql(u8, t, "part")) has_part = true;
    }
    if (!has_session or !has_part) return .schema_mismatch;
    return .ok;
}

/// List sessions in the time window, newest first, capped.
/// Caller owns returned slice and each SessionRef.id.
pub fn listSessions(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
    window: time_window.Window,
    limit: usize,
) ![]SessionRef {
    const cap = @min(limit, max_list_sessions);
    if (cap == 0) return try allocator.alloc(SessionRef, 0);

    const uri = try buildRoUri(allocator, db_path);
    defer allocator.free(uri);

    var sql_buf: [256]u8 = undefined;
    const sql = blk: {
        if (window.cutoff_secs) |cutoff_secs| {
            // OpenCode stores milliseconds — convert cutoff to ms for the filter.
            const cutoff_ms = std.math.mul(i64, cutoff_secs, 1000) catch std.math.maxInt(i64);
            break :blk try std.fmt.bufPrint(
                &sql_buf,
                "SELECT id, time_updated FROM session WHERE time_updated >= {d} ORDER BY time_updated DESC LIMIT {d};",
                .{ cutoff_ms, cap },
            );
        } else {
            break :blk try std.fmt.bufPrint(
                &sql_buf,
                "SELECT id, time_updated FROM session ORDER BY time_updated DESC LIMIT {d};",
                .{cap},
            );
        }
    };

    const out = try runSqlite3(io, allocator, &.{ "sqlite3", "-readonly", "-json", uri, sql }, max_query_stdout_bytes);
    defer allocator.free(out);

    return try parseSessionListJson(allocator, out);
}

/// Load part (+ message) JSON for one session and extract commands + text blobs.
/// Newest-first under caps so recent danger/secrets are preferred on large sessions.
pub fn parseSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
    session_id: []const u8,
    fallback_ts_secs: i64,
) !jsonl.ParsedSession {
    var result: jsonl.ParsedSession = .{
        .commands = .empty,
        .text_blobs = .empty,
        .timestamp_secs = fallback_ts_secs,
    };
    errdefer result.deinit(allocator);

    if (!isValidSessionId(session_id)) return result;

    const uri = try buildRoUri(allocator, db_path);
    defer allocator.free(uri);

    // Prefer tool-shaped parts (commands) newest-first. Session id is charset-validated.
    // -json avoids newline fragmentation inside data fields.
    var part_sql_buf: [480]u8 = undefined;
    const part_sql = try std.fmt.bufPrint(
        &part_sql_buf,
        "SELECT substr(data, 1, {d}) AS data FROM part WHERE session_id = '{s}' AND data LIKE '%\"tool\"%' ORDER BY time_created DESC LIMIT {d};",
        .{ max_data_bytes, session_id, max_parts_per_session },
    );
    const parts_out = runSqlite3(
        io,
        allocator,
        &.{ "sqlite3", "-readonly", "-json", uri, part_sql },
        max_query_stdout_bytes,
    ) catch return result;
    defer allocator.free(parts_out);
    try absorbJsonDataRows(allocator, parts_out, &result);

    // Messages: secret material in user/assistant text (newest-first, bounded).
    var msg_sql_buf: [400]u8 = undefined;
    const msg_sql = try std.fmt.bufPrint(
        &msg_sql_buf,
        "SELECT substr(data, 1, {d}) AS data FROM message WHERE session_id = '{s}' ORDER BY time_created DESC LIMIT {d};",
        .{ max_data_bytes, session_id, max_messages_per_session },
    );
    // message table may be missing on older schemas — fail soft (do not wipe parts).
    if (runSqlite3(
        io,
        allocator,
        &.{ "sqlite3", "-readonly", "-json", uri, msg_sql },
        max_query_stdout_bytes,
    )) |msgs_out| {
        defer allocator.free(msgs_out);
        try absorbJsonDataRows(allocator, msgs_out, &result);
    } else |_| {}

    return result;
}

/// Parse sqlite3 `-json` array of `{"data":"..."}` objects into extract pipelines.
fn absorbJsonDataRows(allocator: std.mem.Allocator, stdout: []const u8, result: *jsonl.ParsedSession) !void {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return;

    var root = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return;
    defer root.deinit();
    if (root.value != .array) return;

    for (root.value.array.items) |item| {
        if (result.commands.items.len >= types.max_commands_per_session and
            result.text_blobs.items.len >= types.max_commands_per_session)
            break;
        if (item != .object) continue;
        const data_v = item.object.get("data") orelse continue;
        if (data_v != .string) continue;
        const line = data_v.string;
        if (line.len == 0 or line.len > max_data_bytes + 64) continue;
        // Malformed part JSON: skip row, continue (AC-P4).
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (result.commands.items.len < types.max_commands_per_session) {
            try extract.walkValueForCommands(allocator, parsed.value, &result.commands, 0);
        }
        try extract.walkValueForTextBlobs(allocator, parsed.value, &result.text_blobs, 0);
    }
}

fn parseSessionListJson(allocator: std.mem.Allocator, json_text: []const u8) ![]SessionRef {
    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) {
        return try allocator.alloc(SessionRef, 0);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return try allocator.alloc(SessionRef, 0);
    };
    defer parsed.deinit();

    if (parsed.value != .array) return try allocator.alloc(SessionRef, 0);

    var list: std.ArrayList(SessionRef) = .empty;
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        const ts_v = item.object.get("time_updated") orelse continue;
        if (id_v != .string) continue;
        if (!isValidSessionId(id_v.string)) continue;
        const ms: i64 = switch (ts_v) {
            .integer => ts_v.integer,
            .number_string => std.fmt.parseInt(i64, ts_v.number_string, 10) catch continue,
            // Reject float/NaN from hostile JSON rather than @intFromFloat.
            else => continue,
        };
        const id_owned = try allocator.dupe(u8, id_v.string);
        errdefer allocator.free(id_owned);
        try list.append(allocator, .{
            .id = id_owned,
            .timestamp_secs = msToUnixSecs(ms),
        });
        if (list.items.len >= max_list_sessions) break;
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeSessionRefs(allocator: std.mem.Allocator, refs: []SessionRef) void {
    for (refs) |*s| s.deinit(allocator);
    allocator.free(refs);
}

fn buildRoUri(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
    // URI form forces read-only open; never use a writeable default open.
    // Encode characters that break URI parsing (spaces, ? , #).
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    try encoded.ensureTotalCapacity(allocator, db_path.len + 16);
    for (db_path) |c| {
        switch (c) {
            ' ', '?', '#', '%', '&' => {
                const hex = "0123456789ABCDEF";
                try encoded.append(allocator, '%');
                try encoded.append(allocator, hex[c >> 4]);
                try encoded.append(allocator, hex[c & 0xf]);
            },
            else => try encoded.append(allocator, c),
        }
    }
    const path_enc = try encoded.toOwnedSlice(allocator);
    defer allocator.free(path_enc);
    return std.fmt.allocPrint(allocator, "file:{s}?mode=ro", .{path_enc});
}

fn runSqlite3(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout_limit: usize,
) ![]u8 {
    const run_result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.SqliteRunFailed;
    // Free stderr always; transfer stdout only on success (no errdefer double-free).
    defer allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(run_result.stdout);
                return error.SqliteQueryFailed;
            }
        },
        else => {
            allocator.free(run_result.stdout);
            return error.SqliteQueryFailed;
        },
    }
    return run_result.stdout;
}

// ─── unit tests (TDD edges E1–E15 subset) ───────────────────────────────────

test "msToUnixSecs converts OpenCode millisecond timestamps" {
    // Real-shape value from research (~1.785e12 ms).
    const ms: i64 = 1_785_143_897_889;
    const secs = msToUnixSecs(ms);
    try std.testing.expectEqual(@as(i64, 1_785_143_897), secs);
    // Must not be treated as already-seconds (that would be far in the future if used as ms later).
    try std.testing.expect(secs < 2_000_000_000);
    try std.testing.expect(secs > 1_700_000_000);
}

test "isValidSessionId accepts opencode ids rejects injection" {
    try std.testing.expect(isValidSessionId("ses_05d33affcffetdAyEBplSWMdDE"));
    try std.testing.expect(isValidSessionId("abc-123_X"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("ses_'; DROP TABLE session;--"));
    try std.testing.expect(!isValidSessionId("ses/../etc"));
    try std.testing.expect(!isValidSessionId("a' OR '1'='1"));
}

test "evidenceRef never embeds raw secrets" {
    const ref = try evidenceRef(std.testing.allocator, "ses_abc123");
    defer std.testing.allocator.free(ref);
    try std.testing.expectEqualStrings("opencode.db#session/ses_abc123", ref);
    try std.testing.expect(std.mem.indexOf(u8, ref, "ghp_") == null);
}

/// Build a minimal synthetic OpenCode-shaped SQLite DB under `db_path`.
pub fn writeSyntheticFixtureDb(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
    now_secs: i64,
) !void {
    if (!sqlite3Available(io, allocator)) return error.SqliteUnavailable;

    // Ensure parent dir exists.
    if (std.fs.path.dirname(db_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    const in_window_ms = now_secs * 1000;
    const out_window_ms = (now_secs - 90 * 86_400) * 1000;

    // Fake tokens for redaction tests — must never appear in scan output.
    const sql =
        \\CREATE TABLE session (
        \\  id text PRIMARY KEY,
        \\  project_id text NOT NULL,
        \\  slug text NOT NULL DEFAULT 's',
        \\  directory text NOT NULL DEFAULT '/',
        \\  title text NOT NULL DEFAULT 't',
        \\  version text NOT NULL DEFAULT '1',
        \\  time_created integer NOT NULL,
        \\  time_updated integer NOT NULL
        \\);
        \\CREATE TABLE message (
        \\  id text PRIMARY KEY,
        \\  session_id text NOT NULL,
        \\  time_created integer NOT NULL,
        \\  time_updated integer NOT NULL,
        \\  data text NOT NULL
        \\);
        \\CREATE TABLE part (
        \\  id text PRIMARY KEY,
        \\  message_id text NOT NULL,
        \\  session_id text NOT NULL,
        \\  time_created integer NOT NULL,
        \\  time_updated integer NOT NULL,
        \\  data text NOT NULL
        \\);
        \\CREATE INDEX part_session_idx ON part(session_id);
        \\INSERT INTO session VALUES('ses_inwindow01','proj1','s','/','in','1',{d},{d});
        \\INSERT INTO session VALUES('ses_oldwindow02','proj1','s','/','old','1',{d},{d});
        \\INSERT INTO message VALUES('msg_1','ses_inwindow01',{d},{d},'{{"role":"user","content":"token ghp_fakeSyntheticTokenValue1234567890abcd"}}');
        \\INSERT INTO part VALUES('prt_danger','msg_1','ses_inwindow01',{d},{d},'{{"type":"tool","tool":"bash","state":{{"status":"completed","input":{{"command":"rm -rf /"}}}}}}');
        \\INSERT INTO part VALUES('prt_secret','msg_1','ses_inwindow01',{d},{d},'{{"type":"tool","tool":"bash","state":{{"status":"completed","input":{{"command":"cat .env"}}}}}}');
        \\INSERT INTO part VALUES('prt_badjson','msg_1','ses_inwindow01',{d},{d},'NOT_JSON{{{{');
        \\INSERT INTO part VALUES('prt_safe','msg_1','ses_inwindow01',{d},{d},'{{"type":"tool","tool":"bash","state":{{"status":"completed","input":{{"command":"git status"}}}}}}');
        \\INSERT INTO part VALUES('prt_old','msg_old','ses_oldwindow02',{d},{d},'{{"type":"tool","tool":"bash","state":{{"status":"completed","input":{{"command":"rm -rf /tmp/old"}}}}}}');
    ;

    const sql_owned = try std.fmt.allocPrint(allocator, sql, .{
        in_window_ms,  in_window_ms,
        out_window_ms, out_window_ms,
        in_window_ms,  in_window_ms,
        in_window_ms,  in_window_ms,
        in_window_ms,  in_window_ms,
        in_window_ms,  in_window_ms,
        in_window_ms,  in_window_ms,
        out_window_ms, out_window_ms,
    });
    defer allocator.free(sql_owned);

    // Write SQL to a temp script; pipe via `.read` (avoids shell + argv quoting).
    const script_path = try std.fmt.allocPrint(allocator, "{s}.sql", .{db_path});
    defer allocator.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = sql_owned });
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};

    const read_arg = try std.fmt.allocPrint(allocator, ".read {s}", .{script_path});
    defer allocator.free(read_arg);
    const create = try std.process.run(allocator, io, .{
        .argv = &.{ "sqlite3", db_path, read_arg },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(create.stdout);
        allocator.free(create.stderr);
    }
    switch (create.term) {
        .exited => |c| if (c != 0) return error.FixtureCreateFailed,
        else => return error.FixtureCreateFailed,
    }
}

test "synthetic fixture: danger secret_access secret_material redaction and window" {
    const io = std.testing.io;
    if (!sqlite3Available(io, std.testing.allocator)) return error.SkipZigTest;

    const now: i64 = 1_785_143_897;
    const root = try std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp-opencode-fix-{d}", .{now});
    defer std.testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "opencode.db" });
    defer std.testing.allocator.free(db_path);
    try writeSyntheticFixtureDb(io, std.testing.allocator, db_path, now);

    // Probe
    try std.testing.expect(probeDb(io, std.testing.allocator, db_path) == .ok);

    // Window: 30 days around `now`
    const window = time_window.resolveWindow(now, 30, false);
    const sessions = try listSessions(io, std.testing.allocator, db_path, window, 80);
    defer freeSessionRefs(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("ses_inwindow01", sessions[0].id);
    try std.testing.expectEqual(msToUnixSecs(now * 1000), sessions[0].timestamp_secs);

    // Parse in-window session
    var parsed = try parseSession(io, std.testing.allocator, db_path, "ses_inwindow01", sessions[0].timestamp_secs);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.commands.items.len >= 2);

    var saw_rm = false;
    var saw_cat_env = false;
    var saw_git = false;
    for (parsed.commands.items) |cmd| {
        if (std.mem.indexOf(u8, cmd, "rm -rf /") != null) saw_rm = true;
        if (std.mem.indexOf(u8, cmd, "cat .env") != null) saw_cat_env = true;
        if (std.mem.indexOf(u8, cmd, "git status") != null) saw_git = true;
    }
    try std.testing.expect(saw_rm);
    try std.testing.expect(saw_cat_env);
    try std.testing.expect(saw_git);

    // Secret material blob present in text extraction
    var saw_blob = false;
    for (parsed.text_blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "ghp_fake") != null) saw_blob = true;
    }
    try std.testing.expect(saw_blob);

    // Out-of-window session must not appear in list
    for (sessions) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.id, "ses_oldwindow02"));
    }
}

test "malformed part JSON skipped without failing parseSession" {
    const io = std.testing.io;
    if (!sqlite3Available(io, std.testing.allocator)) return error.SkipZigTest;

    const now: i64 = 1_785_143_897;
    const root = try std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp-opencode-malformed-{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer std.testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "opencode.db" });
    defer std.testing.allocator.free(db_path);
    try writeSyntheticFixtureDb(io, std.testing.allocator, db_path, now);

    // Includes prt_badjson — must not error.
    var parsed = try parseSession(io, std.testing.allocator, db_path, "ses_inwindow01", now);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.commands.items.len >= 1);
}

test "buildRoUri uses mode=ro" {
    const uri = try buildRoUri(std.testing.allocator, "/tmp/opencode.db");
    defer std.testing.allocator.free(uri);
    try std.testing.expect(std.mem.startsWith(u8, uri, "file:"));
    try std.testing.expect(std.mem.endsWith(u8, uri, "?mode=ro") or std.mem.indexOf(u8, uri, "?mode=ro") != null);
    try std.testing.expect(std.mem.indexOf(u8, uri, "mode=rw") == null);
}

test "newest parts preferred when session exceeds part cap" {
    const io = std.testing.io;
    if (!sqlite3Available(io, std.testing.allocator)) return error.SkipZigTest;

    const now: i64 = 1_785_143_897;
    const root = try std.fmt.allocPrint(std.testing.allocator, "zig-cache/tmp-opencode-newest-{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer std.testing.allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "opencode.db" });
    defer std.testing.allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, root);

    // Build a session with max_parts_per_session+50 old safe parts, then one newest danger part.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(std.testing.allocator);
    try sql.appendSlice(std.testing.allocator,
        \\CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, slug text NOT NULL DEFAULT 's', directory text NOT NULL DEFAULT '/', title text NOT NULL DEFAULT 't', version text NOT NULL DEFAULT '1', time_created integer NOT NULL, time_updated integer NOT NULL);
        \\CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        \\CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        \\INSERT INTO session VALUES('ses_newestcap01','p','s','/','t','1',1,1);
        \\
    );
    var i: usize = 0;
    while (i < max_parts_per_session + 50) : (i += 1) {
        const line = try std.fmt.allocPrint(
            std.testing.allocator,
            "INSERT INTO part VALUES('prt_{d}','m','ses_newestcap01',{d},{d},'{{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{{\"input\":{{\"command\":\"echo old{d}\"}}}}}}');\n",
            .{ i, i + 1, i + 1, i },
        );
        defer std.testing.allocator.free(line);
        try sql.appendSlice(std.testing.allocator, line);
    }
    const danger_ts = max_parts_per_session + 100;
    const danger = try std.fmt.allocPrint(
        std.testing.allocator,
        "INSERT INTO part VALUES('prt_danger_new','m','ses_newestcap01',{d},{d},'{{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{{\"input\":{{\"command\":\"rm -rf /\"}}}}}}');\n",
        .{ danger_ts, danger_ts },
    );
    defer std.testing.allocator.free(danger);
    try sql.appendSlice(std.testing.allocator, danger);

    const script_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/build.sql", .{root});
    defer std.testing.allocator.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = sql.items });
    const read_arg = try std.fmt.allocPrint(std.testing.allocator, ".read {s}", .{script_path});
    defer std.testing.allocator.free(read_arg);
    const create = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "sqlite3", db_path, read_arg },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(create.stdout);
        std.testing.allocator.free(create.stderr);
    }
    try std.testing.expect(create.term == .exited and create.term.exited == 0);

    var parsed = try parseSession(io, std.testing.allocator, db_path, "ses_newestcap01", now);
    defer parsed.deinit(std.testing.allocator);
    var saw_danger = false;
    for (parsed.commands.items) |cmd| {
        if (std.mem.indexOf(u8, cmd, "rm -rf /") != null) saw_danger = true;
    }
    try std.testing.expect(saw_danger);
}

test "aggregate row bounds fit under stdout budget" {
    try std.testing.expect(max_parts_per_session * max_data_bytes <= max_query_stdout_bytes);
    try std.testing.expect(max_messages_per_session * max_data_bytes <= max_query_stdout_bytes);
}
