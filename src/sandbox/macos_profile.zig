//! CompiledProfile → SBPL (Seatbelt profile language) for macOS custom sandbox.
//!
//! Pure string generation — no syscalls. Policy shape:
//! - deny default
//! - workspace RW (minus control-root write carve-outs)
//! - system RO prefixes from grants
//! - no broad $HOME grant
//! - process/mach/network baseline so a sandboxed child can still exec
//!
//! Profile grades (`posture.SeatbeltProfileGrade`):
//! - `compatible`: historical residuals (`process*`, broad `/private/var`, route-force
//!   keeps inbound/bind)
//! - `hardened` (default): narrowed process ops + bootstrap FS; same network model
//! - `strict`: hardened + no listeners under route-force; no broad `network*` without
//!   route forcing (deny-default). Still not process/XPC isolation.
//!
//! Path form (M-28): Seatbelt `subpath` filters on product majors match the
//! normalized `/Users/…` firmlink form. Realpath often returns
//! `/System/Volumes/Data/Users/…`; we strip the Data prefix for SBPL emission
//! so grants are live-effective. Data-form path strings are not dual-emitted.

const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const posture = @import("posture.zig");

/// Data-volume prefix stripped when emitting Users-tree grants (see `sbplEmitPath`).
const data_volume_prefix = "/System/Volumes/Data";

pub const SeatbeltProfileGrade = posture.SeatbeltProfileGrade;

/// Bounds for prepare-time hardlink alias discovery under protect-on.
///
/// `max_entries` counts every dirent under the workspace (files + directories),
/// not only multi-nlink aliases. Align with Linux workspace-view default
/// (`linux_workspace_view` max_scan_entries = 1_000_000) so monorepos with
/// dependency trees and build artifacts do not fail closed at prepare with
/// `seatbelt_secret_hardlink_scan_capacity` while Linux still attaches.
pub const secret_hardlink_scan_max_depth: u32 = 48;
pub const secret_hardlink_scan_max_entries: u32 = 1_000_000;

pub const NetworkRouteForcing = struct {
    proxy_port: u16,
};

pub const RenderOptions = struct {
    network_route_forcing: ?NetworkRouteForcing = null,
    /// Residual grade. Default is hardened.
    profile_grade: SeatbeltProfileGrade = SeatbeltProfileGrade.default_grade,
    /// Absolute paths of multi-nlink non-secret basenames under the workspace
    /// (prepare-time hardlink residual closes outside secret-form inodes linked
    /// under ordinary names). Each path receives last-match deny for
    /// read/write/metadata. Caller owns the slices.
    hardlink_alias_denies: []const []const u8 = &.{},
};

/// Honest network_scope string for receipts/banners after child attach.
pub fn networkScopeSummary(grade: SeatbeltProfileGrade, route_forced: bool) []const u8 {
    if (!route_forced) {
        return switch (grade) {
            .compatible, .hardened => "unrestricted",
            // Strict without route force omits `(allow network*)` — deny default.
            .strict => "deny-default (no broad network*; no route force)",
        };
    }
    return switch (grade) {
        .compatible, .hardened => "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind unrestricted)",
        .strict => "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind denied)",
    };
}

/// Render a custom SBPL profile string from a compiled grant model.
/// Caller owns the returned slice. Uses default (`hardened`) grade.
pub fn renderSbpl(allocator: std.mem.Allocator, compiled: *const profile.CompiledProfile) ![]u8 {
    return renderSbplWithOptions(allocator, compiled, .{});
}

/// Render a custom SBPL profile string with optional child network route forcing
/// and residual grade.
///
/// Route forcing removes broad `network*` and permits outbound TCP only to the
/// local proxy port. Under `compatible`/`hardened`, inbound/bind stay unrestricted
/// so agents can start listeners (Landlock connect-only parity). Under `strict`,
/// inbound/bind are omitted (listener lockdown). macOS Seatbelt accepts
/// `localhost` (not numeric loopback) for TCP address filters; live tests prove
/// that filter still matches numeric `127.0.0.1` client connects.
pub fn renderSbplWithOptions(
    allocator: std.mem.Allocator,
    compiled: *const profile.CompiledProfile,
    options: RenderOptions,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "(version 1)\n");
    try out.appendSlice(allocator, "(deny default)\n");
    try out.appendSlice(allocator, "\n");

    // Baseline: process lifecycle, signals, sysctl, mach, and optional network.
    // Intentional non-goals (FS confinement only — not process/IPC/network isolation):
    // unfiltered mach-lookup remains on all grades. See docs/platform-macos.md.
    // Metadata is scoped to root literals + granted trees only — never bare
    // (allow file-read-metadata) which enables host-wide path discovery.
    try appendProcessBaseline(&out, allocator, options.profile_grade);
    try out.appendSlice(allocator,
        \\(allow signal)
        \\(allow sysctl-read)
        \\;; mach-lookup required for dyld; omit mach-register (no host service registration)
        \\;; unfiltered — not an XPC/service allowlist (residual on all grades)
        \\(allow mach-lookup)
        \\
    );
    try appendNetworkBaseline(&out, allocator, options);
    try appendBootstrapFs(&out, allocator, options.profile_grade);

    // Path grants from the portable profile model (Users-form when under Data/Users).
    // `.exec` uses `literal` (file-only) so a mistaken directory path cannot tree-open.
    try out.appendSlice(allocator, ";; compiled path grants\n");
    for (compiled.grants) |g| {
        // Metadata only under granted trees.
        switch (g.mode) {
            .exec => {
                try appendAllowLiteral(&out, allocator, "file-read-metadata", g.path);
                try appendAllowLiteral(&out, allocator, "file-read*", g.path);
                try appendAllowLiteral(&out, allocator, "process-exec", g.path);
            },
            .ro => {
                try appendAllowSubpath(&out, allocator, "file-read-metadata", g.path);
                try appendAllowSubpath(&out, allocator, "file-read*", g.path);
                try appendAllowSubpath(&out, allocator, "process-exec", g.path);
            },
            .rw => {
                try appendAllowSubpath(&out, allocator, "file-read-metadata", g.path);
                try appendAllowSubpath(&out, allocator, "file-read*", g.path);
                // RW with control-root write denies (require-not).
                try appendAllowWriteMinusControls(&out, allocator, g.path, compiled.control_roots);
            },
        }
    }

    // Explicit control write denies (defense in depth if a broader allow slips in).
    if (compiled.control_roots.len > 0) {
        try out.appendSlice(allocator, "\n;; control-root write carve-outs\n");
        for (compiled.control_roots) |root| {
            try appendDenySubpath(&out, allocator, "file-write*", root);
        }
    }

    // Deny Data-volume firmlink surface (homes / host secrets).
    // Scope is `/System/Volumes/Data` only — not all of `/System/Volumes` (Preboot,
    // Update, etc. are not the secret-home surface). Deny is emitted *after* grants so
    // last-match blocks bare `/System` custom grants that would otherwise open Data.
    //
    // Workspace grants under Data/Users are emitted as Users-form (see sbplEmitPath),
    // which Seatbelt matches live; the Data deny still blocks Data-form opens of
    // sibling homes. Non-Users Data grants (rare) are re-allowed after the deny.
    try out.appendSlice(allocator,
        \\
        \\;; deny data-volume firmlink surface (homes / host secrets); re-allow non-Users Data grants below
        \\(deny file-read* (subpath "/System/Volumes/Data"))
        \\(deny file-read-metadata (subpath "/System/Volumes/Data"))
        \\(deny process-exec (subpath "/System/Volumes/Data"))
        \\
    );

    // Re-allow only grants that remain Data-form after sbplEmitPath (not Users-mapped).
    // Users-form emissions are outside the Data deny subpath string and need no re-allow.
    var reallowed = false;
    for (compiled.grants) |g| {
        if (!grantUnderDataVolume(g.path)) continue;
        // Users-tree grants already emit as /Users/… — skip redundant re-allow.
        if (sbplMapsToUsersForm(g.path)) continue;
        if (!reallowed) {
            try out.appendSlice(allocator, ";; re-allow non-Users grants under /System/Volumes/Data (last-match after Data deny)\n");
            reallowed = true;
        }
        switch (g.mode) {
            .exec => {
                try appendAllowLiteral(&out, allocator, "file-read-metadata", g.path);
                try appendAllowLiteral(&out, allocator, "file-read*", g.path);
                try appendAllowLiteral(&out, allocator, "process-exec", g.path);
            },
            .ro => {
                try appendAllowSubpath(&out, allocator, "file-read-metadata", g.path);
                try appendAllowSubpath(&out, allocator, "file-read*", g.path);
                try appendAllowSubpath(&out, allocator, "process-exec", g.path);
            },
            .rw => {
                try appendAllowSubpath(&out, allocator, "file-read-metadata", g.path);
                try appendAllowSubpath(&out, allocator, "file-read*", g.path);
                try appendAllowWriteMinusControls(&out, allocator, g.path, compiled.control_roots);
            },
        }
    }

    if (compiled.protect_workspace_secrets) {
        try out.appendSlice(allocator, "\n;; workspace env secret carve-out\n");
        try appendWorkspaceSecretDeny(&out, allocator, "file-read*", compiled.workspace_root);
        try appendWorkspaceSecretDeny(&out, allocator, "file-read-metadata", compiled.workspace_root);
        try appendWorkspaceSecretDeny(&out, allocator, "file-write*", compiled.workspace_root);
        if (options.hardlink_alias_denies.len > 0) {
            try out.appendSlice(allocator, ";; multi-nlink non-secret basenames (prepare-time hardlink residual)\n");
            for (options.hardlink_alias_denies) |alias_path| {
                try appendDenySubpath(&out, allocator, "file-read*", alias_path);
                try appendDenySubpath(&out, allocator, "file-read-metadata", alias_path);
                try appendDenySubpath(&out, allocator, "file-write*", alias_path);
            }
        }
    }

    // No broad HOME: assert via absence — never emit $HOME or ~ grants.
    return try out.toOwnedSlice(allocator);
}

fn appendProcessBaseline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    grade: SeatbeltProfileGrade,
) !void {
    switch (grade) {
        .compatible => try out.appendSlice(allocator,
            \\;; process baseline (compatible): unrestricted process* residual
            \\(allow process*)
            \\
        ),
        // Hardened + strict: lifecycle ops agents need without blanket process*.
        // process-exec is also re-granted per compiled path trees below.
        .hardened, .strict => try out.appendSlice(allocator,
            \\;; process baseline (hardened/strict): fork/exec/info only — not process isolation
            \\(allow process-fork)
            \\(allow process-exec)
            \\(allow process-info*)
            \\
        ),
    }
}

fn appendNetworkBaseline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    options: RenderOptions,
) !void {
    if (options.network_route_forcing) |route| {
        switch (options.profile_grade) {
            .compatible, .hardened => {
                // Outbound: only the Orca loopback proxy. Inbound/bind stay open —
                // connect mediation, not a listener lockdown (Landlock parity).
                const line = try std.fmt.allocPrint(allocator,
                    \\;; network route forcing: outbound TCP only to Orca loopback proxy;
                    \\;; inbound/bind unrestricted (dev servers, ephemeral listeners)
                    \\(allow network-inbound)
                    \\(allow network-bind)
                    \\(allow network-outbound (remote tcp "localhost:{d}"))
                    \\
                , .{route.proxy_port});
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            },
            .strict => {
                const line = try std.fmt.allocPrint(allocator,
                    \\;; network route forcing (strict): outbound TCP only to Orca loopback proxy;
                    \\;; inbound/bind omitted (listener lockdown — breaks Landlock parity intentionally)
                    \\(allow network-outbound (remote tcp "localhost:{d}"))
                    \\
                , .{route.proxy_port});
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            },
        }
        return;
    }
    switch (options.profile_grade) {
        .compatible, .hardened => try out.appendSlice(allocator,
            \\;; network unrestricted unless the launcher requested proxy route forcing
            \\(allow network*)
            \\
        ),
        // Strict without route force: omit network* — deny default blocks network.
        .strict => try out.appendSlice(allocator,
            \\;; strict without route force: no broad network* (deny default)
            \\
        ),
    }
}

fn appendBootstrapFs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    grade: SeatbeltProfileGrade,
) !void {
    // Shared dyld/device/root literals.
    try out.appendSlice(allocator,
        \\;; dyld / device / root path components needed for exec (content + metadata)
        \\(allow file-read-metadata (literal "/"))
        \\(allow file-read-metadata (literal "/private"))
        \\(allow file-read* (literal "/"))
        \\(allow file-read* (literal "/private"))
        \\(allow file-read* (literal "/private/tmp"))
        \\(allow file-read* (literal "/private/var/tmp"))
        \\
    );
    switch (grade) {
        // Historical: broad /private/var read (host discovery residual).
        .compatible => try out.appendSlice(allocator,
            \\(allow file-read* (literal "/private/var"))
            \\
        ),
        // Hardened/strict: no broad /private/var — only dyld + shell select + tmp.
        .hardened, .strict => try out.appendSlice(allocator,
            \\;; bootstrap FS (hardened/strict): no broad /private/var
            \\(allow file-read* (subpath "/private/var/select"))
            \\
        ),
    }
    try out.appendSlice(allocator,
        \\(allow file-read-metadata (subpath "/dev"))
        \\(allow file-read* (subpath "/dev"))
        \\(allow file-ioctl (subpath "/dev"))
        \\(allow file-read-metadata (subpath "/private/var/db/dyld"))
        \\(allow file-read* (subpath "/private/var/db/dyld"))
        \\;; device writes: only null/urandom (not bare /dev)
        \\(allow file-write* (literal "/dev/null"))
        \\(allow file-write* (literal "/dev/urandom"))
        \\
    );
}

/// Regular file recorded during protect-on hardlink alias discovery.
const ScannedFile = struct {
    path: []u8,
    secret_name: bool,
    nlink: u64,
};

/// Walk `workspace_root` and return owned absolute paths of regular files that
/// need explicit last-match Seatbelt path denies as hardlink aliases.
///
/// Policy (aligns with Linux FUSE multi-nlink taint):
/// - Secret-form basenames are covered by the shared path-regex deny.
/// - Non-secret basenames with `nlink > 1` are denied by path: they can alias
///   an outside secret-form inode (e.g. host `.env` hardlinked as `config.txt`)
///   or a workspace secret-form name. Single-nlink ordinary files stay allowed.
///
/// Fail-closed policy (protect-on prepare path):
/// - Missing workspace (`error.FileNotFound`) → empty list (regex deny still
///   applies; unit tests with synthetic roots keep working).
/// - Any other root open failure (access denied, not a directory, …) →
///   `error.ScanOpenFailed`.
/// - Nested directory open failure → `error.ScanOpenFailed` (never skip).
/// - Regular-file open/fstat failure → `error.ScanOpenFailed`.
/// - Symlinks and other non-regular kinds are skipped (cannot be hardlink
///   aliases of secret regular files); only open/fstat failures on kinds that
///   may be regular files fail closed.
/// - Scan capacity/depth exceeded → `error.ScanCapacity` /
///   `error.ScanDepthExceeded`.
///
/// Prepare maps `OutOfMemory` to `seatbelt_profile_oom` and other scan errors
/// to distinct `seatbelt_secret_hardlink_scan_*` reason codes.
///
/// Caller frees each path and the outer slice via `freeHardlinkAliasPaths`.
pub fn collectSecretHardlinkAliasPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
) ![]const []const u8 {
    if (builtin.os.tag != .macos) return try allocator.alloc([]const u8, 0);

    var root = std.Io.Dir.openDirAbsolute(io, workspace_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        // Only absence is soft: regex deny still covers secret basenames.
        error.FileNotFound => return try allocator.alloc([]const u8, 0),
        else => return error.ScanOpenFailed,
    };
    defer root.close(io);

    var entries: std.ArrayList(ScannedFile) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }

    var scanned: u32 = 0;
    try walkCollectHardlinkCandidates(
        allocator,
        io,
        &root,
        workspace_root,
        0,
        &scanned,
        &entries,
    );

    var aliases: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (aliases.items) |p| allocator.free(p);
        aliases.deinit(allocator);
    }

    for (entries.items) |e| {
        // Secret basenames: path-regex deny. Multi-nlink non-secret: explicit path deny.
        if (e.secret_name or e.nlink <= 1) continue;
        // dupe before append: free on append failure (partial-success path).
        const owned = try allocator.dupe(u8, e.path);
        errdefer allocator.free(owned);
        try aliases.append(allocator, owned);
    }

    return try aliases.toOwnedSlice(allocator);
}

pub fn freeHardlinkAliasPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

fn walkCollectHardlinkCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    dir_path: []const u8,
    depth: u32,
    scanned: *u32,
    entries: *std.ArrayList(ScannedFile),
) !void {
    if (depth > secret_hardlink_scan_max_depth) return error.ScanDepthExceeded;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (std.mem.indexOfScalar(u8, entry.name, 0) != null) continue;

        scanned.* = std.math.add(u32, scanned.*, 1) catch return error.ScanCapacity;
        if (scanned.* > secret_hardlink_scan_max_entries) return error.ScanCapacity;

        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_path);

        switch (entry.kind) {
            .directory => {
                // iterate() reports real directories as .directory; symlinks are
                // .sym_link and are intentionally not followed into the walk.
                // Open failures fail closed: skipping an unreadable dir would
                // miss multi-nlink aliases under that tree.
                var child = std.Io.Dir.openDirAbsolute(io, child_path, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch return error.ScanOpenFailed;
                defer child.close(io);
                try walkCollectHardlinkCandidates(
                    allocator,
                    io,
                    &child,
                    child_path,
                    depth + 1,
                    scanned,
                    entries,
                );
            },
            .file => try recordScannedRegular(allocator, io, child_path, entry.name, entries),
            // Symlinks and known non-regular kinds cannot be hardlink aliases of
            // secret regular files — skip without failing prepare (node_modules
            // shims, sockets, etc. must not break empty-backpack attach).
            .sym_link,
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            => {},
            // Unknown kind: attempt open/fstat; non-regular → skip; open fail → closed.
            else => try recordScannedRegular(allocator, io, child_path, entry.name, entries),
        }
    }
}

fn recordScannedRegular(
    allocator: std.mem.Allocator,
    io: std.Io,
    child_path: []const u8,
    entry_name: []const u8,
    entries: *std.ArrayList(ScannedFile),
) !void {
    const meta = (try regularFileMetaForPath(io, child_path)) orelse return;
    const secret_name = profile.isWorkspaceSecretBasename(entry_name);
    const owned = try allocator.dupe(u8, child_path);
    errdefer allocator.free(owned);
    try entries.append(allocator, .{
        .path = owned,
        .secret_name = secret_name,
        .nlink = meta.nlink,
    });
}

const RegularFileMeta = struct {
    nlink: u64,
};

/// Open/fstat a path as a regular file. Open/fstat failures → `ScanOpenFailed`
/// (fail closed). Non-regular after successful fstat → `null` (skip).
fn regularFileMetaForPath(io: std.Io, path: []const u8) error{ScanOpenFailed}!?RegularFileMeta {
    if (builtin.os.tag != .macos) return null;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{
        .path_only = true,
        .follow_symlinks = false,
    }) catch return error.ScanOpenFailed;
    defer file.close(io);
    // Zig 0.16 File.Stat omits nlink; use libc fstat for multi-link detection.
    var st: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &st) != 0) return error.ScanOpenFailed;
    if (!std.posix.S.ISREG(st.mode)) return null;
    return .{
        .nlink = @intCast(st.nlink),
    };
}

fn appendWorkspaceSecretDeny(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    op: []const u8,
    workspace_root: []const u8,
) !void {
    try out.appendSlice(allocator, "(deny ");
    try out.appendSlice(allocator, op);
    try out.appendSlice(allocator, " (require-all (subpath \"");
    try appendEscaped(out, allocator, sbplEmitPath(workspace_root));
    // Secret form + template allow: only profile rule book (no local .env regex).
    try out.appendSlice(allocator, "\") ");
    try profile.appendWorkspaceSecretSbplRegexPredicates(out, allocator);
    try out.appendSlice(allocator, "))\n");
}

/// True when a grant path is exactly Data volume or a strict descendant.
fn grantUnderDataVolume(path: []const u8) bool {
    return profile.isPathWithin(path, data_volume_prefix);
}

/// True when `sbplEmitPath` would strip `/System/Volumes/Data` → `/Users/…`.
fn sbplMapsToUsersForm(path: []const u8) bool {
    return !std.mem.eql(u8, sbplEmitPath(path), path);
}

/// Normalize paths for SBPL emission: prefer Users-form when realpath is under
/// `/System/Volumes/Data/Users/…`. Seatbelt subpath filters match `/Users/…` on
/// matrix hosts; Data-form grant strings are not live-effective for workspace RW.
///
/// Only the Data+Users firmlink surface is rewritten (component-bounded). Other
/// Data paths (e.g. `/System/Volumes/Data/private/…`) pass through unchanged.
fn sbplEmitPath(path: []const u8) []const u8 {
    // /System/Volumes/Data/Users or /System/Volumes/Data/Users/…
    const users_under_data = data_volume_prefix ++ "/Users";
    if (std.mem.eql(u8, path, users_under_data)) {
        return path[data_volume_prefix.len..]; // "/Users"
    }
    if (std.mem.startsWith(u8, path, users_under_data ++ "/")) {
        return path[data_volume_prefix.len..]; // "/Users/…"
    }
    return path;
}

fn appendAllowSubpath(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    op: []const u8,
    path: []const u8,
) !void {
    const emit = sbplEmitPath(path);
    try out.appendSlice(allocator, "(allow ");
    try out.appendSlice(allocator, op);
    try out.appendSlice(allocator, " (subpath \"");
    try appendEscaped(out, allocator, emit);
    try out.appendSlice(allocator, "\"))\n");
}

/// File-only allow (no tree open). Used for `.exec` launch-binary grants.
fn appendAllowLiteral(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    op: []const u8,
    path: []const u8,
) !void {
    const emit = sbplEmitPath(path);
    try out.appendSlice(allocator, "(allow ");
    try out.appendSlice(allocator, op);
    try out.appendSlice(allocator, " (literal \"");
    try appendEscaped(out, allocator, emit);
    try out.appendSlice(allocator, "\"))\n");
}

fn appendDenySubpath(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    op: []const u8,
    path: []const u8,
) !void {
    const emit = sbplEmitPath(path);
    try out.appendSlice(allocator, "(deny ");
    try out.appendSlice(allocator, op);
    try out.appendSlice(allocator, " (subpath \"");
    try appendEscaped(out, allocator, emit);
    try out.appendSlice(allocator, "\"))\n");
}

fn appendAllowWriteMinusControls(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    control_roots: []const []const u8,
) !void {
    const emit = sbplEmitPath(path);
    // (allow file-write* (require-all (subpath "ws") (require-not (subpath "ctrl")) ...))
    try out.appendSlice(allocator, "(allow file-write* (require-all (subpath \"");
    try appendEscaped(out, allocator, emit);
    try out.appendSlice(allocator, "\")");
    for (control_roots) |root| {
        // Only carve controls that sit under this RW grant (lexical on original paths).
        if (!profile.isPathWithin(root, path) and !std.mem.eql(u8, root, path)) continue;
        try out.appendSlice(allocator, " (require-not (subpath \"");
        try appendEscaped(out, allocator, sbplEmitPath(root));
        try out.appendSlice(allocator, "\"))");
    }
    try out.appendSlice(allocator, "))\n");
}

fn appendEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    for (path) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, c),
        }
    }
}

/// True if SBPL text grants a broad home directory (should always be false for Orca profiles).
pub fn sbplGrantsHome(sbpl: []const u8, home: []const u8) bool {
    if (home.len == 0) return false;
    // Match exact subpath "HOME" grant forms only (not workspace under home).
    var needle_buf: [512]u8 = undefined;
    if (home.len + 32 > needle_buf.len) return false;
    const needle = std.fmt.bufPrint(&needle_buf, "(subpath \"{s}\")", .{home}) catch return false;
    // Only count as broad HOME if the grant is exactly HOME, not a longer path.
    // Search for the needle and ensure the next char after home in the path is `"`.
    return std.mem.indexOf(u8, sbpl, needle) != null;
}

test "SBPL denies default and grants workspace RW" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-ws",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(version 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/tmp/orca-sbpl-ws\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "file-write*") != null);
}

test "SBPL system prefixes are read-only not write" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/proj",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (subpath \"/usr\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (subpath \"/bin\"))") != null);
    // No bare write grant for system prefixes.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-write* (subpath \"/usr\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-write* (subpath \"/bin\"))") == null);
}

test "SBPL control roots deny write under workspace" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/proj",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(require-not (subpath \"/workspace/proj/.orca\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-write* (subpath \"/workspace/proj/.orca\"))") != null);
}

test "SBPL emits process-exec for launch .exec grants without HOME" {
    const allocator = std.testing.allocator;
    const home = "/Users/dev";
    const agent_bin = "/Users/dev/.local/share/claude/versions/2.1.196";
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/Users/dev/projects/app",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
        .exec_paths = &.{agent_bin},
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process-exec (literal \"/Users/dev/.local/share/claude/versions/2.1.196\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (literal \"/Users/dev/.local/share/claude/versions/2.1.196\"))") != null);
    // Exec grants must not tree-open via subpath.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process-exec (subpath \"/Users/dev/.local/share/claude/versions/2.1.196\"))") == null);
    // Still no broad HOME.
    try std.testing.expect(!sbplGrantsHome(sbpl, home));
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/Users/dev\")") == null);
}

test "SBPL never grants broad HOME" {
    const allocator = std.testing.allocator;
    const home = "/Users/dev";
    const ws = "/Users/dev/projects/app";
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws,
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(!sbplGrantsHome(sbpl, home));
    try std.testing.expect(std.mem.indexOf(u8, sbpl, home) != null); // workspace path contains home prefix
    // Exact HOME subpath grant must not appear.
    var exact: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&exact, "(subpath \"{s}\")", .{home});
    // Workspace grant is longer: (subpath "/Users/dev/projects/app") — allowed.
    // Count only exact HOME: path ends with home then quote.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, needle) == null);
    try std.testing.expect(!compiled.grantsHome(home));
}

test "SBPL escapes quotes and backslashes in paths" {
    const allocator = std.testing.allocator;
    const nasty = "/tmp/x\"y\\z";
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = nasty,
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    const escaped_grant = "(subpath \"/tmp/x\\\"y\\\\z\")";
    try std.testing.expect(std.mem.indexOf(u8, sbpl, escaped_grant) != null);
    const escaped_control = "(deny file-write* (subpath \"/tmp/x\\\"y\\\\z/.orca\"))";
    try std.testing.expect(std.mem.indexOf(u8, sbpl, escaped_control) != null);
}

test "SBPL never emits bare unrestricted file-read-metadata" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-meta",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    // Bare form must not appear; only path-filtered metadata allows.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read-metadata)\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read-metadata (literal \"/\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read-metadata (subpath \"/tmp/orca-sbpl-meta\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read-metadata (subpath \"/usr\"))") != null);
}

test "SBPL narrows /dev writes to null and urandom only" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-dev",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    // Broad /dev write grant must not appear.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-write* (subpath \"/dev\"))") == null);
    // Narrow device nodes required for exec/stdio.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-write* (literal \"/dev/null\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-write* (literal \"/dev/urandom\"))") != null);
    // Read/ioctl remain broad for exec (TTY, null reads, etc.).
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (subpath \"/dev\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-ioctl (subpath \"/dev\"))") != null);
    // mach-lookup remains (dyld); mach-register is no longer granted.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow mach-lookup)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow mach-register)") == null);
}

test "SBPL hardened default narrows process* and broad /private/var" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-hardened",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process*)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process-fork)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process-exec)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process-info*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (literal \"/private/var\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (subpath \"/private/var/select\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (subpath \"/private/var/db/dyld\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") != null);
}

test "SBPL compatible retains process* and broad /private/var" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-compat",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbplWithOptions(allocator, &compiled, .{ .profile_grade = .compatible });
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (literal \"/private/var\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") != null);
}

test "SBPL route forcing removes broad network and allows only proxy TCP port" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-route",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbplWithOptions(allocator, &compiled, .{
        .network_route_forcing = .{ .proxy_port = 43123 },
        .profile_grade = .hardened,
    });
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(remote tcp \"localhost:43123\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(remote tcp \"*:43123\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(remote tcp)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(remote udp)") == null);
    // Hardened: inbound/bind remain so route-forced agents can listen.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-inbound)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-bind)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-outbound (remote tcp \"localhost:43123\"))") != null);
}

test "SBPL strict route forcing denies inbound/bind" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-strict-route",
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbplWithOptions(allocator, &compiled, .{
        .network_route_forcing = .{ .proxy_port = 43123 },
        .profile_grade = .strict,
    });
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-inbound)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-bind)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network-outbound (remote tcp \"localhost:43123\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process*)") == null);
    try std.testing.expectEqualStrings(
        "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind denied)",
        networkScopeSummary(.strict, true),
    );
}

test "SBPL strict without route force omits network*" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-strict-no-route",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer compiled.deinit();

    const sbpl = try renderSbplWithOptions(allocator, &compiled, .{ .profile_grade = .strict });
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") == null);
    try std.testing.expectEqualStrings(
        "deny-default (no broad network*; no route force)",
        networkScopeSummary(.strict, false),
    );
}

test "SBPL default remains explicit unrestricted network under hardened" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-network-default",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") != null);
    try std.testing.expectEqualStrings("unrestricted", networkScopeSummary(.hardened, false));
}

// M-6 partial: dual-encoding lock — SBPL tokens must match networkScopeSummary invariants
// for every grade × route_force cell (claim vs render drift guard).
test "grade residual matrix: SBPL tokens match networkScopeSummary invariants" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-grade-matrix",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer compiled.deinit();

    const grades = [_]SeatbeltProfileGrade{ .compatible, .hardened, .strict };
    for (grades) |grade| {
        // No route force.
        {
            const sbpl = try renderSbplWithOptions(allocator, &compiled, .{ .profile_grade = grade });
            defer allocator.free(sbpl);
            const summary = networkScopeSummary(grade, false);
            const has_network_star = std.mem.indexOf(u8, sbpl, "(allow network*)") != null;
            switch (grade) {
                .compatible, .hardened => {
                    try std.testing.expect(has_network_star);
                    try std.testing.expectEqualStrings("unrestricted", summary);
                    const has_process_star = std.mem.indexOf(u8, sbpl, "(allow process*)") != null;
                    const has_private_var = std.mem.indexOf(u8, sbpl, "(allow file-read* (literal \"/private/var\"))") != null;
                    try std.testing.expectEqual(grade == .compatible, has_process_star);
                    try std.testing.expectEqual(grade == .compatible, has_private_var);
                },
                .strict => {
                    try std.testing.expect(!has_network_star);
                    try std.testing.expectEqualStrings(
                        "deny-default (no broad network*; no route force)",
                        summary,
                    );
                    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow process*)") == null);
                    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow file-read* (literal \"/private/var\"))") == null);
                },
            }
        }
        // Route force.
        {
            const sbpl = try renderSbplWithOptions(allocator, &compiled, .{
                .profile_grade = grade,
                .network_route_forcing = .{ .proxy_port = 43123 },
            });
            defer allocator.free(sbpl);
            const summary = networkScopeSummary(grade, true);
            try std.testing.expect(std.mem.indexOf(u8, sbpl, "(allow network*)") == null);
            try std.testing.expect(std.mem.indexOf(u8, sbpl, "(remote tcp \"localhost:43123\")") != null);
            const has_inbound = std.mem.indexOf(u8, sbpl, "(allow network-inbound)") != null;
            const has_bind = std.mem.indexOf(u8, sbpl, "(allow network-bind)") != null;
            switch (grade) {
                .compatible, .hardened => {
                    try std.testing.expect(has_inbound and has_bind);
                    try std.testing.expectEqualStrings(
                        "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind unrestricted)",
                        summary,
                    );
                },
                .strict => {
                    try std.testing.expect(!has_inbound and !has_bind);
                    try std.testing.expectEqualStrings(
                        "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind denied)",
                        summary,
                    );
                },
            }
        }
    }
}

test "SBPL denies /System/Volumes/Data even if bare /System is granted" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-sys",
        // Adversarial: custom bare /System must still not open Data volume homes.
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/System" },
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/System/Volumes/Data\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read-metadata (subpath \"/System/Volumes/Data\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny process-exec (subpath \"/System/Volumes/Data\"))") != null);
    // Blanket deny of all Volumes is too broad (Preboot) and clobbers realpath workspaces.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/System/Volumes\"))") == null);
}

test "SBPL emits Users-form for Data-volume realpath workspace (M-28 / R2-1)" {
    const allocator = std.testing.allocator;
    // Model macOS firmlink realpath: /Users/… → /System/Volumes/Data/Users/…
    const ws_data = "/System/Volumes/Data/Users/dev/projects/app";
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_data,
        .system_ro_prefixes = &[_][]const u8{ "/usr", "/bin" },
        .include_tmp = false,
    });
    defer compiled.deinit();

    // Pure model: workspace under Data remains granted; sibling home secrets are not.
    try std.testing.expect(compiled.isGrantedReadable(ws_data));
    try std.testing.expect(compiled.isAgentWritable(ws_data));
    try std.testing.expect(compiled.isGrantedReadable("/System/Volumes/Data/Users/dev/projects/app/src/main.zig"));
    try std.testing.expect(!compiled.isGrantedReadable("/System/Volumes/Data/Users/dev/.ssh/id_rsa"));
    try std.testing.expect(!compiled.isGrantedReadable("/System/Volumes/Data/Users/other/secret"));

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    // Seatbelt matches Users-form; emit /Users/… not Data-form grant strings.
    const allow_ws_users = "(allow file-read* (subpath \"/Users/dev/projects/app\"))";
    try std.testing.expect(std.mem.indexOf(u8, sbpl, allow_ws_users) != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/System/Volumes/Data/Users/dev/projects/app\")") == null);
    // Control carve-out also Users-form.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(require-not (subpath \"/Users/dev/projects/app/.orca\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-write* (subpath \"/Users/dev/projects/app/.orca\"))") != null);
    // Data deny still present (blocks Data-form sibling opens).
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/System/Volumes/Data\"))") != null);
    // Users-mapped workspace needs no Data re-allow section.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "re-allow non-Users grants under /System/Volumes/Data") == null);
    // Non-workspace Data home must not appear as a grant.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/System/Volumes/Data/Users/dev/.ssh\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/Users/dev/.ssh\")") == null);
}

test "sbplEmitPath strips Data prefix only under Users tree" {
    try std.testing.expectEqualStrings(
        "/Users/dev/projects/app",
        sbplEmitPath("/System/Volumes/Data/Users/dev/projects/app"),
    );
    try std.testing.expectEqualStrings("/Users", sbplEmitPath("/System/Volumes/Data/Users"));
    // Non-Users Data paths pass through (not dual-mapped).
    try std.testing.expectEqualStrings(
        "/System/Volumes/Data/private/tmp",
        sbplEmitPath("/System/Volumes/Data/private/tmp"),
    );
    // Component boundary: UsersFoo must not strip.
    try std.testing.expectEqualStrings(
        "/System/Volumes/Data/UsersFoo",
        sbplEmitPath("/System/Volumes/Data/UsersFoo"),
    );
    // Already Users-form: unchanged.
    try std.testing.expectEqualStrings("/Users/dev/app", sbplEmitPath("/Users/dev/app"));
    // Unrelated paths unchanged.
    try std.testing.expectEqualStrings("/tmp/ws", sbplEmitPath("/tmp/ws"));
}

test "SBPL production defaults omit bare /System and /Library grants" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/tmp/orca-sbpl-defaults",
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    // Exact bare /System and /Library grant forms must not appear (trailing ")).
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/System\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/Library\"))") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/System/Library\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(subpath \"/Library/Frameworks\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/System/Volumes/Data\"))") != null);
}

test "SBPL secret boundary denies workspace env forms but not exact safe templates" {
    const allocator = std.testing.allocator;
    var ordinary = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/app",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
    });
    defer ordinary.deinit();
    var protected = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/app",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
        .protect_workspace_secrets = true,
    });
    defer protected.deinit();

    const ordinary_sbpl = try renderSbpl(allocator, &ordinary);
    defer allocator.free(ordinary_sbpl);
    const protected_sbpl = try renderSbpl(allocator, &protected);
    defer allocator.free(protected_sbpl);

    try std.testing.expect(std.mem.indexOf(u8, ordinary_sbpl, "workspace env secret carve-out") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, protected_sbpl, ";; workspace env secret carve-out") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            protected_sbpl,
            "(deny file-read* (require-all (subpath \"/workspace/app\")",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            protected_sbpl,
            "(deny file-write* (require-all (subpath \"/workspace/app\")",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            protected_sbpl,
            "(deny file-read-metadata (require-all (subpath \"/workspace/app\")",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            protected_sbpl,
            profile.workspace_secret_form_sbpl_regex,
        ) != null,
    );
    var template_needle_buf: [128]u8 = undefined;
    const template_needle = try std.fmt.bufPrint(
        &template_needle_buf,
        "(require-not (regex #\"/[.]env[.]({s})$\"))",
        .{profile.workspace_secret_safe_template_sbpl_alt},
    );
    try std.testing.expect(std.mem.indexOf(u8, protected_sbpl, template_needle) != null);
}

test "SBPL secret boundary uses live Users firmlink form" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/System/Volumes/Data/Users/dev/projects/app",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
        .protect_workspace_secrets = true,
    });
    defer compiled.deinit();

    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            sbpl,
            "(deny file-read* (require-all (subpath \"/Users/dev/projects/app\")",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            sbpl,
            "(deny file-read* (require-all (subpath \"/System/Volumes/Data/Users/dev/projects/app\")",
        ) == null,
    );
}

test "SBPL protect-on emits explicit denies for hardlink alias paths" {
    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/app",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
        .protect_workspace_secrets = true,
    });
    defer compiled.deinit();

    const sbpl = try renderSbplWithOptions(allocator, &compiled, .{
        .hardlink_alias_denies = &[_][]const u8{"/workspace/app/notes.txt"},
    });
    defer allocator.free(sbpl);

    try std.testing.expect(std.mem.indexOf(u8, sbpl, "multi-nlink non-secret basenames") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/workspace/app/notes.txt\"))") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, sbpl, "(deny file-write* (subpath \"/workspace/app/notes.txt\"))") != null,
    );
}

test "collectSecretHardlinkAliasPaths finds non-secret basenames sharing secret inode" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "secret-body" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ordinary.txt", .data = "plain" });
    tmp.dir.hardLink(".env", tmp.dir, "alias.txt", io, .{}) catch return error.SkipZigTest;

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const aliases = try collectSecretHardlinkAliasPaths(allocator, io, root);
    defer freeHardlinkAliasPaths(allocator, aliases);

    try std.testing.expectEqual(@as(usize, 1), aliases.len);
    try std.testing.expect(std.mem.endsWith(u8, aliases[0], "alias.txt"));
    try std.testing.expect(!std.mem.endsWith(u8, aliases[0], ".env"));
    try std.testing.expect(!std.mem.endsWith(u8, aliases[0], "ordinary.txt"));
}

test "collectSecretHardlinkAliasPaths denies outside secret hardlinked under non-secret name" {
    // Outside `.env` hardlinked into the workspace as config.txt must be denied
    // even though no secret-form basename exists inside the workspace walk.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();

    try outside.dir.writeFile(io, .{ .sub_path = ".env", .data = "OUTSIDE-SECRET-CANARY" });
    outside.dir.hardLink(".env", workspace.dir, "config.txt", io, .{}) catch return error.SkipZigTest;
    try workspace.dir.writeFile(io, .{ .sub_path = "ordinary.txt", .data = "plain" });

    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const aliases = try collectSecretHardlinkAliasPaths(allocator, io, root);
    defer freeHardlinkAliasPaths(allocator, aliases);

    try std.testing.expectEqual(@as(usize, 1), aliases.len);
    try std.testing.expect(std.mem.endsWith(u8, aliases[0], "config.txt"));
    try std.testing.expect(!std.mem.endsWith(u8, aliases[0], "ordinary.txt"));
}

test "collectSecretHardlinkAliasPaths skips workspace symlinks without ScanOpenFailed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "secret-body" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "plain" });
    tmp.dir.symLink(io, "target.txt", "shim", .{}) catch return error.SkipZigTest;
    tmp.dir.hardLink(".env", tmp.dir, "alias.txt", io, .{}) catch return error.SkipZigTest;

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const aliases = try collectSecretHardlinkAliasPaths(allocator, io, root);
    defer freeHardlinkAliasPaths(allocator, aliases);

    try std.testing.expectEqual(@as(usize, 1), aliases.len);
    try std.testing.expect(std.mem.endsWith(u8, aliases[0], "alias.txt"));
}

test "collectSecretHardlinkAliasPaths fails closed on mode-000 nested directory" {
    // Unreadable nested dir with secret + root hardlink alias must not soft-skip
    // the dir (fail open). Scan returns ScanOpenFailed so prepare fails closed.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/.env", .data = "secret-body" });
    tmp.dir.hardLink("d/.env", tmp.dir, "notes.txt", io, .{}) catch return error.SkipZigTest;

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const nested = try std.fs.path.join(allocator, &.{ root, "d" });
    defer allocator.free(nested);
    const nested_z = try allocator.dupeZ(u8, nested);
    defer allocator.free(nested_z);

    // Drop all perms on nested dir; restore so tmpDir cleanup can remove it.
    if (std.c.chmod(nested_z.ptr, 0) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(nested_z.ptr, 0o755);

    try std.testing.expectError(
        error.ScanOpenFailed,
        collectSecretHardlinkAliasPaths(allocator, io, root),
    );
}

test "collectSecretHardlinkAliasPaths missing workspace is empty not ScanOpenFailed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const aliases = try collectSecretHardlinkAliasPaths(
        allocator,
        io,
        "/tmp/orca-hardlink-scan-missing-ws-does-not-exist",
    );
    defer freeHardlinkAliasPaths(allocator, aliases);
    try std.testing.expectEqual(@as(usize, 0), aliases.len);
}

test "secret hardlink scan capacity matches Linux monorepo floor" {
    // Regression: 50_000 was below typical monorepo dirent counts (node_modules,
    // vendor checkouts, SPM .build) and blocked protect-on Seatbelt prepare.
    try std.testing.expect(secret_hardlink_scan_max_entries >= 1_000_000);
    try std.testing.expect(secret_hardlink_scan_max_depth >= 48);
}

test "secret policy: SBPL emit embeds profile-owned fragments; path == basename law" {
    // Product law is a single basename classifier. SBPL emission must embed only
    // profile-owned regex fragments (no local .env regex). Live denial is proven
    // by process canaries, not a second pure simulator alias.
    const basenames = [_][]const u8{
        ".env",
        ".env.local",
        ".env.production",
        ".env.example.local",
        ".env.example",
        ".env.sample",
        ".env.template",
        ".envrc",
        "notes.txt",
        "service.env",
        ".env.",
        "env",
        ".ENV",
    };

    for (basenames) |name| {
        const zig = profile.isWorkspaceSecretBasename(name);
        try std.testing.expectEqual(zig, profile.isWorkspaceSecretPath(name));
        // Path form basenames via basename(); classifier is component-level.
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/workspace/{s}", .{name});
        try std.testing.expectEqual(zig, profile.isWorkspaceSecretPath(path));
    }

    // Template stems in SBPL alt are derived only from the name list.
    try std.testing.expectEqualStrings("example|sample|template", profile.workspace_secret_safe_template_sbpl_alt);
    for (profile.workspace_secret_safe_template_names) |full| {
        try std.testing.expect(std.mem.startsWith(u8, full, ".env."));
        const stem = full[".env.".len..];
        try std.testing.expect(std.mem.indexOf(u8, profile.workspace_secret_safe_template_sbpl_alt, stem) != null);
    }

    const allocator = std.testing.allocator;
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = "/workspace/app",
        .system_ro_prefixes = &[_][]const u8{"/usr"},
        .protect_workspace_secrets = true,
    });
    defer compiled.deinit();
    const sbpl = try renderSbpl(allocator, &compiled);
    defer allocator.free(sbpl);

    // Form regex + template require-not come only from profile constants.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, profile.workspace_secret_form_sbpl_regex) != null);
    var needle_buf: [160]u8 = undefined;
    const needle = try std.fmt.bufPrint(
        &needle_buf,
        "(require-not (regex #\"/[.]env[.]({s})$\"))",
        .{profile.workspace_secret_safe_template_sbpl_alt},
    );
    try std.testing.expect(std.mem.indexOf(u8, sbpl, needle) != null);

    // Emission helper matches what SBPL contains (single emission path).
    var pred: std.ArrayList(u8) = .empty;
    defer pred.deinit(allocator);
    try profile.appendWorkspaceSecretSbplRegexPredicates(&pred, allocator);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, pred.items) != null);
}
