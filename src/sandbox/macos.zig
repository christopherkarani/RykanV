const std = @import("std");
const builtin = @import("builtin");

const backend = @import("backend.zig");
const platform = @import("orca_core").platform;
const macos_seatbelt = @import("macos_seatbelt.zig");

pub const implemented = true;

pub fn detect() backend.ReportSet {
    var reports = backend.baseReports(.macos);
    backend.setReport(&reports, .process_supervision, .active, "macOS child process-group supervision and best-effort descendant cleanup are enabled");
    backend.setReport(&reports, .shell_wrapping, .wrapper_only, "sh, bash, and zsh are wrapped when resolved through the Orca shim PATH");
    backend.setReport(&reports, .path_shims, .wrapper_only, "Orca prepends session shims to PATH for wrapper-mediated command checks");
    backend.setReport(&reports, .network_observe, .observe_only, "network policy decisions are audited for Orca-mediated actions");
    backend.setReport(&reports, .network_enforce, .unavailable, "transparent macOS network enforcement is not installed; only wrapper/proxy-mediated hooks are available");
    backend.setReport(&reports, .user_namespaces, .unsupported, "Linux user namespaces are not a macOS feature");
    backend.setReport(&reports, .mount_namespaces, .unsupported, "Linux mount namespaces are not a macOS feature");
    backend.setReport(&reports, .seccomp, .unsupported, "Linux seccomp-bpf is not a macOS feature");
    backend.setReport(&reports, .landlock, .unsupported, "Linux Landlock is not a macOS feature");
    backend.setReport(&reports, .cgroups, .unsupported, "Linux cgroup cleanup is not a macOS feature");

    // Strong sandbox: version-gated deprecated custom profile API (matrix majors 14–26).
    // Capability probes never authorize a live session `active` claim (S-GLO-01).
    const support = if (builtin.os.tag == .macos)
        macos_seatbelt.evaluateSupport()
    else
        macos_seatbelt.SupportStatus.not_macos;

    const strong_level: backend.Level = switch (support) {
        // API path present on advertised matrix — still not a live session attach.
        .supported => .partial,
        .version_unsupported, .symbol_unavailable, .not_macos => .unavailable,
    };
    const strong_note: []const u8 = switch (support) {
        // Capability only — never live active. Default residual grade is hardened (flag token).
        .supported => "OS filesystem sandbox API present on a supported macOS version; default residual grade hardened (seatbelt_profile=hardened); session active only after apply-before-exec child attach and profile hash",
        .version_unsupported => "OS filesystem sandbox unavailable: running macOS is outside the advertised support matrix (14–26); capability probes are not a live session claim",
        .symbol_unavailable => "OS filesystem sandbox unavailable: sandbox apply symbol not resolvable; capability probes are not a live session claim",
        .not_macos => "OS filesystem sandbox is a macOS feature",
    };
    backend.setReport(&reports, .strong_sandbox, strong_level, strong_note);

    return .{
        .os = .macos,
        .backend_name = "macos",
        .fallback_level = .partial,
        .fallback_note = "macOS backend uses practical local wrapper controls, staging, env filtering, MCP proxying, audit, and process supervision",
        .reports = reports,
    };
}

test "macOS capability detector is honest about wrapper and unavailable protections" {
    const report = detect();
    try std.testing.expectEqual(platform.Os.macos, report.os);
    try std.testing.expectEqualStrings("macos", report.backend_name);
    try std.testing.expectEqual(backend.Level.active, report.get(.env_filtering).level);
    try std.testing.expectEqual(backend.Level.active, report.get(.path_staging).level);
    try std.testing.expectEqual(backend.Level.wrapper_only, report.get(.shell_wrapping).level);
    try std.testing.expectEqual(backend.Level.wrapper_only, report.get(.path_shims).level);
    try std.testing.expectEqual(backend.Level.active, report.get(.process_supervision).level);
    try std.testing.expectEqual(backend.Level.unavailable, report.get(.network_enforce).level);
    // strong_sandbox never active from detect (S-GLO-01).
    try std.testing.expect(report.get(.strong_sandbox).level != .active);
    try std.testing.expect(!report.featureAvailable(.strong_sandbox) or report.get(.strong_sandbox).level == .partial);
    // Default doctor notes stay mechanism-neutral (no capital "Seatbelt" branding).
    try std.testing.expect(std.mem.indexOf(u8, report.get(.strong_sandbox).note, "Seatbelt") == null);
    // When attach is possible, surface default residual grade (capability, not live active).
    if (report.get(.strong_sandbox).level == .partial) {
        try std.testing.expect(std.mem.indexOf(u8, report.get(.strong_sandbox).note, "seatbelt_profile=hardened") != null);
        try std.testing.expect(std.mem.indexOf(u8, report.get(.strong_sandbox).note, "default residual grade hardened") != null);
        try std.testing.expect(std.mem.indexOf(u8, report.get(.strong_sandbox).note, "session active only after") != null);
    }
}

test "macOS strong_sandbox tracks version matrix without live active claim" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const report = detect();
    const support = macos_seatbelt.evaluateSupport();
    switch (support) {
        .supported => {
            try std.testing.expectEqual(backend.Level.partial, report.get(.strong_sandbox).level);
            try std.testing.expect(std.mem.indexOf(u8, report.get(.strong_sandbox).note, "seatbelt_profile=hardened") != null);
        },
        else => try std.testing.expectEqual(backend.Level.unavailable, report.get(.strong_sandbox).level),
    }
    try std.testing.expect(report.get(.strong_sandbox).level != .active);
}

// No scaffold prepare path — production attach is apply_posix only.
// Process-group leadership for agent spawn is proven in apply_posix tests.
test "macOS process group spawn runs simple command" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &[_][]const u8{"/usr/bin/true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const term = try child.wait(std.testing.io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
