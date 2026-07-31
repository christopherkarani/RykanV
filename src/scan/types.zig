//! Scan finding model (session forensics).
const std = @import("std");
const shell_engine = @import("../shell_engine/mod.zig");

pub const Host = enum {
    claude,
    codex,
    pi,
    opencode,
    grok,
    ryk,

    pub fn toString(self: Host) []const u8 {
        return @tagName(self);
    }
};

pub const FindingKind = enum {
    danger,
    secret_access,
    secret_material,

    pub fn toString(self: FindingKind) []const u8 {
        return @tagName(self);
    }

    /// Higher = prefer earlier in ranked list when severity ties.
    pub fn rankWeight(self: FindingKind) u8 {
        return switch (self) {
            .secret_material => 3,
            .secret_access => 2,
            .danger => 1,
        };
    }
};

pub const Severity = shell_engine.Severity;

pub const Finding = struct {
    kind: FindingKind,
    severity: Severity,
    host: Host,
    session_id: []const u8,
    path: []const u8,
    timestamp_secs: i64,
    title: []const u8,
    detail: []const u8,
    /// Optional redacted fingerprint/label for secret findings.
    secret_label: ?[]const u8 = null,
    secret_fingerprint: ?[]const u8 = null,
    evidence_ref: []const u8,
    /// How many raw hits were collapsed into this row (fingerprint dedupe).
    occurrence_count: usize = 1,

    pub fn deinit(self: *Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.detail);
        if (self.secret_label) |s| allocator.free(s);
        if (self.secret_fingerprint) |s| allocator.free(s);
        allocator.free(self.evidence_ref);
        self.* = undefined;
    }
};

pub const HostStatus = enum {
    ok,
    not_found,
    unreadable,
    unsupported,
    empty,

    pub fn toString(self: HostStatus) []const u8 {
        return @tagName(self);
    }
};

pub const HostAccount = struct {
    host: Host,
    status: HostStatus,
    sessions_seen: usize = 0,
    note: []const u8 = "",
};

pub const Scorecard = struct {
    window_days: ?u32,
    all_time: bool,
    sessions_scanned: usize = 0,
    danger_count: usize = 0,
    secret_access_count: usize = 0,
    secret_material_count: usize = 0,
    // Length bound to Host enum so new hosts cannot silently desync the scorecard.
    hosts: [@typeInfo(Host).@"enum".fields.len]HostAccount = blk: {
        var arr: [@typeInfo(Host).@"enum".fields.len]HostAccount = undefined;
        for (@typeInfo(Host).@"enum".fields, 0..) |field, i| {
            arr[i] = .{ .host = @enumFromInt(field.value), .status = .not_found };
        }
        break :blk arr;
    },

    pub fn setHost(self: *Scorecard, host: Host, status: HostStatus, sessions: usize, note: []const u8) void {
        const idx = @intFromEnum(host);
        self.hosts[idx] = .{
            .host = host,
            .status = status,
            .sessions_seen = sessions,
            .note = note,
        };
    }
};

pub const ScanResult = struct {
    scorecard: Scorecard,
    findings: []Finding,
    total_findings: usize,
    shown_cap: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScanResult) void {
        for (self.findings) |*f| f.deinit(self.allocator);
        self.allocator.free(self.findings);
        self.* = undefined;
    }
};

pub const default_list_cap: usize = 20;
pub const default_window_days: u32 = 30;
pub const max_file_bytes: usize = 512 * 1024;
pub const max_line_bytes: usize = 64 * 1024;
pub const max_sessions_per_host: usize = 80;
pub const max_commands_per_session: usize = 100;
pub const max_detail_len: usize = 240;

/// Severity ranks for ordering (critical first).
pub fn severityRank(sev: Severity) u8 {
    return switch (sev) {
        .critical => 4,
        .high => 3,
        .medium => 2,
        .low => 1,
    };
}

/// Default danger cut: medium and above (includes critical).
pub fn severityMeetsDefaultCut(sev: Severity) bool {
    return severityRank(sev) >= severityRank(.medium);
}

test "severity default cut keeps medium high critical drops low" {
    try std.testing.expect(severityMeetsDefaultCut(.critical));
    try std.testing.expect(severityMeetsDefaultCut(.high));
    try std.testing.expect(severityMeetsDefaultCut(.medium));
    try std.testing.expect(!severityMeetsDefaultCut(.low));
}

test "finding kind rank prefers secrets over danger" {
    try std.testing.expect(FindingKind.secret_material.rankWeight() > FindingKind.danger.rankWeight());
    try std.testing.expect(FindingKind.secret_access.rankWeight() > FindingKind.danger.rankWeight());
}
