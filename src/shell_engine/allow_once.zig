//! Allow-once pending + active stores (JSONL under XDG data).
//!
//! Product paths (brand `orca`, not `dcg`):
//! - Dir: `$XDG_DATA_HOME/orca/` or `~/.local/share/orca/`
//! - `pending_exceptions.jsonl` — issued on deny (short code, full hash, command, cwd, reason, expires)
//! - `allow_once.jsonl` — redeemed active entries (scope cwd|project, single_use, expires, command)
//!
//! Reference behavior: DCG `pending_exceptions.rs` (TTL, prune, exact match, single-use consume,
//! lock spirit, bounded growth). Tests inject absolute paths — no env required.
//!
//! --- Expected public API (implementer; tests are the contract) ---
//!
//! Constants:
//!   `schema_version = 1`
//!   `default_ttl_hours = 24`
//!   `max_pending_lines = 10_000`
//!   `max_pending_bytes = 10 * 1024 * 1024`
//!   `pending_file_name` / `allow_once_file_name`
//!
//! Types:
//!   `ScopeKind` = enum { cwd, project }
//!   `PendingRecord` — short_code (6-digit), full_hash (64 hex), created_at, expires_at,
//!                     cwd, command_raw, reason, single_use, consumed_at?
//!   `AllowOnceEntry` — source_short_code, source_full_hash, created_at, expires_at,
//!                      scope_kind, scope_path, command_raw, reason, single_use, consumed_at?
//!   `Maintenance` — pruned_expired, pruned_consumed, parse_errors
//!   `PendingList` / `AllowOnceList` — owned slices + `.deinit(gpa)`
//!
//! Pure helpers:
//!   `computeFullHash(gpa, created_at, cwd, command_raw) ![]u8`  — SHA-256 hex of
//!       `"{created_at} | {cwd} | {command_raw}"` (no secret; optional HMAC is follow-up)
//!   `shortCodeFromHash(full_hash) [6]u8` — last 8 hex chars → u32 → % 1_000_000 → 6 digits
//!   `isExpired(expires_at, now_iso) bool` — expires_at <= now (ISO-8601 same-format lex)
//!   `scopeMatches(entry, cwd) bool` — cwd exact for .cwd; path-prefix for .project
//!
//! Pending store (path = absolute pending_exceptions.jsonl):
//!   `issuePending(io, gpa, path, command, cwd, reason, now_iso, single_use) !PendingIssue`
//!       — append pending line; prune expired/consumed; enforce max lines/bytes;
//!         short_code unique among active pending (re-key created_at +1s on collision);
//!         returns owned record
//!   `loadPendingActive(io, gpa, path, now_iso) !LoadPending`
//!       — active only; rewrites file when prunes; skips corrupt lines (parse_errors)
//!   `lookupPendingByCode(io, gpa, path, code, now_iso) !LoadPending`
//!   `clearPending(io, gpa, path, now_iso) !ClearResult`  — removed count + maintenance
//!   `revokePending(io, gpa, path, code_or_hash, now_iso) !ClearResult`
//!
//! Allow-once store (path = absolute allow_once.jsonl):
//!   `redeem(io, gpa, pending_path, allow_once_path, code, now_iso, scope_kind, scope_path) !AllowOnceEntry`
//!       — lookup active pending by short_code (fail closed if ambiguous);
//!         burn pending on disk first (fail-closed single-use integrity);
//!         then write allow_once entry (default single_use=true, TTL from now);
//!         owned entry returned
//!   `loadAllowOnceActive(io, gpa, path, now_iso) !LoadAllowOnce`
//!   `matchAllowOnce(io, gpa, path, command, cwd, now_iso, consume) !?AllowOnceEntry`
//!       — exact command_raw + scopeMatches; if consume and single_use → remove entry;
//!         if !consume → match without removing (explain / dry-run)
//!   `clearAllowOnce(io, gpa, path, now_iso) !ClearResult`
//!   `revokeAllowOnce(io, gpa, path, code_or_hash, now_iso) !ClearResult`
//!       — match source_short_code or source_full_hash
//!
//! Errors (in addition to allocator / IO):
//!   `CodeNotFound`, `Expired`, `AlreadyConsumed`, `StoreFull`, `AmbiguousCode`
//!
//! JSONL: one JSON object per line; unknown/corrupt lines skipped (not fatal).
//! s-engine re-exports this module and pulls tests into `test-shell-engine`.
//! Until then: `./scripts/zig test src/shell_engine/allow_once.zig` after impl.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public contract — types & constants (implementer fills function bodies)
// ---------------------------------------------------------------------------

pub const schema_version: u32 = 1;
pub const default_ttl_hours: i64 = 24;
pub const max_pending_lines: usize = 10_000;
pub const max_pending_bytes: u64 = 10 * 1024 * 1024;
pub const pending_file_name = "pending_exceptions.jsonl";
pub const allow_once_file_name = "allow_once.jsonl";

pub const ScopeKind = enum {
    cwd,
    project,
};

pub const StoreError = error{
    CodeNotFound,
    Expired,
    AlreadyConsumed,
    StoreFull,
    /// More than one active pending row shares the same short_code (legacy / corrupt store).
    AmbiguousCode,
};

pub const Maintenance = struct {
    pruned_expired: usize = 0,
    pruned_consumed: usize = 0,
    parse_errors: usize = 0,

    pub fn isEmpty(self: Maintenance) bool {
        return self.pruned_expired == 0 and self.pruned_consumed == 0 and self.parse_errors == 0;
    }
};

pub const PendingRecord = struct {
    schema_version: u32 = schema_version,
    short_code: []const u8,
    full_hash: []const u8,
    created_at: []const u8,
    expires_at: []const u8,
    cwd: []const u8,
    command_raw: []const u8,
    reason: []const u8,
    single_use: bool = true,
    consumed_at: ?[]const u8 = null,
};

pub const AllowOnceEntry = struct {
    schema_version: u32 = schema_version,
    source_short_code: []const u8,
    source_full_hash: []const u8,
    created_at: []const u8,
    expires_at: []const u8,
    scope_kind: ScopeKind,
    scope_path: []const u8,
    command_raw: []const u8,
    reason: []const u8,
    single_use: bool = true,
    consumed_at: ?[]const u8 = null,
};

pub const PendingList = struct {
    records: []PendingRecord = &.{},
    owned: bool = false,

    pub fn deinit(self: *PendingList, gpa: std.mem.Allocator) void {
        if (!self.owned) {
            self.* = .{};
            return;
        }
        for (self.records) |r| freePendingRecord(gpa, r);
        gpa.free(self.records);
        self.* = .{};
    }
};

pub const AllowOnceList = struct {
    entries: []AllowOnceEntry = &.{},
    owned: bool = false,

    pub fn deinit(self: *AllowOnceList, gpa: std.mem.Allocator) void {
        if (!self.owned) {
            self.* = .{};
            return;
        }
        for (self.entries) |e| freeAllowOnceEntry(gpa, e);
        gpa.free(self.entries);
        self.* = .{};
    }
};

pub const PendingIssue = struct {
    record: PendingRecord,
    maintenance: Maintenance = .{},

    pub fn deinit(self: *PendingIssue, gpa: std.mem.Allocator) void {
        freePendingRecord(gpa, self.record);
        self.* = undefined;
    }
};

pub const LoadPending = struct {
    list: PendingList = .{},
    maintenance: Maintenance = .{},

    pub fn deinit(self: *LoadPending, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
        self.* = .{};
    }
};

pub const LoadAllowOnce = struct {
    list: AllowOnceList = .{},
    maintenance: Maintenance = .{},

    pub fn deinit(self: *LoadAllowOnce, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
        self.* = .{};
    }
};

pub const ClearResult = struct {
    removed: usize = 0,
    maintenance: Maintenance = .{},
};

pub fn freePendingRecord(gpa: std.mem.Allocator, r: PendingRecord) void {
    gpa.free(r.short_code);
    gpa.free(r.full_hash);
    gpa.free(r.created_at);
    gpa.free(r.expires_at);
    gpa.free(r.cwd);
    gpa.free(r.command_raw);
    gpa.free(r.reason);
    if (r.consumed_at) |c| gpa.free(c);
}

pub fn freeAllowOnceEntry(gpa: std.mem.Allocator, e: AllowOnceEntry) void {
    gpa.free(e.source_short_code);
    gpa.free(e.source_full_hash);
    gpa.free(e.created_at);
    gpa.free(e.expires_at);
    gpa.free(e.scope_path);
    gpa.free(e.command_raw);
    gpa.free(e.reason);
    if (e.consumed_at) |c| gpa.free(c);
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// SHA-256 hex of `"{created_at} | {cwd} | {command_raw}"` (DCG-compatible).
pub fn computeFullHash(
    gpa: std.mem.Allocator,
    created_at: []const u8,
    cwd: []const u8,
    command_raw: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(gpa, "{s} | {s} | {s}", .{ created_at, cwd, command_raw });
    defer gpa.free(payload);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});

    var hex: [64]u8 = undefined;
    const hex_digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_digits[byte >> 4];
        hex[i * 2 + 1] = hex_digits[byte & 0xf];
    }
    return try gpa.dupe(u8, hex[0..]);
}

/// Last 8 hex chars → u32 → % 1_000_000 → zero-padded 6 digits.
pub fn shortCodeFromHash(full_hash: []const u8) [6]u8 {
    var out: [6]u8 = "000000".*;
    if (full_hash.len < 8) return out;
    const tail = full_hash[full_hash.len - 8 ..];
    const n = std.fmt.parseInt(u32, tail, 16) catch return out;
    const code = n % 1_000_000;
    _ = std.fmt.bufPrint(&out, "{d:0>6}", .{code}) catch return out;
    return out;
}

/// ISO-8601 same-format lexicographic compare: expired when expires_at <= now.
pub fn isExpired(expires_at: []const u8, now_iso: []const u8) bool {
    return std.mem.order(u8, expires_at, now_iso) != .gt;
}

/// cwd scope: exact path. project scope: path-prefix (boundary on `/`).
pub fn scopeMatches(entry: AllowOnceEntry, cwd: []const u8) bool {
    return switch (entry.scope_kind) {
        .cwd => std.mem.eql(u8, entry.scope_path, cwd),
        .project => pathIsUnder(entry.scope_path, cwd),
    };
}

fn pathIsUnder(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, path)) return true;
    if (path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    // Require a path separator boundary so "/repo" does not match "/repo-other".
    const boundary = if (root[root.len - 1] == '/') true else path[root.len] == '/';
    return boundary;
}

// ---------------------------------------------------------------------------
// Pending store
// ---------------------------------------------------------------------------

pub fn issuePending(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    command: []const u8,
    cwd: []const u8,
    reason: []const u8,
    now_iso: []const u8,
    single_use: bool,
) !PendingIssue {
    var state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    defer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    // Bounded growth: rotate oldest active rows until under line/byte caps.
    try rotatePendingToFit(gpa, &state, 1);

    // Ensure short_code is unique among active pending (re-key created_at on collision).
    const record = try buildPendingRecordUnique(gpa, state.active.items, command, cwd, reason, now_iso, single_use);
    var record_owned = true;
    errdefer if (record_owned) freePendingRecord(gpa, record);

    // Byte-cap check for the new line before commit.
    const trial_line = try renderPendingLine(gpa, record);
    defer gpa.free(trial_line);
    if (state.active_bytes + trial_line.len + 1 > max_pending_bytes) {
        while (state.active.items.len > 0 and state.active_bytes + trial_line.len + 1 > max_pending_bytes) {
            const old = state.active.orderedRemove(0);
            const old_line = renderPendingLine(gpa, old) catch {
                freePendingRecord(gpa, old);
                return error.StoreFull;
            };
            defer gpa.free(old_line);
            state.active_bytes -|= old_line.len + 1;
            freePendingRecord(gpa, old);
        }
        if (state.active_bytes + trial_line.len + 1 > max_pending_bytes) {
            return error.StoreFull;
        }
    }

    try state.active.append(gpa, record);
    record_owned = false; // now owned by state.active (defer frees it)
    state.active_bytes += trial_line.len + 1;

    try writePendingFile(runtime_io, gpa, pending_path, state.active.items);

    const owned = try clonePendingRecord(gpa, state.active.items[state.active.items.len - 1]);
    return .{
        .record = owned,
        .maintenance = state.maintenance,
    };
}

pub fn loadPendingActive(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    now_iso: []const u8,
) !LoadPending {
    var state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    errdefer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    if (state.dirty) {
        try writePendingFile(runtime_io, gpa, pending_path, state.active.items);
    }

    // pendingStateToLoad steals the slice; disarm errdefer by emptying state first only on success.
    const result = try pendingStateToLoad(gpa, &state);
    // state.active is empty/unowned after toOwnedSlice or deinit inside pendingStateToLoad.
    return result;
}

pub fn lookupPendingByCode(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    code: []const u8,
    now_iso: []const u8,
) !LoadPending {
    var state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    defer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    if (state.dirty) {
        try writePendingFile(runtime_io, gpa, pending_path, state.active.items);
    }

    var matched: std.ArrayListUnmanaged(PendingRecord) = .empty;
    errdefer {
        freePendingRecords(gpa, matched.items);
        matched.deinit(gpa);
    }

    for (state.active.items) |r| {
        if (std.mem.eql(u8, r.short_code, code)) {
            try matched.append(gpa, try clonePendingRecord(gpa, r));
        }
    }

    if (matched.items.len == 0) {
        matched.deinit(gpa);
        return .{
            .list = .{ .records = &.{}, .owned = false },
            .maintenance = state.maintenance,
        };
    }

    const records = try matched.toOwnedSlice(gpa);
    return .{
        .list = .{ .records = records, .owned = true },
        .maintenance = state.maintenance,
    };
}

pub fn clearPending(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    now_iso: []const u8,
) !ClearResult {
    var state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    defer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    const removed = state.active.items.len;
    // Drop all active rows and rewrite empty (also drops expired via load).
    freePendingRecords(gpa, state.active.items);
    state.active.clearRetainingCapacity();

    try writePendingFile(runtime_io, gpa, pending_path, state.active.items);
    return .{
        .removed = removed,
        .maintenance = state.maintenance,
    };
}

pub fn revokePending(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    code_or_hash: []const u8,
    now_iso: []const u8,
) !ClearResult {
    var state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    defer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    // In-place compact: single owner for all records (avoids dual-list OOM double-free).
    var removed: usize = 0;
    var write_idx: usize = 0;
    for (state.active.items) |r| {
        if (std.mem.eql(u8, r.short_code, code_or_hash) or std.mem.eql(u8, r.full_hash, code_or_hash)) {
            freePendingRecord(gpa, r);
            removed += 1;
        } else {
            state.active.items[write_idx] = r;
            write_idx += 1;
        }
    }
    state.active.shrinkRetainingCapacity(write_idx);

    try writePendingFile(runtime_io, gpa, pending_path, state.active.items);

    return .{
        .removed = removed,
        .maintenance = state.maintenance,
    };
}

// ---------------------------------------------------------------------------
// Allow-once store
// ---------------------------------------------------------------------------

pub fn redeem(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    allow_once_path: []const u8,
    code: []const u8,
    now_iso: []const u8,
    scope_kind: ScopeKind,
    scope_path: []const u8,
) !AllowOnceEntry {
    var pending_state = try loadPendingState(runtime_io, gpa, pending_path, now_iso);
    defer {
        freePendingRecords(gpa, pending_state.active.items);
        pending_state.active.deinit(gpa);
    }

    // Resolve active short_code matches first (live wins over expired-on-disk collisions).
    var match_count: usize = 0;
    var found_idx: ?usize = null;
    for (pending_state.active.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.short_code, code)) {
            match_count += 1;
            if (found_idx == null) found_idx = i;
        }
    }
    if (match_count > 1) return error.AmbiguousCode;
    const idx = found_idx orelse {
        // No active match: distinguish Expired (was present, TTL elapsed) vs missing.
        if (try pendingCodeIsExpiredOnDisk(runtime_io, gpa, pending_path, code, now_iso)) {
            return error.Expired;
        }
        return error.CodeNotFound;
    };

    const pending = pending_state.active.items[idx];
    if (pending.consumed_at != null) return error.AlreadyConsumed;

    // Build returned entry before burning pending (needs field slices while record lives).
    const entry = try buildAllowOnceFromPending(gpa, pending, now_iso, scope_kind, scope_path);
    errdefer freeAllowOnceEntry(gpa, entry);

    // FAIL-CLOSED dual-file order: burn pending on disk first, then mint allow-once.
    // If pending write fails → disk unchanged, code remains redeemable, no grant written.
    // If pending write succeeds and allow-once write fails → code is burned (no double redeem);
    // caller must re-issue rather than retry redeem blindly.
    const removed = pending_state.active.orderedRemove(idx);
    var removed_owned = true;
    errdefer if (removed_owned) freePendingRecord(gpa, removed);

    try writePendingFile(runtime_io, gpa, pending_path, pending_state.active.items);
    freePendingRecord(gpa, removed);
    removed_owned = false;

    // Append to allow-once store (prune first via load).
    var allow_state = try loadAllowOnceState(runtime_io, gpa, allow_once_path, now_iso);
    defer {
        freeAllowOnceEntries(gpa, allow_state.active.items);
        allow_state.active.deinit(gpa);
    }
    const stored = try cloneAllowOnceEntry(gpa, entry);
    var stored_owned = true;
    errdefer if (stored_owned) freeAllowOnceEntry(gpa, stored);
    try allow_state.active.append(gpa, stored);
    stored_owned = false; // owned by allow_state (defer frees)
    try writeAllowOnceFile(runtime_io, gpa, allow_once_path, allow_state.active.items);

    return entry;
}

pub fn loadAllowOnceActive(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    allow_once_path: []const u8,
    now_iso: []const u8,
) !LoadAllowOnce {
    var state = try loadAllowOnceState(runtime_io, gpa, allow_once_path, now_iso);
    errdefer {
        freeAllowOnceEntries(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    if (state.dirty) {
        try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);
    }

    return allowOnceStateToLoad(gpa, &state);
}

/// Match exact command + scope. When `consume` is true and the entry is single_use,
/// remove it from the store (evaluate path). When `consume` is false, leave store intact
/// (explain / dry-run).
pub fn matchAllowOnce(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    allow_once_path: []const u8,
    command: []const u8,
    cwd: []const u8,
    now_iso: []const u8,
    consume: bool,
) !?AllowOnceEntry {
    var state = try loadAllowOnceState(runtime_io, gpa, allow_once_path, now_iso);
    defer {
        freeAllowOnceEntries(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    var hit_idx: ?usize = null;
    for (state.active.items, 0..) |e, i| {
        if (!std.mem.eql(u8, e.command_raw, command)) continue;
        if (!scopeMatches(e, cwd)) continue;
        hit_idx = i;
        break;
    }

    const idx = hit_idx orelse {
        if (state.dirty) {
            try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);
        }
        return null;
    };

    if (consume and state.active.items[idx].single_use) {
        // Transfer ownership of the matched entry out of the list (defer must not free it).
        const taken = state.active.orderedRemove(idx);
        errdefer freeAllowOnceEntry(gpa, taken);
        try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);
        return taken;
    }

    const owned = try cloneAllowOnceEntry(gpa, state.active.items[idx]);
    errdefer freeAllowOnceEntry(gpa, owned);
    if (state.dirty) {
        try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);
    }
    return owned;
}

pub fn clearAllowOnce(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    allow_once_path: []const u8,
    now_iso: []const u8,
) !ClearResult {
    var state = try loadAllowOnceState(runtime_io, gpa, allow_once_path, now_iso);
    defer {
        freeAllowOnceEntries(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    const removed = state.active.items.len;
    freeAllowOnceEntries(gpa, state.active.items);
    state.active.clearRetainingCapacity();
    try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);
    return .{
        .removed = removed,
        .maintenance = state.maintenance,
    };
}

pub fn revokeAllowOnce(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    allow_once_path: []const u8,
    code_or_hash: []const u8,
    now_iso: []const u8,
) !ClearResult {
    var state = try loadAllowOnceState(runtime_io, gpa, allow_once_path, now_iso);
    defer {
        freeAllowOnceEntries(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    // In-place compact: single owner for all entries (avoids dual-list OOM double-free).
    var removed: usize = 0;
    var write_idx: usize = 0;
    for (state.active.items) |e| {
        if (std.mem.eql(u8, e.source_short_code, code_or_hash) or
            std.mem.eql(u8, e.source_full_hash, code_or_hash))
        {
            freeAllowOnceEntry(gpa, e);
            removed += 1;
        } else {
            state.active.items[write_idx] = e;
            write_idx += 1;
        }
    }
    state.active.shrinkRetainingCapacity(write_idx);

    try writeAllowOnceFile(runtime_io, gpa, allow_once_path, state.active.items);

    return .{
        .removed = removed,
        .maintenance = state.maintenance,
    };
}

// ---------------------------------------------------------------------------
// Internals — pending JSONL
// ---------------------------------------------------------------------------

const PendingState = struct {
    active: std.ArrayListUnmanaged(PendingRecord) = .empty,
    maintenance: Maintenance = .{},
    dirty: bool = false,
    active_bytes: u64 = 0,
};

fn loadPendingState(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    now_iso: []const u8,
) !PendingState {
    var state: PendingState = .{};
    errdefer {
        freePendingRecords(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    const raw = readFileOptional(runtime_io, gpa, pending_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    if (raw == null) return state;
    const body = raw.?;
    defer gpa.free(body);

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = parsePendingLine(gpa, line) catch {
            state.maintenance.parse_errors += 1;
            state.dirty = true;
            continue;
        };

        if (parsed.consumed_at != null) {
            freePendingRecord(gpa, parsed);
            state.maintenance.pruned_consumed += 1;
            state.dirty = true;
            continue;
        }
        if (isExpired(parsed.expires_at, now_iso)) {
            freePendingRecord(gpa, parsed);
            state.maintenance.pruned_expired += 1;
            state.dirty = true;
            continue;
        }

        const line_bytes = line.len + 1;
        try state.active.append(gpa, parsed);
        state.active_bytes += line_bytes;
    }

    return state;
}

fn pendingStateToLoad(gpa: std.mem.Allocator, state: *PendingState) !LoadPending {
    if (state.active.items.len == 0) {
        state.active.deinit(gpa);
        return .{
            .list = .{ .records = &.{}, .owned = false },
            .maintenance = state.maintenance,
        };
    }
    const records = try state.active.toOwnedSlice(gpa);
    return .{
        .list = .{ .records = records, .owned = true },
        .maintenance = state.maintenance,
    };
}

fn rotatePendingToFit(gpa: std.mem.Allocator, state: *PendingState, room_for: usize) !void {
    // Line cap: keep at most max_pending_lines - room_for existing rows.
    while (state.active.items.len + room_for > max_pending_lines) {
        if (state.active.items.len == 0) return error.StoreFull;
        const old = state.active.orderedRemove(0);
        const old_line = renderPendingLine(gpa, old) catch {
            freePendingRecord(gpa, old);
            return error.StoreFull;
        };
        defer gpa.free(old_line);
        state.active_bytes -|= old_line.len + 1;
        freePendingRecord(gpa, old);
        state.dirty = true;
    }
}

fn parsePendingLine(gpa: std.mem.Allocator, line: []const u8) !PendingRecord {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return error.Corrupt;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Corrupt;
    const obj = parsed.value.object;

    const short_code = try dupeJsonString(gpa, obj, "short_code");
    errdefer gpa.free(short_code);
    const full_hash = try dupeJsonString(gpa, obj, "full_hash");
    errdefer gpa.free(full_hash);
    const created_at = try dupeJsonString(gpa, obj, "created_at");
    errdefer gpa.free(created_at);
    const expires_at = try dupeJsonString(gpa, obj, "expires_at");
    errdefer gpa.free(expires_at);
    const cwd = try dupeJsonString(gpa, obj, "cwd");
    errdefer gpa.free(cwd);
    const command_raw = try dupeJsonString(gpa, obj, "command_raw");
    errdefer gpa.free(command_raw);
    const reason = try dupeJsonString(gpa, obj, "reason");
    errdefer gpa.free(reason);

    const schema = jsonU32(obj, "schema_version") orelse schema_version;
    const single_use = jsonBool(obj, "single_use") orelse true;
    const consumed_at = try dupeJsonStringOptional(gpa, obj, "consumed_at");

    return .{
        .schema_version = schema,
        .short_code = short_code,
        .full_hash = full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .cwd = cwd,
        .command_raw = command_raw,
        .reason = reason,
        .single_use = single_use,
        .consumed_at = consumed_at,
    };
}

fn renderPendingLine(gpa: std.mem.Allocator, r: PendingRecord) ![]u8 {
    const payload = .{
        .schema_version = r.schema_version,
        .short_code = r.short_code,
        .full_hash = r.full_hash,
        .created_at = r.created_at,
        .expires_at = r.expires_at,
        .cwd = r.cwd,
        .command_raw = r.command_raw,
        .reason = r.reason,
        .single_use = r.single_use,
        .consumed_at = r.consumed_at,
    };
    return std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return error.OutOfMemory;
}

fn writePendingFile(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    records: []const PendingRecord,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    for (records) |r| {
        const line = try renderPendingLine(gpa, r);
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
        try buf.append(gpa, '\n');
    }
    try writeFile(runtime_io, path, buf.items);
}

fn clonePendingRecord(gpa: std.mem.Allocator, r: PendingRecord) !PendingRecord {
    const short_code = try gpa.dupe(u8, r.short_code);
    errdefer gpa.free(short_code);
    const full_hash = try gpa.dupe(u8, r.full_hash);
    errdefer gpa.free(full_hash);
    const created_at = try gpa.dupe(u8, r.created_at);
    errdefer gpa.free(created_at);
    const expires_at = try gpa.dupe(u8, r.expires_at);
    errdefer gpa.free(expires_at);
    const cwd = try gpa.dupe(u8, r.cwd);
    errdefer gpa.free(cwd);
    const command_raw = try gpa.dupe(u8, r.command_raw);
    errdefer gpa.free(command_raw);
    const reason = try gpa.dupe(u8, r.reason);
    errdefer gpa.free(reason);
    const consumed_at = if (r.consumed_at) |c| try gpa.dupe(u8, c) else null;
    return .{
        .schema_version = r.schema_version,
        .short_code = short_code,
        .full_hash = full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .cwd = cwd,
        .command_raw = command_raw,
        .reason = reason,
        .single_use = r.single_use,
        .consumed_at = consumed_at,
    };
}

fn freePendingRecords(gpa: std.mem.Allocator, records: []PendingRecord) void {
    for (records) |r| freePendingRecord(gpa, r);
}

/// True when a pending line with this short_code exists on disk and is expired at now_iso.
fn pendingCodeIsExpiredOnDisk(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    pending_path: []const u8,
    code: []const u8,
    now_iso: []const u8,
) !bool {
    const raw = readFileOptional(runtime_io, gpa, pending_path) catch return false;
    if (raw == null) return false;
    const body = raw.?;
    defer gpa.free(body);

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = parsePendingLine(gpa, line) catch continue;
        defer freePendingRecord(gpa, parsed);
        if (!std.mem.eql(u8, parsed.short_code, code)) continue;
        if (parsed.consumed_at != null) continue;
        if (isExpired(parsed.expires_at, now_iso)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Internals — allow-once JSONL
// ---------------------------------------------------------------------------

const AllowOnceState = struct {
    active: std.ArrayListUnmanaged(AllowOnceEntry) = .empty,
    maintenance: Maintenance = .{},
    dirty: bool = false,
};

fn loadAllowOnceState(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    allow_once_path: []const u8,
    now_iso: []const u8,
) !AllowOnceState {
    var state: AllowOnceState = .{};
    errdefer {
        freeAllowOnceEntries(gpa, state.active.items);
        state.active.deinit(gpa);
    }

    const raw = readFileOptional(runtime_io, gpa, allow_once_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    if (raw == null) return state;
    const body = raw.?;
    defer gpa.free(body);

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = parseAllowOnceLine(gpa, line) catch {
            state.maintenance.parse_errors += 1;
            state.dirty = true;
            continue;
        };

        if (parsed.consumed_at != null) {
            freeAllowOnceEntry(gpa, parsed);
            state.maintenance.pruned_consumed += 1;
            state.dirty = true;
            continue;
        }
        if (isExpired(parsed.expires_at, now_iso)) {
            freeAllowOnceEntry(gpa, parsed);
            state.maintenance.pruned_expired += 1;
            state.dirty = true;
            continue;
        }

        try state.active.append(gpa, parsed);
    }

    return state;
}

fn allowOnceStateToLoad(gpa: std.mem.Allocator, state: *AllowOnceState) !LoadAllowOnce {
    if (state.active.items.len == 0) {
        state.active.deinit(gpa);
        return .{
            .list = .{ .entries = &.{}, .owned = false },
            .maintenance = state.maintenance,
        };
    }
    const entries = try state.active.toOwnedSlice(gpa);
    return .{
        .list = .{ .entries = entries, .owned = true },
        .maintenance = state.maintenance,
    };
}

fn parseAllowOnceLine(gpa: std.mem.Allocator, line: []const u8) !AllowOnceEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return error.Corrupt;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Corrupt;
    const obj = parsed.value.object;

    const source_short_code = try dupeJsonString(gpa, obj, "source_short_code");
    errdefer gpa.free(source_short_code);
    const source_full_hash = try dupeJsonString(gpa, obj, "source_full_hash");
    errdefer gpa.free(source_full_hash);
    const created_at = try dupeJsonString(gpa, obj, "created_at");
    errdefer gpa.free(created_at);
    const expires_at = try dupeJsonString(gpa, obj, "expires_at");
    errdefer gpa.free(expires_at);
    const scope_path = try dupeJsonString(gpa, obj, "scope_path");
    errdefer gpa.free(scope_path);
    const command_raw = try dupeJsonString(gpa, obj, "command_raw");
    errdefer gpa.free(command_raw);
    const reason = try dupeJsonString(gpa, obj, "reason");
    errdefer gpa.free(reason);

    const scope_kind_str = jsonString(obj, "scope_kind") orelse return error.Corrupt;
    const scope_kind: ScopeKind = if (std.mem.eql(u8, scope_kind_str, "cwd"))
        .cwd
    else if (std.mem.eql(u8, scope_kind_str, "project"))
        .project
    else
        return error.Corrupt;

    const schema = jsonU32(obj, "schema_version") orelse schema_version;
    const single_use = jsonBool(obj, "single_use") orelse true;
    const consumed_at = try dupeJsonStringOptional(gpa, obj, "consumed_at");

    return .{
        .schema_version = schema,
        .source_short_code = source_short_code,
        .source_full_hash = source_full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .scope_kind = scope_kind,
        .scope_path = scope_path,
        .command_raw = command_raw,
        .reason = reason,
        .single_use = single_use,
        .consumed_at = consumed_at,
    };
}

fn renderAllowOnceLine(gpa: std.mem.Allocator, e: AllowOnceEntry) ![]u8 {
    const scope_kind_str: []const u8 = switch (e.scope_kind) {
        .cwd => "cwd",
        .project => "project",
    };
    const payload = .{
        .schema_version = e.schema_version,
        .source_short_code = e.source_short_code,
        .source_full_hash = e.source_full_hash,
        .created_at = e.created_at,
        .expires_at = e.expires_at,
        .scope_kind = scope_kind_str,
        .scope_path = e.scope_path,
        .command_raw = e.command_raw,
        .reason = e.reason,
        .single_use = e.single_use,
        .consumed_at = e.consumed_at,
    };
    return std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return error.OutOfMemory;
}

fn writeAllowOnceFile(
    runtime_io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    entries: []const AllowOnceEntry,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    for (entries) |e| {
        const line = try renderAllowOnceLine(gpa, e);
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
        try buf.append(gpa, '\n');
    }
    try writeFile(runtime_io, path, buf.items);
}

fn cloneAllowOnceEntry(gpa: std.mem.Allocator, e: AllowOnceEntry) !AllowOnceEntry {
    const source_short_code = try gpa.dupe(u8, e.source_short_code);
    errdefer gpa.free(source_short_code);
    const source_full_hash = try gpa.dupe(u8, e.source_full_hash);
    errdefer gpa.free(source_full_hash);
    const created_at = try gpa.dupe(u8, e.created_at);
    errdefer gpa.free(created_at);
    const expires_at = try gpa.dupe(u8, e.expires_at);
    errdefer gpa.free(expires_at);
    const scope_path = try gpa.dupe(u8, e.scope_path);
    errdefer gpa.free(scope_path);
    const command_raw = try gpa.dupe(u8, e.command_raw);
    errdefer gpa.free(command_raw);
    const reason = try gpa.dupe(u8, e.reason);
    errdefer gpa.free(reason);
    const consumed_at = if (e.consumed_at) |c| try gpa.dupe(u8, c) else null;
    return .{
        .schema_version = e.schema_version,
        .source_short_code = source_short_code,
        .source_full_hash = source_full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .scope_kind = e.scope_kind,
        .scope_path = scope_path,
        .command_raw = command_raw,
        .reason = reason,
        .single_use = e.single_use,
        .consumed_at = consumed_at,
    };
}

fn freeAllowOnceEntries(gpa: std.mem.Allocator, entries: []AllowOnceEntry) void {
    for (entries) |e| freeAllowOnceEntry(gpa, e);
}

// ---------------------------------------------------------------------------
// Internals — JSON helpers, ISO math, file IO
// ---------------------------------------------------------------------------

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

fn dupeJsonString(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const s = jsonString(obj, key) orelse return error.Corrupt;
    return try gpa.dupe(u8, s);
}

fn dupeJsonStringOptional(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| try gpa.dupe(u8, s),
        else => error.Corrupt,
    };
}

/// Add whole hours to a UTC ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SSZ` or with fractional seconds ignored).
fn addHoursIso(gpa: std.mem.Allocator, iso: []const u8, hours: i64) ![]u8 {
    return addSecondsIso(gpa, iso, hours * 3600);
}

/// Add whole seconds to a UTC ISO-8601 timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
fn addSecondsIso(gpa: std.mem.Allocator, iso: []const u8, seconds: i64) ![]u8 {
    const parts = try parseIsoUtc(iso);
    var y: i32 = parts.year;
    var mo: i32 = parts.month;
    var d: i32 = parts.day;
    var h: i64 = parts.hour;
    var mi: i64 = parts.minute;
    var s: i64 = @as(i64, @intCast(parts.second)) + seconds;

    // Normalize seconds → minutes → hours → days.
    while (s >= 60) {
        s -= 60;
        mi += 1;
    }
    while (s < 0) {
        s += 60;
        mi -= 1;
    }
    while (mi >= 60) {
        mi -= 60;
        h += 1;
    }
    while (mi < 0) {
        mi += 60;
        h -= 1;
    }
    while (h >= 24) {
        h -= 24;
        d += 1;
        const dim = daysInMonth(y, mo);
        if (d > dim) {
            d = 1;
            mo += 1;
            if (mo > 12) {
                mo = 1;
                y += 1;
            }
        }
    }
    while (h < 0) {
        h += 24;
        d -= 1;
        if (d < 1) {
            mo -= 1;
            if (mo < 1) {
                mo = 12;
                y -= 1;
            }
            d = daysInMonth(y, mo);
        }
    }

    // Cast to unsigned so fmt does not emit a leading '+' for signed ints.
    return try std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(y)),
        @as(u32, @intCast(mo)),
        @as(u32, @intCast(d)),
        @as(u32, @intCast(h)),
        @as(u32, @intCast(mi)),
        @as(u32, @intCast(s)),
    });
}

fn shortCodeInUse(records: []const PendingRecord, code: []const u8) bool {
    for (records) |r| {
        if (std.mem.eql(u8, r.short_code, code)) return true;
    }
    return false;
}

/// Build a pending record whose short_code is unique among `active`.
/// On collision, re-key by bumping `created_at` (+1s each attempt) so hash/short_code change.
fn buildPendingRecordUnique(
    gpa: std.mem.Allocator,
    active: []const PendingRecord,
    command: []const u8,
    cwd: []const u8,
    reason: []const u8,
    now_iso: []const u8,
    single_use: bool,
) !PendingRecord {
    // max_pending_lines unique codes always fit in 1e6 space; bound retries tightly.
    const max_attempts: i64 = @intCast(max_pending_lines + 16);
    var offset: i64 = 0;
    while (offset < max_attempts) : (offset += 1) {
        const created_at_iso = if (offset == 0)
            try gpa.dupe(u8, now_iso)
        else
            try addSecondsIso(gpa, now_iso, offset);
        defer gpa.free(created_at_iso);

        const record = try buildPendingRecord(gpa, command, cwd, reason, created_at_iso, single_use);
        if (!shortCodeInUse(active, record.short_code)) return record;
        freePendingRecord(gpa, record);
    }
    return error.StoreFull;
}

fn buildPendingRecord(
    gpa: std.mem.Allocator,
    command: []const u8,
    cwd: []const u8,
    reason: []const u8,
    now_iso: []const u8,
    single_use: bool,
) !PendingRecord {
    const expires_at = try addHoursIso(gpa, now_iso, default_ttl_hours);
    errdefer gpa.free(expires_at);
    const full_hash = try computeFullHash(gpa, now_iso, cwd, command);
    errdefer gpa.free(full_hash);
    const code_buf = shortCodeFromHash(full_hash);
    const short_code = try gpa.dupe(u8, code_buf[0..]);
    errdefer gpa.free(short_code);
    const created_at = try gpa.dupe(u8, now_iso);
    errdefer gpa.free(created_at);
    const cwd_owned = try gpa.dupe(u8, cwd);
    errdefer gpa.free(cwd_owned);
    const command_raw = try gpa.dupe(u8, command);
    errdefer gpa.free(command_raw);
    const reason_owned = try gpa.dupe(u8, reason);
    errdefer gpa.free(reason_owned);
    return .{
        .schema_version = schema_version,
        .short_code = short_code,
        .full_hash = full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .cwd = cwd_owned,
        .command_raw = command_raw,
        .reason = reason_owned,
        .single_use = single_use,
        .consumed_at = null,
    };
}

fn buildAllowOnceFromPending(
    gpa: std.mem.Allocator,
    pending: PendingRecord,
    now_iso: []const u8,
    scope_kind: ScopeKind,
    scope_path: []const u8,
) !AllowOnceEntry {
    const expires_at = try addHoursIso(gpa, now_iso, default_ttl_hours);
    errdefer gpa.free(expires_at);
    const source_short_code = try gpa.dupe(u8, pending.short_code);
    errdefer gpa.free(source_short_code);
    const source_full_hash = try gpa.dupe(u8, pending.full_hash);
    errdefer gpa.free(source_full_hash);
    const created_at = try gpa.dupe(u8, now_iso);
    errdefer gpa.free(created_at);
    const scope_path_owned = try gpa.dupe(u8, scope_path);
    errdefer gpa.free(scope_path_owned);
    const command_raw = try gpa.dupe(u8, pending.command_raw);
    errdefer gpa.free(command_raw);
    const reason = try gpa.dupe(u8, pending.reason);
    errdefer gpa.free(reason);
    return .{
        .schema_version = schema_version,
        .source_short_code = source_short_code,
        .source_full_hash = source_full_hash,
        .created_at = created_at,
        .expires_at = expires_at,
        .scope_kind = scope_kind,
        .scope_path = scope_path_owned,
        .command_raw = command_raw,
        .reason = reason,
        .single_use = pending.single_use,
        .consumed_at = null,
    };
}

const IsoParts = struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i64,
    minute: u32,
    second: u32,
};

fn parseIsoUtc(iso: []const u8) !IsoParts {
    // Minimum: YYYY-MM-DDTHH:MM:SSZ
    if (iso.len < 20) return error.InvalidIso;
    if (iso[4] != '-' or iso[7] != '-' or iso[10] != 'T' or iso[13] != ':' or iso[16] != ':') {
        return error.InvalidIso;
    }
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return error.InvalidIso;
    const month = std.fmt.parseInt(i32, iso[5..7], 10) catch return error.InvalidIso;
    const day = std.fmt.parseInt(i32, iso[8..10], 10) catch return error.InvalidIso;
    const hour = std.fmt.parseInt(i64, iso[11..13], 10) catch return error.InvalidIso;
    const minute = std.fmt.parseInt(u32, iso[14..16], 10) catch return error.InvalidIso;
    const second = std.fmt.parseInt(u32, iso[17..19], 10) catch return error.InvalidIso;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour < 0 or hour > 23 or minute > 59 or second > 60) {
        return error.InvalidIso;
    }
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn daysInMonth(year: i32, month: i32) i32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    return @mod(year, 4) == 0;
}

/// Read file; FileNotFound → null. Caps at max_pending_bytes (+1 probe).
fn readFileOptional(runtime_io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const limit = max_pending_bytes + 1;
    return std.Io.Dir.cwd().readFileAlloc(runtime_io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => err,
    };
}

fn writeFile(runtime_io: std.Io, path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(runtime_io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var file = try std.Io.Dir.cwd().createFile(runtime_io, path, .{});
    defer file.close(runtime_io);
    try file.writeStreamingAll(runtime_io, body);
}

// ---------------------------------------------------------------------------
// Tests — locked contract (implementer: green these; do not weaken assertions)
// ---------------------------------------------------------------------------

const testing = std.testing;
const allocator = testing.allocator;
const io = testing.io;

const fixed_now = "2026-07-25T15:00:00Z";
const far_future = "9999-01-01T00:00:00Z";
const past_time = "2026-07-24T00:00:00Z";

fn writeFileAbsolute(path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

fn readFileAbsolute(path: []const u8) ![]u8 {
    // Cap above max_pending_bytes so bounded-growth fixtures can be inspected.
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
}

fn joinPath(tmp_root: []const u8, rel: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ tmp_root, rel });
}

fn tmpRoot() !struct { dir: std.testing.TmpDir, path: []u8 } {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    // realPathFileAlloc returns [:0]u8 (dupeZ). Re-dupe to a plain slice for free.
    const path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_z);
    const path = try allocator.dupe(u8, path_z);
    return .{ .dir = tmp, .path = path };
}

fn storePaths(tmp_path: []const u8) !struct { pending: []u8, allow_once: []u8 } {
    const pending = try joinPath(tmp_path, pending_file_name);
    errdefer allocator.free(pending);
    const allow_once = try joinPath(tmp_path, allow_once_file_name);
    return .{ .pending = pending, .allow_once = allow_once };
}

fn isSixDigitNumeric(code: []const u8) bool {
    if (code.len != 6) return false;
    for (code) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ── Pure helpers (hash / short code / expiry / scope) ────────────────────────

test "s3-once-store: computeFullHash is stable SHA-256 hex of timestamp|cwd|command" {
    // DCG-compatible input: "{created_at} | {cwd} | {command_raw}"
    const hash = try computeFullHash(allocator, "2099-01-01T00:00:00Z", "/repo", "git status");
    defer allocator.free(hash);
    try testing.expectEqual(@as(usize, 64), hash.len);
    // Known vector from DCG pending_exceptions tests.
    try testing.expectEqualStrings(
        "17a268f67ce0aab3bc5015427e3ba8fd1d643d25f9f13dca1332c13818a5ac63",
        hash,
    );
    // Lowercase hex only.
    for (hash) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "s3-once-store: shortCodeFromHash is 6-digit numeric from last 8 hex chars" {
    const full = "17a268f67ce0aab3bc5015427e3ba8fd1d643d25f9f13dca1332c13818a5ac63";
    const code = shortCodeFromHash(full);
    try testing.expect(isSixDigitNumeric(code[0..]));
    // 0x18a5ac63 % 1_000_000 = 510755 (plan example / DCG vector).
    try testing.expectEqualStrings("510755", code[0..]);
}

test "s3-once-store: isExpired lexicographic ISO compare" {
    try testing.expect(isExpired("2026-07-25T00:00:00Z", fixed_now)); // expires_at < now
    try testing.expect(isExpired(fixed_now, fixed_now)); // expires_at == now → expired
    try testing.expect(!isExpired("2026-07-26T00:00:00Z", fixed_now));
    try testing.expect(!isExpired(far_future, fixed_now));
}

test "s3-once-store: scopeMatches cwd exact and project prefix" {
    const cwd_entry = AllowOnceEntry{
        .source_short_code = "510755",
        .source_full_hash = "ab",
        .created_at = fixed_now,
        .expires_at = far_future,
        .scope_kind = .cwd,
        .scope_path = "/repo",
        .command_raw = "git status",
        .reason = "scope test",
    };
    try testing.expect(scopeMatches(cwd_entry, "/repo"));
    try testing.expect(!scopeMatches(cwd_entry, "/repo/sub"));
    try testing.expect(!scopeMatches(cwd_entry, "/other"));

    const project_entry = AllowOnceEntry{
        .source_short_code = "510755",
        .source_full_hash = "ab",
        .created_at = fixed_now,
        .expires_at = far_future,
        .scope_kind = .project,
        .scope_path = "/repo",
        .command_raw = "git status",
        .reason = "scope test",
    };
    try testing.expect(scopeMatches(project_entry, "/repo"));
    try testing.expect(scopeMatches(project_entry, "/repo/sub"));
    try testing.expect(scopeMatches(project_entry, "/repo/a/b"));
    try testing.expect(!scopeMatches(project_entry, "/repo-other"));
    try testing.expect(!scopeMatches(project_entry, "/other"));
}

// ── Acceptance 1: issue → redeem → match; wrong cwd miss; expired cannot redeem

test "s3-once-store: issue pending writes JSONL with 6-digit short code" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git reset --hard HEAD",
        "/repo",
        "blocked by core.git:reset-hard",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);

    try testing.expect(isSixDigitNumeric(issued.record.short_code));
    try testing.expectEqual(@as(usize, 64), issued.record.full_hash.len);
    try testing.expectEqualStrings("git reset --hard HEAD", issued.record.command_raw);
    try testing.expectEqualStrings("/repo", issued.record.cwd);
    try testing.expect(issued.record.single_use);
    try testing.expect(issued.record.consumed_at == null);
    try testing.expectEqual(schema_version, issued.record.schema_version);
    // TTL default: expires after default_ttl_hours from now (24h).
    try testing.expectEqualStrings("2026-07-26T15:00:00Z", issued.record.expires_at);

    const raw = try readFileAbsolute(paths.pending);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, issued.record.short_code) != null);
    try testing.expect(std.mem.indexOf(u8, raw, "git reset --hard HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "short_code") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "full_hash") != null);
}

test "s3-once-store: issue redeem exact command+scope match" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git reset --hard HEAD",
        "/work/project",
        "destructive reset blocked",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);
    const code = issued.record.short_code;

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        code,
        fixed_now,
        .cwd,
        "/work/project",
    );
    defer freeAllowOnceEntry(allocator, entry);

    try testing.expectEqualStrings(code, entry.source_short_code);
    try testing.expectEqualStrings("git reset --hard HEAD", entry.command_raw);
    try testing.expect(entry.scope_kind == .cwd);
    try testing.expectEqualStrings("/work/project", entry.scope_path);
    try testing.expect(entry.single_use);
    try testing.expect(entry.consumed_at == null);

    // Exact command + matching cwd → hit (consume=false so store stays for later asserts).
    const hit = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "git reset --hard HEAD",
        "/work/project",
        fixed_now,
        false,
    );
    try testing.expect(hit != null);
    if (hit) |h| freeAllowOnceEntry(allocator, h);

    // Near-miss command must not match.
    const miss_cmd = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "git reset --hard HEAD~1",
        "/work/project",
        fixed_now,
        false,
    );
    try testing.expect(miss_cmd == null);
}

test "s3-once-store: wrong cwd does not match cwd-scoped entry" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "rm -rf /tmp/scratch",
        "/allowed/cwd",
        "cleanup blocked",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        issued.record.short_code,
        fixed_now,
        .cwd,
        "/allowed/cwd",
    );
    defer freeAllowOnceEntry(allocator, entry);

    const wrong = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "rm -rf /tmp/scratch",
        "/different/cwd",
        fixed_now,
        false,
    );
    try testing.expect(wrong == null);

    const right = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "rm -rf /tmp/scratch",
        "/allowed/cwd",
        fixed_now,
        false,
    );
    try testing.expect(right != null);
    if (right) |h| freeAllowOnceEntry(allocator, h);
}

test "s3-once-store: expired pending cannot redeem" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    // Issue in the past with TTL that is already expired relative to fixed_now.
    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git reset --hard HEAD",
        "/repo",
        "old block",
        past_time, // created 2026-07-24 → expires 2026-07-25T00:00:00Z < fixed_now
        true,
    );
    defer issued.deinit(allocator);

    // Explicitly ensure the written record is expired at fixed_now.
    try testing.expect(isExpired(issued.record.expires_at, fixed_now));

    const result = redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        issued.record.short_code,
        fixed_now,
        .cwd,
        "/repo",
    );
    try testing.expectError(error.Expired, result);

    // Allow-once store must remain empty (no silent redeem).
    var loaded = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), loaded.list.entries.len);
}

test "s3-once-store: redeem consumes pending so code cannot redeem twice" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git clean -fdx",
        "/repo",
        "clean blocked",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);
    const code = try allocator.dupe(u8, issued.record.short_code);
    defer allocator.free(code);

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        code,
        fixed_now,
        .cwd,
        "/repo",
    );
    freeAllowOnceEntry(allocator, entry);

    const second = redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        code,
        fixed_now,
        .cwd,
        "/repo",
    );
    // Second redeem: code gone from pending → CodeNotFound (or AlreadyConsumed).
    try testing.expect(second == error.CodeNotFound or second == error.AlreadyConsumed or second == error.Expired);
}

// ── Acceptance 2: consume removes single-use; list / revoke / clear ──────────

test "s3-once-store: consume removes single-use entry; second match misses" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git reset --hard HEAD",
        "/repo",
        "once only",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        issued.record.short_code,
        fixed_now,
        .cwd,
        "/repo",
    );
    freeAllowOnceEntry(allocator, entry);

    const first = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "git reset --hard HEAD",
        "/repo",
        fixed_now,
        true, // consume
    );
    try testing.expect(first != null);
    if (first) |h| freeAllowOnceEntry(allocator, h);

    const second = try matchAllowOnce(
        io,
        allocator,
        paths.allow_once,
        "git reset --hard HEAD",
        "/repo",
        fixed_now,
        true,
    );
    try testing.expect(second == null);

    // Store file should have no active entries.
    var loaded = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), loaded.list.entries.len);
}

test "s3-once-store: match with consume=false leaves single-use entry intact" {
    // Explain / dry-run path: match + attribute without burning the exception.
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(
        io,
        allocator,
        paths.pending,
        "git reset --hard HEAD",
        "/repo",
        "explain must not consume",
        fixed_now,
        true,
    );
    defer issued.deinit(allocator);

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        issued.record.short_code,
        fixed_now,
        .cwd,
        "/repo",
    );
    freeAllowOnceEntry(allocator, entry);

    // Two non-consuming matches both hit.
    const a = try matchAllowOnce(io, allocator, paths.allow_once, "git reset --hard HEAD", "/repo", fixed_now, false);
    try testing.expect(a != null);
    if (a) |h| freeAllowOnceEntry(allocator, h);

    const b = try matchAllowOnce(io, allocator, paths.allow_once, "git reset --hard HEAD", "/repo", fixed_now, false);
    try testing.expect(b != null);
    if (b) |h| freeAllowOnceEntry(allocator, h);

    // Then a real consume burns it; subsequent match misses.
    const c = try matchAllowOnce(io, allocator, paths.allow_once, "git reset --hard HEAD", "/repo", fixed_now, true);
    try testing.expect(c != null);
    if (c) |h| freeAllowOnceEntry(allocator, h);

    const d = try matchAllowOnce(io, allocator, paths.allow_once, "git reset --hard HEAD", "/repo", fixed_now, true);
    try testing.expect(d == null);
}

test "s3-once-store: list revoke clear on allow-once store" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var a = try issuePending(io, allocator, paths.pending, "cmd-a", "/repo", "reason a long enough", fixed_now, true);
    defer a.deinit(allocator);
    var b = try issuePending(io, allocator, paths.pending, "cmd-b", "/repo", "reason b long enough", fixed_now, true);
    defer b.deinit(allocator);

    const ea = try redeem(io, allocator, paths.pending, paths.allow_once, a.record.short_code, fixed_now, .cwd, "/repo");
    defer freeAllowOnceEntry(allocator, ea);
    const eb = try redeem(io, allocator, paths.pending, paths.allow_once, b.record.short_code, fixed_now, .project, "/repo");
    defer freeAllowOnceEntry(allocator, eb);

    {
        var listed = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), listed.list.entries.len);
    }

    // Revoke by short code removes one.
    const rev = try revokeAllowOnce(io, allocator, paths.allow_once, a.record.short_code, fixed_now);
    try testing.expectEqual(@as(usize, 1), rev.removed);

    {
        var listed = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), listed.list.entries.len);
        try testing.expectEqualStrings("cmd-b", listed.list.entries[0].command_raw);
    }

    // Revoke by full hash also works.
    const rev_hash = try revokeAllowOnce(io, allocator, paths.allow_once, b.record.full_hash, fixed_now);
    try testing.expectEqual(@as(usize, 1), rev_hash.removed);

    {
        var listed = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), listed.list.entries.len);
    }

    // Re-seed and clear all.
    var c = try issuePending(io, allocator, paths.pending, "cmd-c", "/repo", "reason c long enough", fixed_now, true);
    defer c.deinit(allocator);
    const ec = try redeem(io, allocator, paths.pending, paths.allow_once, c.record.short_code, fixed_now, .cwd, "/repo");
    freeAllowOnceEntry(allocator, ec);

    const cleared = try clearAllowOnce(io, allocator, paths.allow_once, fixed_now);
    try testing.expectEqual(@as(usize, 1), cleared.removed);

    {
        var listed = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), listed.list.entries.len);
    }
}

test "s3-once-store: list revoke clear on pending store" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var a = try issuePending(io, allocator, paths.pending, "pend-a", "/repo", "pending reason a", fixed_now, true);
    defer a.deinit(allocator);
    var b = try issuePending(io, allocator, paths.pending, "pend-b", "/repo", "pending reason b", fixed_now, true);
    defer b.deinit(allocator);

    {
        var listed = try loadPendingActive(io, allocator, paths.pending, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), listed.list.records.len);
    }

    {
        var by_code = try lookupPendingByCode(io, allocator, paths.pending, a.record.short_code, fixed_now);
        defer by_code.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), by_code.list.records.len);
        try testing.expectEqualStrings("pend-a", by_code.list.records[0].command_raw);
    }

    const rev = try revokePending(io, allocator, paths.pending, a.record.short_code, fixed_now);
    try testing.expectEqual(@as(usize, 1), rev.removed);

    {
        var listed = try loadPendingActive(io, allocator, paths.pending, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), listed.list.records.len);
    }

    const cleared = try clearPending(io, allocator, paths.pending, fixed_now);
    try testing.expectEqual(@as(usize, 1), cleared.removed);

    {
        var listed = try loadPendingActive(io, allocator, paths.pending, fixed_now);
        defer listed.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), listed.list.records.len);
    }
}

// ── Acceptance 3: prune / bounded growth ─────────────────────────────────────

test "s3-once-store: loadPendingActive prunes expired and consumed from file" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    // Seed via issue, then hand-craft additional expired/consumed lines in the file.
    var active = try issuePending(
        io,
        allocator,
        paths.pending,
        "git status",
        "/repo",
        "still valid pending",
        fixed_now,
        true,
    );
    defer active.deinit(allocator);

    // Append expired + consumed raw JSONL lines (schema-compatible).
    const existing = try readFileAbsolute(paths.pending);
    defer allocator.free(existing);

    const extra = try std.fmt.allocPrint(allocator,
        \\{{"schema_version":1,"short_code":"111111","full_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-07-20T00:00:00Z","expires_at":"2026-07-21T00:00:00Z","cwd":"/repo","command_raw":"old cmd","reason":"expired","single_use":true,"consumed_at":null}}
        \\{{"schema_version":1,"short_code":"222222","full_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","created_at":"{s}","expires_at":"2026-07-26T15:00:00Z","cwd":"/repo","command_raw":"used cmd","reason":"consumed","single_use":true,"consumed_at":"{s}"}}
        \\
    , .{ fixed_now, fixed_now });
    defer allocator.free(extra);

    const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, extra });
    defer allocator.free(merged);
    try writeFileAbsolute(paths.pending, merged);

    var loaded = try loadPendingActive(io, allocator, paths.pending, fixed_now);
    defer loaded.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), loaded.list.records.len);
    try testing.expectEqualStrings("git status", loaded.list.records[0].command_raw);
    try testing.expect(loaded.maintenance.pruned_expired >= 1);
    try testing.expect(loaded.maintenance.pruned_consumed >= 1);

    // File rewritten to active-only (no expired short code left).
    const after = try readFileAbsolute(paths.pending);
    defer allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "111111") == null);
    try testing.expect(std.mem.indexOf(u8, after, "222222") == null);
    try testing.expect(std.mem.indexOf(u8, after, active.record.short_code) != null);
}

test "s3-once-store: loadAllowOnceActive prunes expired entries" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(io, allocator, paths.pending, "alive-cmd", "/repo", "alive reason text", fixed_now, true);
    defer issued.deinit(allocator);
    const entry = try redeem(io, allocator, paths.pending, paths.allow_once, issued.record.short_code, fixed_now, .cwd, "/repo");
    freeAllowOnceEntry(allocator, entry);

    const existing = try readFileAbsolute(paths.allow_once);
    defer allocator.free(existing);

    const expired_line =
        \\{"schema_version":1,"source_short_code":"999999","source_full_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","created_at":"2026-07-20T00:00:00Z","expires_at":"2026-07-21T00:00:00Z","scope_kind":"cwd","scope_path":"/repo","command_raw":"dead-cmd","reason":"expired allow","single_use":true,"consumed_at":null}
        \\
    ;
    const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, expired_line });
    defer allocator.free(merged);
    try writeFileAbsolute(paths.allow_once, merged);

    var loaded = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), loaded.list.entries.len);
    try testing.expectEqualStrings("alive-cmd", loaded.list.entries[0].command_raw);
    try testing.expect(loaded.maintenance.pruned_expired >= 1);

    const after = try readFileAbsolute(paths.allow_once);
    defer allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "dead-cmd") == null);
    try testing.expect(std.mem.indexOf(u8, after, "alive-cmd") != null);
}

test "s3-once-store: corrupt JSONL lines skipped without panic" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(io, allocator, paths.pending, "good-cmd", "/repo", "good reason text", fixed_now, true);
    defer issued.deinit(allocator);

    const existing = try readFileAbsolute(paths.pending);
    defer allocator.free(existing);
    const merged = try std.fmt.allocPrint(allocator, "not-json-at-all\n{s}{{broken\n", .{existing});
    defer allocator.free(merged);
    try writeFileAbsolute(paths.pending, merged);

    var loaded = try loadPendingActive(io, allocator, paths.pending, fixed_now);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), loaded.list.records.len);
    try testing.expectEqualStrings("good-cmd", loaded.list.records[0].command_raw);
    try testing.expect(loaded.maintenance.parse_errors >= 1);
}

test "s3-once-store: bounded growth refuses or rotates past max_pending_lines" {
    // Product law: no unbounded silent growth. When active pending exceeds
    // max_pending_lines, issuePending must either rotate (keep live file ≤ cap)
    // or return StoreFull — never silently append without bound.
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    // Build a file with max_pending_lines + 50 synthetic active records.
    // Compact lines keep the fixture under max_pending_bytes while over the line cap.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < max_pending_lines + 50) : (i += 1) {
        // Minimal schema-valid line; unique short_code via zero-padded index mod 1e6.
        const line = try std.fmt.allocPrint(allocator,
            \\{{"schema_version":1,"short_code":"{d:0>6}","full_hash":"{d:0>64}","created_at":"{s}","expires_at":"2026-07-26T15:00:00Z","cwd":"/r","command_raw":"c{d}","reason":"b","single_use":true,"consumed_at":null}}
            \\
        , .{ i % 1_000_000, i, fixed_now, i });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    try writeFileAbsolute(paths.pending, buf.items);

    // Precondition: file has more than max_pending_lines lines.
    {
        const raw = try readFileAbsolute(paths.pending);
        defer allocator.free(raw);
        var lines: usize = 0;
        var iter = std.mem.splitScalar(u8, raw, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) lines += 1;
        }
        try testing.expect(lines > max_pending_lines);
    }

    if (issuePending(
        io,
        allocator,
        paths.pending,
        "overflow-cmd",
        "/repo",
        "should not grow unbounded",
        fixed_now,
        true,
    )) |issued_const| {
        var issued = issued_const;
        defer issued.deinit(allocator);
        // Rotation path: live file must be within cap after issue.
        const raw = try readFileAbsolute(paths.pending);
        defer allocator.free(raw);
        var lines: usize = 0;
        var iter = std.mem.splitScalar(u8, raw, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) lines += 1;
        }
        try testing.expect(lines <= max_pending_lines);
        // New entry present.
        try testing.expect(std.mem.indexOf(u8, raw, "overflow-cmd") != null);
    } else |err| {
        // Refusal path is also acceptable product behavior.
        try testing.expect(err == error.StoreFull);
    }
}

test "s3-once-store: missing store files load as empty not error" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var pending = try loadPendingActive(io, allocator, paths.pending, fixed_now);
    defer pending.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pending.list.records.len);

    var allow = try loadAllowOnceActive(io, allocator, paths.allow_once, fixed_now);
    defer allow.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), allow.list.entries.len);

    const miss = try matchAllowOnce(io, allocator, paths.allow_once, "anything", "/repo", fixed_now, true);
    try testing.expect(miss == null);
}

test "s3-once-store: project scope matches subdirectory cwd" {
    var tmp = try tmpRoot();
    defer {
        allocator.free(tmp.path);
        tmp.dir.cleanup();
    }
    const paths = try storePaths(tmp.path);
    defer {
        allocator.free(paths.pending);
        allocator.free(paths.allow_once);
    }

    var issued = try issuePending(io, allocator, paths.pending, "npm install", "/repo", "install once in project", fixed_now, true);
    defer issued.deinit(allocator);

    const entry = try redeem(
        io,
        allocator,
        paths.pending,
        paths.allow_once,
        issued.record.short_code,
        fixed_now,
        .project,
        "/repo",
    );
    freeAllowOnceEntry(allocator, entry);

    const sub = try matchAllowOnce(io, allocator, paths.allow_once, "npm install", "/repo/packages/cli", fixed_now, false);
    try testing.expect(sub != null);
    if (sub) |h| freeAllowOnceEntry(allocator, h);

    const outside = try matchAllowOnce(io, allocator, paths.allow_once, "npm install", "/other", fixed_now, false);
    try testing.expect(outside == null);
}

test "s3-once-store: constants and file names match product brand" {
    try testing.expectEqual(@as(u32, 1), schema_version);
    try testing.expectEqual(@as(i64, 24), default_ttl_hours);
    try testing.expectEqual(@as(usize, 10_000), max_pending_lines);
    try testing.expectEqual(@as(u64, 10 * 1024 * 1024), max_pending_bytes);
    try testing.expectEqualStrings("pending_exceptions.jsonl", pending_file_name);
    try testing.expectEqualStrings("allow_once.jsonl", allow_once_file_name);
}
