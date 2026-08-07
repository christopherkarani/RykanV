//! OpenClaw protection honesty for doctor/install surfaces.
//! Standing product claim until live-host E2E exists (Wave 1): npm/ClawHub is
//! unprotected; hook grade is unverified; prefer wrapper `ryk run -- openclaw`.

const std = @import("std");
const core = @import("ryk_core").core;

/// Shared enforcement note (plain + JSON). Single source of truth for doctor copy.
pub const enforcement_note =
    "unprotected for npm/ClawHub (hooks no-op); prefer wrapper: ryk run -- openclaw";

/// Hook grade until real-host E2E proves veto. Not a boolean "enforcing" claim.
pub const hook_grade = "unverified";

/// npm/ClawHub install path label (hooks no-op in CLI-metadata mode).
pub const npm_path_label = "unprotected";

/// Preferred protection path (grade wrapper).
pub const preferred_wrapper = "ryk run -- openclaw";

/// Plain-text honesty lines for `ryk plugin doctor openclaw`.
pub fn writeDoctorHonesty(stdout: anytype) !void {
    try stdout.print("  enforcement: {s}\n", .{enforcement_note});
    try stdout.writeAll("  hook grade: unverified (no live host E2E); installed != protected\n");
    try stdout.writeAll("  install: use 'ryk plugin install openclaw --dry-run' to preview (plumbing only)\n");
    try stdout.writeAll("  note: npm/ClawHub package ryk-openclaw-plugin is published for distribution; not an enforcement install\n");
}

/// Append OpenClaw honesty fields inside an existing `openclaw_paths` JSON object
/// (caller has already written detection_note and a trailing comma is expected before this).
pub fn writePathsJsonHonesty(stdout: anytype) !void {
    try stdout.writeAll("    \"enforcement_note\": ");
    try core.util.writeJsonString(stdout, enforcement_note);
    try stdout.writeAll(",\n");
    try stdout.writeAll("    \"hook_grade\": ");
    try core.util.writeJsonString(stdout, hook_grade);
    try stdout.writeAll(",\n");
    try stdout.writeAll("    \"npm_path\": ");
    try core.util.writeJsonString(stdout, npm_path_label);
    try stdout.writeAll("\n");
}

/// Install-path guidance (dry-run / install openclaw).
pub fn writeInstallPaths(stdout: anytype) !void {
    try stdout.writeAll("  install paths for OpenClaw:\n");
    try stdout.print("    preferred protection: {s}  (wrapper; not npm)\n", .{preferred_wrapper});
    try stdout.writeAll("    local:   openclaw plugins install ./integrations/openclaw-plugin\n");
    try stdout.writeAll("    npm:     openclaw plugins install npm:ryk-openclaw-plugin (published; unprotected — hooks no-op)\n");
    try stdout.writeAll("    clawhub: openclaw plugins install clawhub:ryk-openclaw-plugin (published; unprotected — hooks no-op)\n");
}

test "openclaw honesty constants are stable tokens" {
    try std.testing.expect(std.mem.indexOf(u8, enforcement_note, "unprotected") != null);
    try std.testing.expect(std.mem.indexOf(u8, enforcement_note, preferred_wrapper) != null);
    try std.testing.expectEqualStrings("unverified", hook_grade);
    try std.testing.expectEqualStrings("unprotected", npm_path_label);
}

test "writeDoctorHonesty includes enforcement and wrapper" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDoctorHonesty(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "unprotected") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, preferred_wrapper) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "installed != protected") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hook grade: unverified") != null);
}

test "writePathsJsonHonesty uses hook_grade not hook_enforcing" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePathsJsonHonesty(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"enforcement_note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hook_grade\": \"unverified\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"npm_path\": \"unprotected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hook_enforcing") == null);
}
