//! Immutable evidence manifest for security gate verification (S-GLO-09).
//!
//! Evidence files live under gitignored planning/security/evidence/ and must never
//! contain raw secret values or live canary bodies.

const std = @import("std");
const util = @import("ryk_core").core.util;

pub const schema_version: u16 = 1;

/// Dual-proof CTRL-ATTACH detail tokens allowed when `ctrl_attach.ok` is true.
/// New production attach proofs must be added here before manifests may claim ok.
// Unit dual-proof (test-fast greps) and packaged binary attach.
pub const allowlisted_attach_details = [_][]const u8{
    "zig_real_fs_deny_canary_and_handshake",
    "ryk_run_os_sandbox_on_active",
};

pub const ControlResult = struct {
    ok: bool,
    detail: []const u8 = "",
};

pub const Manifest = struct {
    schema_version: u16 = schema_version,
    gate_ids: []const []const u8,
    case_id: []const u8,
    source_commit: []const u8,
    binary_sha256: []const u8,
    platform_os: []const u8,
    platform_arch: []const u8,
    backend_id: []const u8,
    profile_hash: []const u8 = "",
    command: []const u8,
    exit_code: i32 = 0,
    ctrl_baseline: ControlResult,
    /// Optional/partial prepare path; not required by allControlsPass.
    ctrl_prepare: ControlResult = .{ .ok = false },
    ctrl_attach: ControlResult,
    test_deny: ControlResult,
    ctrl_neighbor: ControlResult,
    ctrl_off: ControlResult,
    canary_fingerprint: []const u8 = "",
    rerun: []const u8 = "",

    pub fn allControlsPass(self: Manifest) bool {
        // ctrl_prepare is optional/partial and is intentionally not required.
        if (!(self.ctrl_baseline.ok and
            self.ctrl_attach.ok and
            self.test_deny.ok and
            self.ctrl_neighbor.ok and
            self.ctrl_off.ok)) return false;
        // Booleans alone are not enough: attach detail must pass validate quality.
        self.validate() catch return false;
        return true;
    }

    pub fn validate(self: Manifest) !void {
        if (self.schema_version != schema_version) return error.UnsupportedSchemaVersion;
        if (self.gate_ids.len == 0) return error.MissingGateIds;
        if (self.case_id.len == 0) return error.MissingCaseId;
        if (self.source_commit.len == 0) return error.MissingSourceCommit;
        if (self.binary_sha256.len == 0) return error.MissingBinaryHash;
        if (self.platform_os.len == 0) return error.MissingPlatform;
        if (self.command.len == 0) return error.MissingCommand;
        // Probe-only / prepare-only attach is forbidden for enforcement manifests (F-1).
        if (std.mem.eql(u8, self.ctrl_attach.detail, "capability_probe")) return error.ProbeOnlyAttach;
        if (std.mem.eql(u8, self.ctrl_attach.detail, "zig_status_pipe_or_prepare_handshake")) return error.PrepareOnlyAttach;
        if (std.mem.indexOf(u8, self.ctrl_attach.detail, "prepare") != null and
            std.mem.indexOf(u8, self.ctrl_attach.detail, "without") != null)
        {
            return error.PrepareOnlyAttach;
        }
        // Unit-canary-only attach (no production handshake) is forbidden for enforcement.
        if (std.mem.eql(u8, self.ctrl_attach.detail, "zig_real_fs_deny_canary")) return error.UnitCanaryOnlyAttach;
        // CTRL-ATTACH without TEST-DENY is not an enforcement claim.
        if (self.ctrl_attach.ok and !self.test_deny.ok) return error.AttachWithoutDeny;
        // When attach claims success, detail must be dual-proof allowlisted (not a freeform denylist).
        if (self.ctrl_attach.ok and !isAllowlistedAttachDetail(self.ctrl_attach.detail)) {
            return error.AttachDetailNotAllowlisted;
        }
        // Packaged binary attach must carry a real profile hash.
        if (self.ctrl_attach.ok and
            std.mem.eql(u8, self.ctrl_attach.detail, "ryk_run_os_sandbox_on_active") and
            self.profile_hash.len != 64)
        {
            return error.MissingProfileHash;
        }
    }
};

fn isAllowlistedAttachDetail(detail: []const u8) bool {
    for (allowlisted_attach_details) |allowed| {
        if (std.mem.eql(u8, detail, allowed)) return true;
    }
    return false;
}

fn writeJsonField(w: anytype, key: []const u8, value: []const u8, trailing: []const u8) !void {
    try w.writeAll("  ");
    try util.writeJsonString(w, key);
    try w.writeAll(": ");
    try util.writeJsonString(w, value);
    try w.writeAll(trailing);
}

pub fn writeJson(allocator: std.mem.Allocator, manifest: Manifest) ![]u8 {
    try manifest.validate();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n");
    try w.print("  \"schema_version\": {d},\n", .{manifest.schema_version});
    try w.writeAll("  \"gate_ids\": [");
    for (manifest.gate_ids, 0..) |id, i| {
        if (i > 0) try w.writeAll(", ");
        try util.writeJsonString(w, id);
    }
    try w.writeAll("],\n");
    try writeJsonField(w, "case_id", manifest.case_id, ",\n");
    try writeJsonField(w, "source_commit", manifest.source_commit, ",\n");
    try writeJsonField(w, "binary_sha256", manifest.binary_sha256, ",\n");
    try w.writeAll("  \"platform\": {\"os\": ");
    try util.writeJsonString(w, manifest.platform_os);
    try w.writeAll(", \"arch\": ");
    try util.writeJsonString(w, manifest.platform_arch);
    try w.writeAll("},\n");
    try writeJsonField(w, "backend_id", manifest.backend_id, ",\n");
    try writeJsonField(w, "profile_hash", manifest.profile_hash, ",\n");
    try writeJsonField(w, "command", manifest.command, ",\n");
    try w.print("  \"exit_code\": {d},\n", .{manifest.exit_code});
    try w.writeAll("  \"controls\": {\n");
    try writeControl(w, "CTRL-BASELINE", manifest.ctrl_baseline);
    try w.writeAll(",\n");
    try writeControl(w, "CTRL-PREPARE", manifest.ctrl_prepare);
    try w.writeAll(",\n");
    try writeControl(w, "CTRL-ATTACH", manifest.ctrl_attach);
    try w.writeAll(",\n");
    try writeControl(w, "TEST-DENY", manifest.test_deny);
    try w.writeAll(",\n");
    try writeControl(w, "CTRL-NEIGHBOR", manifest.ctrl_neighbor);
    try w.writeAll(",\n");
    try writeControl(w, "CTRL-OFF", manifest.ctrl_off);
    try w.writeAll("\n  },\n");
    try writeJsonField(w, "canary_fingerprint", manifest.canary_fingerprint, ",\n");
    try writeJsonField(w, "rerun", manifest.rerun, "\n");
    try w.writeAll("}\n");
    return try aw.toOwnedSlice();
}

fn writeControl(w: anytype, name: []const u8, result: ControlResult) !void {
    try w.writeAll("    ");
    try util.writeJsonString(w, name);
    try w.writeAll(": {\"ok\": ");
    try w.print("{}", .{result.ok});
    try w.writeAll(", \"detail\": ");
    try util.writeJsonString(w, result.detail);
    try w.writeAll("}");
}

test "evidence manifest rejects empty required fields" {
    const incomplete = Manifest{
        .gate_ids = &.{},
        .case_id = "",
        .source_commit = "",
        .binary_sha256 = "",
        .platform_os = "",
        .platform_arch = "arm64",
        .backend_id = "none",
        .command = "",
        .ctrl_baseline = .{ .ok = false },
        .ctrl_prepare = .{ .ok = false },
        .ctrl_attach = .{ .ok = false },
        .test_deny = .{ .ok = false },
        .ctrl_neighbor = .{ .ok = false },
        .ctrl_off = .{ .ok = false },
    };
    try std.testing.expectError(error.MissingGateIds, incomplete.validate());
}

test "evidence manifest rejects capability_probe as CTRL-ATTACH (S-GLO-09)" {
    const bad = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "home-deny",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "ryk run -- true",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_prepare = .{ .ok = true, .detail = "applySelf" },
        .ctrl_attach = .{ .ok = true, .detail = "capability_probe" },
        .test_deny = .{ .ok = true },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.ProbeOnlyAttach, bad.validate());
}

test "evidence manifest rejects prepare-only and attach-without-deny (F-1)" {
    const prepare_only = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "prep",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "test-fast",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "zig_status_pipe_or_prepare_handshake" },
        .test_deny = .{ .ok = true },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.PrepareOnlyAttach, prepare_only.validate());

    const no_deny = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "no-deny",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "test-fast",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary_and_handshake" },
        .test_deny = .{ .ok = false },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.AttachWithoutDeny, no_deny.validate());
}

test "evidence manifest rejects zig_real_fs_deny_canary as CTRL-ATTACH" {
    const bad = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "home-deny",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "ryk run -- true",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_prepare = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary" },
        .test_deny = .{ .ok = true },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.UnitCanaryOnlyAttach, bad.validate());
}

test "valid enforcement manifest serializes and reports all controls" {
    const good = Manifest{
        .gate_ids = &.{ "P1-I-01", "P1-R-01" },
        .case_id = "home-secret-read",
        .source_commit = "77e49049",
        .binary_sha256 = "aabbcc",
        .platform_os = "macos",
        .platform_arch = "arm64",
        .backend_id = "none",
        .profile_hash = "",
        .command = "ryk run --os-sandbox off -- true",
        .ctrl_baseline = .{ .ok = true, .detail = "canary readable" },
        .ctrl_prepare = .{ .ok = true, .detail = "platform_prepare" },
        .ctrl_attach = .{ .ok = false, .detail = "no_apply_wired" },
        .test_deny = .{ .ok = false, .detail = "expected until landlock" },
        .ctrl_neighbor = .{ .ok = true, .detail = "workspace ok" },
        .ctrl_off = .{ .ok = true, .detail = "off path" },
        .canary_fingerprint = "sha256:00",
        .rerun = "./scripts/os-sandbox-adversarial-e2e.sh --case home-secret-read",
    };
    try good.validate();
    try std.testing.expect(!good.allControlsPass());
    const json = try writeJson(std.testing.allocator, good);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "CTRL-BASELINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "CTRL-PREPARE") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "CTRL-ATTACH") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TEST-DENY") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "P1-I-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "capability_probe") == null);
    // CTRL-PREPARE appears after BASELINE and before ATTACH (shell order).
    const prepare_pos = std.mem.indexOf(u8, json, "CTRL-PREPARE").?;
    const baseline_pos = std.mem.indexOf(u8, json, "CTRL-BASELINE").?;
    const attach_pos = std.mem.indexOf(u8, json, "CTRL-ATTACH").?;
    try std.testing.expect(baseline_pos < prepare_pos);
    try std.testing.expect(prepare_pos < attach_pos);
}

test "dual-proof attach detail with handshake is allowed" {
    // ctrl_prepare left at default (ok=false): prepare is optional for allControlsPass.
    const dual = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "home-deny",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "macos",
        .platform_arch = "arm64",
        .backend_id = "seatbelt",
        .command = "ryk run -- true",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary_and_handshake" },
        .test_deny = .{ .ok = true },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try dual.validate();
    try std.testing.expect(!dual.ctrl_prepare.ok);
    try std.testing.expect(dual.allControlsPass());
}

test "writeJson escapes quotes backslash and newlines in string fields" {
    const m = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "quote\"case",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "ryk run -- \"foo\\bar\"\nbaz",
        .ctrl_baseline = .{ .ok = true, .detail = "line1\nline2" },
        .ctrl_prepare = .{ .ok = false, .detail = "prep \"x\"" },
        .ctrl_attach = .{ .ok = false, .detail = "has \"quotes\" and\\slash" },
        .test_deny = .{ .ok = false, .detail = "deny\tdetail" },
        .ctrl_neighbor = .{ .ok = true, .detail = "ok" },
        .ctrl_off = .{ .ok = true, .detail = "off" },
        .canary_fingerprint = "fp\"1",
        .rerun = "rerun\ncmd",
    };
    try m.validate();
    const json = try writeJson(std.testing.allocator, m);
    defer std.testing.allocator.free(json);

    // Raw unescaped quote/newline must not appear inside string values as bare chars that break JSON.
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\\") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("quote\"case", root.get("case_id").?.string);
    try std.testing.expectEqualStrings("ryk run -- \"foo\\bar\"\nbaz", root.get("command").?.string);
    const controls = root.get("controls").?.object;
    try std.testing.expectEqualStrings("has \"quotes\" and\\slash", controls.get("CTRL-ATTACH").?.object.get("detail").?.string);
    try std.testing.expectEqualStrings("line1\nline2", controls.get("CTRL-BASELINE").?.object.get("detail").?.string);
    try std.testing.expectEqualStrings("fp\"1", root.get("canary_fingerprint").?.string);
    try std.testing.expectEqualStrings("rerun\ncmd", root.get("rerun").?.string);
}

test "ctrl_attach ok requires allowlisted dual-proof detail" {
    const base = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "home-deny",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .command = "ryk run -- true",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "" },
        .test_deny = .{ .ok = true },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.AttachDetailNotAllowlisted, base.validate());
    try std.testing.expect(!base.allControlsPass());

    var probe_ok = base;
    probe_ok.ctrl_attach = .{ .ok = true, .detail = "capability_probe_ok" };
    try std.testing.expectError(error.AttachDetailNotAllowlisted, probe_ok.validate());
    try std.testing.expect(!probe_ok.allControlsPass());

    var typo = base;
    typo.ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary_and_handshak" };
    try std.testing.expectError(error.AttachDetailNotAllowlisted, typo.validate());
    try std.testing.expect(!typo.allControlsPass());

    // ok=false keeps freeform detail (not on allowlist).
    var freeform = base;
    freeform.ctrl_attach = .{ .ok = false, .detail = "not_proven_yet" };
    freeform.test_deny = .{ .ok = false };
    try freeform.validate();
    try std.testing.expect(!freeform.allControlsPass());

    // Good dual-proof + deny ok passes validate and allControlsPass.
    var good = base;
    good.ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary_and_handshake" };
    try good.validate();
    try std.testing.expect(good.allControlsPass());
}

test "e2e-shaped unit dual-proof manifest validates and allControlsPass" {
    // Mirrors scripts/os-sandbox-adversarial-e2e.sh unit dual-proof emission.
    const unit = Manifest{
        .gate_ids = &.{ "P1-I-01", "P0-I-06", "M-11", "M-12", "F-1", "F-5" },
        .case_id = "ci-linux",
        .source_commit = "deadbeef",
        .binary_sha256 = "aabbccdd",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .profile_hash = "",
        .command = "./scripts/zig build test-fast (sandbox apply real-FS-deny proofs only for CTRL-ATTACH)",
        .exit_code = 0,
        .ctrl_baseline = .{ .ok = true, .detail = "binary_present" },
        .ctrl_prepare = .{ .ok = true, .detail = "zig_fork_apply_handshake" },
        .ctrl_attach = .{ .ok = true, .detail = "zig_real_fs_deny_canary_and_handshake" },
        .test_deny = .{ .ok = true, .detail = "outside_unreadable_under_sandbox" },
        .ctrl_neighbor = .{ .ok = true, .detail = "workspace_neighbor_rw" },
        .ctrl_off = .{ .ok = true, .detail = "apply_mode_off_disabled_receipt" },
        .canary_fingerprint = "zig-unit:real-fs-deny",
        .rerun = "./scripts/os-sandbox-adversarial-e2e.sh --case ci-linux",
    };
    try unit.validate();
    try std.testing.expect(unit.allControlsPass());
    const json = try writeJson(std.testing.allocator, unit);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "zig_real_fs_deny_canary_and_handshake") != null);
}

test "e2e-shaped packaged orca_run attach requires 64-hex profile_hash" {
    const hash64 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    var packaged = Manifest{
        .gate_ids = &.{ "P1-I-01", "P0-I-06", "M-11", "M-12", "F-1", "F-5" },
        .case_id = "ci-linux",
        .source_commit = "deadbeef",
        .binary_sha256 = "aabbccdd",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .profile_hash = "",
        .command = "ryk run --os-sandbox on -- /usr/bin/true (+ test-fast dual-proof support)",
        .exit_code = 0,
        .ctrl_baseline = .{ .ok = true, .detail = "binary_present" },
        .ctrl_prepare = .{ .ok = true, .detail = "zig_fork_apply_handshake" },
        .ctrl_attach = .{ .ok = true, .detail = "ryk_run_os_sandbox_on_active" },
        .test_deny = .{ .ok = true, .detail = "outside_unreadable_under_sandbox" },
        .ctrl_neighbor = .{ .ok = true, .detail = "workspace_neighbor_rw" },
        .ctrl_off = .{ .ok = true, .detail = "apply_mode_off_disabled_receipt" },
        .canary_fingerprint = "packaged:ryk_run_os_sandbox_on_active",
        .rerun = "./scripts/os-sandbox-adversarial-e2e.sh --case ci-linux",
    };
    try std.testing.expectError(error.MissingProfileHash, packaged.validate());
    try std.testing.expect(!packaged.allControlsPass());

    packaged.profile_hash = hash64;
    try packaged.validate();
    try std.testing.expect(packaged.allControlsPass());
    const json = try writeJson(std.testing.allocator, packaged);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "ryk_run_os_sandbox_on_active") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, hash64) != null);
}

test "e2e-shaped attach without TEST-DENY fails validate" {
    const bad = Manifest{
        .gate_ids = &.{"P1-I-01"},
        .case_id = "banner-only",
        .source_commit = "deadbeef",
        .binary_sha256 = "00",
        .platform_os = "linux",
        .platform_arch = "x86_64",
        .backend_id = "landlock",
        .profile_hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        .command = "ryk run --os-sandbox on",
        .ctrl_baseline = .{ .ok = true },
        .ctrl_attach = .{ .ok = true, .detail = "ryk_run_os_sandbox_on_active" },
        .test_deny = .{ .ok = false, .detail = "not_proven" },
        .ctrl_neighbor = .{ .ok = true },
        .ctrl_off = .{ .ok = true },
    };
    try std.testing.expectError(error.AttachWithoutDeny, bad.validate());
}
