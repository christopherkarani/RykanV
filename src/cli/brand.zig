//! Single source of truth for product identity (Phase 5a brand cut).
//!
//! Primary brand/CLI: **ryk**. Legacy alias: **orca** (binary + env dual-read).
//! Do not introduce a second brand (ryz). Workspace `.orca/` paths stay for Phase 5b.

const std = @import("std");

/// User-facing product display name (help, TUI, status, block copy).
pub const product_display = "ryk";

/// Primary CLI binary / argv name.
pub const cli_name = "ryk";

/// Legacy CLI binary kept as PATH alias for ≥1 major.
pub const cli_name_legacy = "orca";

/// npm scope kept during 5a (package names change; scope does not).
pub const package_scope = "@orca-sec";

/// Version JSON / plain `product` field.
pub fn versionProduct() []const u8 {
    return product_display;
}

/// Usage line prefix, e.g. `ryk version`.
pub fn usagePrefix() []const u8 {
    return cli_name;
}

/// True when argv0 basename is the legacy binary name (`orca` / `orca.exe`).
pub fn isLegacyInvocation(argv0_basename: []const u8) bool {
    if (std.mem.eql(u8, argv0_basename, cli_name_legacy)) return true;
    if (std.mem.eql(u8, argv0_basename, cli_name_legacy ++ ".exe")) return true;
    return false;
}

/// True when argv0 basename is the primary binary name.
pub fn isPrimaryInvocation(argv0_basename: []const u8) bool {
    if (std.mem.eql(u8, argv0_basename, cli_name)) return true;
    if (std.mem.eql(u8, argv0_basename, cli_name ++ ".exe")) return true;
    return false;
}

/// Safety-boundary blurb for version metadata (local-only product claim).
pub fn safetyBoundary() []const u8 {
    return "ryk enforces local command, file, network, MCP, audit, and red-team controls; it does not provide hosted telemetry or cloud enforcement.";
}

test "brand constants: ryk primary and orca legacy" {
    try std.testing.expectEqualStrings("ryk", product_display);
    try std.testing.expectEqualStrings("ryk", cli_name);
    try std.testing.expectEqualStrings("orca", cli_name_legacy);
    try std.testing.expectEqualStrings("ryk", versionProduct());
    try std.testing.expectEqualStrings("ryk", usagePrefix());
    try std.testing.expect(isLegacyInvocation("orca"));
    try std.testing.expect(isLegacyInvocation("orca.exe"));
    try std.testing.expect(!isLegacyInvocation("ryk"));
    try std.testing.expect(isPrimaryInvocation("ryk"));
    try std.testing.expect(!isPrimaryInvocation("orca"));
    // No second brand.
    try std.testing.expect(!std.mem.eql(u8, product_display, "ryz"));
    try std.testing.expect(!std.mem.eql(u8, cli_name, "ryz"));
}

test "brand safety boundary names ryk" {
    try std.testing.expect(std.mem.indexOf(u8, safetyBoundary(), "ryk") != null);
    try std.testing.expect(std.mem.indexOf(u8, safetyBoundary(), "Orca") == null);
}
