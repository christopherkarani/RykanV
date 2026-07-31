//! Narrow host-agent config grants for empty-backpack Seatbelt/Landlock.
//!
//! Empty backpack keeps `HOME=` in the child env but does **not** grant `$HOME`
//! as a filesystem tree. Known agent hosts still need their login/config roots
//! (e.g. `~/.claude`, Application Support trees) so interactive / `-p` paths do
//! not blank-hang after `sandbox=active`.
//!
//! Contract:
//! - Grant only explicit per-host subpaths that already exist on disk.
//! - Paths compile as **RW** so agents can write session/history under their own
//!   roots — still never bare `$HOME`, bare `~/Library`, or `~/.ssh`.
//! - Non-host `ryk run -- /bin/echo` collects an empty list (no fail-closed).

const std = @import("std");
const builtin = @import("builtin");

/// Home-relative config roots for a launch host basename (exact match).
pub const HostConfigSpec = struct {
    host: []const u8,
    /// Directory roots under `$HOME` (no leading `/`).
    home_rel_dirs: []const []const u8,
    /// Home-relative files that count as usable login material (any one non-empty).
    /// Empty list → directory presence alone is enough (weaker, host-specific).
    login_markers: []const []const u8 = &.{},
};

/// Authoritative grant table for host-launch aliases that need host login stores.
/// Keep this tighter than scan session discovery (full config root, not only
/// `projects/` / `sessions/` leaves).
/// Paths compile as **RW** (session write under the agent root) — never bare `$HOME`.
pub const host_config_table = [_]HostConfigSpec{
    .{
        .host = "claude",
        .home_rel_dirs = &.{
            ".claude",
            // Install tree for updates/assets next to the self-contained binary.
            ".local/share/claude",
            // Claude Code / desktop OAuth + CLI node state (not bare ~/Library).
            "Library/Application Support/Claude",
            "Library/Application Support/claude-cli-nodejs",
            "Library/Caches/claude-cli-nodejs",
        },
        // OAuth / CLI login blob. Expired tokens are still "present" — hang residual
        // is host auth/network, not missing config (see empty-backpack tip on agent exit).
        .login_markers = &.{".claude/.credentials.json"},
    },
    .{
        .host = "codex",
        .home_rel_dirs = &.{".codex"},
        .login_markers = &.{ ".codex/auth.json", ".codex/config.toml" },
    },
    .{
        .host = "pi",
        .home_rel_dirs = &.{".pi"},
    },
    .{
        .host = "opencode",
        .home_rel_dirs = &.{
            ".config/opencode",
            ".local/share/opencode",
        },
    },
    .{
        .host = "openclaw",
        .home_rel_dirs = &.{".openclaw"},
    },
    .{
        .host = "hermes",
        .home_rel_dirs = &.{".hermes"},
    },
};

/// Basename of argv0 (`claude`, or `…/claude` → `claude`). Empty if no basename.
pub fn hostBasename(argv0: []const u8) []const u8 {
    if (argv0.len == 0) return "";
    return std.fs.path.basename(argv0);
}

/// Lookup table entry for an exact host basename, or null.
pub fn specForHost(host: []const u8) ?*const HostConfigSpec {
    if (host.len == 0) return null;
    for (&host_config_table) |*spec| {
        if (std.mem.eql(u8, spec.host, host)) return spec;
    }
    return null;
}

/// True when a home-relative segment list is unsafe (empty, `.`, `..`).
pub fn relHasUnsafeComponents(rel: []const u8) bool {
    if (rel.len == 0) return true;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue; // tolerate accidental //
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

/// True when `path` is forbidden as a host-config grant (root, bare home, .ssh,
/// bare Library / Application Support). `path` must be absolute; callers should
/// pass lexically cleaned paths (no `..` components — see `relHasUnsafeComponents`).
pub fn isForbiddenHostConfigPath(path: []const u8, home: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len == 1 and path[0] == '/') return true;
    if (home.len > 0 and std.mem.eql(u8, path, home)) return true;
    // Never grant classic secret / over-broad home trees even if a table drifts.
    if (home.len > 0 and std.mem.startsWith(u8, path, home) and
        (path.len == home.len or path[home.len] == '/'))
    {
        const rest = if (path.len > home.len) path[home.len + 1 ..] else "";
        if (std.mem.eql(u8, rest, ".ssh") or std.mem.startsWith(u8, rest, ".ssh/")) return true;
        if (std.mem.eql(u8, rest, ".gnupg") or std.mem.startsWith(u8, rest, ".gnupg/")) return true;
        if (std.mem.eql(u8, rest, ".aws") or std.mem.startsWith(u8, rest, ".aws/")) return true;
        // Bare Library / Application Support / Keychains / Cookies would open host secrets.
        if (std.mem.eql(u8, rest, "Library") or
            std.mem.eql(u8, rest, "Library/Application Support") or
            std.mem.eql(u8, rest, "Library/Caches") or
            std.mem.eql(u8, rest, "Library/Keychains") or
            std.mem.startsWith(u8, rest, "Library/Keychains/") or
            std.mem.eql(u8, rest, "Library/Cookies") or
            std.mem.startsWith(u8, rest, "Library/Cookies/"))
            return true;
    }
    return false;
}

/// Collect owned absolute host-config grant paths for a host launch binary.
///
/// - Empty when argv0 is not a known host, HOME is empty, or no listed roots exist.
/// - Skips missing paths (caller may fail closed when a known host has zero grants
///   and no provider gateway).
/// - Never returns bare HOME or `.ssh`.
/// - Callers compile these as `.rw` (session write) — still narrow trees only.
///
/// Caller frees with `freeHostConfigPaths`.
pub fn collectHostConfigPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv0: []const u8,
    home: []const u8,
) error{OutOfMemory}![]const []const u8 {
    const host = hostBasename(argv0);
    const spec = specForHost(host) orelse {
        return try allocator.alloc([]const u8, 0);
    };
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) {
        return try allocator.alloc([]const u8, 0);
    }
    // Note: do not call isForbiddenHostConfigPath(home, home) — bare HOME is always
    // "forbidden as a grant", which would empty the list before any subpath is considered.

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    for (spec.home_rel_dirs) |rel| {
        if (rel.len == 0) continue;
        // Reject traversal / self-ref components before join (forbid filter is stringy).
        if (relHasUnsafeComponents(rel)) continue;
        const joined = try std.fs.path.join(allocator, &.{ home, rel });
        defer allocator.free(joined);
        if (isForbiddenHostConfigPath(joined, home)) continue;

        // Only grant paths that exist (dir or file). Missing → skip.
        if (!pathExists(io, joined)) continue;

        // Dedup exact strings.
        var exists = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, joined)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;

        const owned = try allocator.dupe(u8, joined);
        list.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeHostConfigPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// True when a known host has at least one listed config root present under home.
pub fn hostConfigPresent(
    io: std.Io,
    argv0: []const u8,
    home: []const u8,
) bool {
    const host = hostBasename(argv0);
    const spec = specForHost(host) orelse return false;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return false;
    for (spec.home_rel_dirs) |rel| {
        if (rel.len == 0 or relHasUnsafeComponents(rel)) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, rel }) catch continue;
        if (isForbiddenHostConfigPath(joined, home)) continue;
        if (pathExists(io, joined)) return true;
    }
    return false;
}

/// True when a non-empty login marker file is readable, or (if the host has no
/// markers) when a config root exists. Config dir alone is not enough for Claude.
pub fn hostLoginMaterialPresent(
    io: std.Io,
    argv0: []const u8,
    home: []const u8,
) bool {
    const host = hostBasename(argv0);
    const spec = specForHost(host) orelse return false;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return false;
    if (spec.login_markers.len == 0) return hostConfigPresent(io, argv0, home);
    for (spec.login_markers) |rel| {
        if (rel.len == 0 or relHasUnsafeComponents(rel)) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, rel }) catch continue;
        if (isForbiddenHostConfigPath(joined, home)) continue;
        if (nonEmptyFileExists(io, joined)) return true;
    }
    return false;
}

fn nonEmptyFileExists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    return st.size > 0;
}

/// Claude OAuth access-token expiry when readable. Other hosts always `.unknown`.
/// Does not log or return token bytes — only the freshness class.
pub const LoginFreshness = enum {
    /// No marker / unreadable / not applicable.
    unknown,
    /// Marker present; no expiry field or not yet expired.
    fresh,
    /// `claudeAiOauth.expiresAt` (unix ms) is in the past.
    expired,
};

/// Best-effort Claude credential freshness. Never loads secrets into the return value.
pub fn claudeLoginFreshness(io: std.Io, home: []const u8) LoginFreshness {
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return .unknown;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.claude/.credentials.json", .{home}) catch return .unknown;
    if (isForbiddenHostConfigPath(path, home)) return .unknown;

    // Bound read — credentials files are small; never log body contents.
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .unknown;
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return .unknown;
    if (n == 0) return .unknown;
    const body = buf[0..n];

    // Minimal structural parse: find "expiresAt" numeric (ms since epoch).
    const key = "\"expiresAt\"";
    const key_at = std.mem.indexOf(u8, body, key) orelse return .fresh; // present file, no field
    var i = key_at + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r' or body[i] == ':')) : (i += 1) {}
    if (i >= body.len or body[i] < '0' or body[i] > '9') return .fresh;
    var exp: u64 = 0;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        const digit: u64 = body[i] - '0';
        exp = exp *% 10 +% digit;
    }
    if (exp == 0) return .fresh;
    // expiresAt is milliseconds; Io wall clock is seconds.
    const now_s = std.Io.Timestamp.now(io, .real).toSeconds();
    if (now_s < 0) return .fresh;
    const now_ms: u64 = @as(u64, @intCast(now_s)) * 1000;
    if (exp < now_ms) return .expired;
    return .fresh;
}

/// Usable auth markers present (non-empty login files / config roots). Does **not**
/// reject expired OAuth — use `claudeLoginFreshness` + `isAgentHelpOrVersionOnly`
/// so `--help` still works under empty backpack with stale credentials.
pub fn hostUsableAuthPresent(
    io: std.Io,
    argv0: []const u8,
    home: []const u8,
) bool {
    return hostLoginMaterialPresent(io, argv0, home);
}

/// True when argv after the binary is only help/version flags (no prompt / -p).
/// Bare interactive (`claude` alone) is **not** help-only.
pub fn isAgentHelpOrVersionOnly(command_argv: []const []const u8) bool {
    if (command_argv.len < 2) return false;
    for (command_argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "--version") or
            std.mem.eql(u8, arg, "-v") or
            std.mem.eql(u8, arg, "version") or
            std.mem.eql(u8, arg, "-V"))
        {
            continue;
        }
        return false;
    }
    return true;
}

/// True when Claude OAuth is known-expired and the launch is not help/version-only.
/// Call only after marker presence has already passed.
pub fn shouldFailClosedStaleClaudeLogin(
    io: std.Io,
    command_argv: []const []const u8,
    home: []const u8,
    has_anthropic_gateway: bool,
) bool {
    if (has_anthropic_gateway) return false;
    if (command_argv.len == 0) return false;
    if (!std.mem.eql(u8, hostBasename(command_argv[0]), "claude")) return false;
    if (isAgentHelpOrVersionOnly(command_argv)) return false;
    return claudeLoginFreshness(io, home) == .expired;
}

/// True when `path` exists as a directory or regular openable file.
fn pathExists(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
        file.close(io);
        return true;
    };
    dir.close(io);
    return true;
}

/// Static stderr guidance when empty backpack cannot offer host login or gateway.
pub const missing_config_fail_closed_message =
    \\ryk run: empty-backpack OS sandbox cannot read host agent login/config under $HOME.
    \\No usable host login material was found (for example ~/.claude/.credentials.json) and no matching provider gateway is active.
    \\Fix one of:
    \\  • run the agent once outside ryk to create host login (e.g. `claude` then login), then retry
    \\  • for Claude: export ANTHROPIC_API_KEY; for Codex: export OPENAI_API_KEY (host-matched gateway)
    \\  • escape with `ryk run --with-host-secrets -- <agent>` (loud; may expose host secrets)
    \\See docs/credentials.md
    \\
;

/// When Claude credentials exist but the OAuth access token is past expiresAt.
pub const stale_login_fail_closed_message =
    \\ryk run: empty-backpack found Claude login material, but the OAuth access token is expired (expiresAt in the past).
    \\Without a host-matched Anthropic gateway this often blank-hangs after sandbox=active.
    \\Fix one of:
    \\  • re-login outside ryk (`claude` then login) so ~/.claude/.credentials.json is fresh
    \\  • export ANTHROPIC_API_KEY (host-matched gateway under empty backpack)
    \\  • escape with `ryk run --with-host-secrets -- claude` (loud; may expose host secrets)
    \\See docs/credentials.md
    \\
;

/// Primary tip when parent stdout/stderr path is under classic ungranted host tmp
/// (inherited shell redirects). Leads with stdio/fstat residual — not re-login.
pub const empty_backpack_stdio_fstat_exit_tip =
    \\ryk run: empty-backpack: agent died after sandbox attach — redirected stdout/stderr lands under classic /tmp or /var/folders, which Seatbelt does not grant. Bun/Node fstat on those FDs fails (EPERM / process.stderr.fd). Capture under the workspace (e.g. .orca-tmp), use a pipe, or a TTY. Do not treat this as missing login first. Keychain FS is not granted (by design).
    \\
;

/// Tip when agent output shows Seatbelt path-walk residual (EPERM on lstat/realpath
/// of path parents). Prefer this over re-login when the stack is clear.
pub const empty_backpack_pathwalk_exit_tip =
    \\ryk run: empty-backpack: agent died after sandbox attach — Seatbelt path-walk residual (EPERM on lstat/realpath of a path parent such as /Users). This is an OS-sandbox filesystem residual, not missing host login. If it persists on a current ryk build, report it; do not re-login first. Keychain FS is not granted (by design).
    \\
;

/// Generic tip when empty-backpack agent exits non-zero without a more specific residual.
pub const empty_backpack_agent_exit_tip =
    \\ryk run: empty-backpack tip: agent exited non-zero after sandbox attach. Common causes: Seatbelt path-walk EPERM (lstat/realpath on path parents), redirected stdio into /tmp or /var/folders (fstat denials — capture under the workspace), stale host auth (re-login outside ryk), missing host-matched API key for gateway, or --with-host-secrets (loud). Keychain FS is not granted (by design).
    \\
;

/// Pre-spawn warning when parent stdio already points at ungranted host tmp.
pub const empty_backpack_stdio_host_tmp_warn =
    \\ryk run: warning: stdout/stderr appear redirected under /tmp or /var/folders; empty-backpack Seatbelt may deny agent fstat on those FDs. Prefer workspace capture, pipe, or TTY.
    \\
;

/// True when `path` is classic host temp content empty backpack does not grant.
/// Bootstrap may allow the literal `/private/tmp` directory node only — not tree contents.
pub fn pathIsUngrantedHostTmpContent(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.eql(u8, path, "/tmp") or std.mem.eql(u8, path, "/private/tmp")) return true;
    if (std.mem.startsWith(u8, path, "/tmp/")) return true;
    if (std.mem.startsWith(u8, path, "/private/tmp/")) return true;
    if (std.mem.startsWith(u8, path, "/var/folders/")) return true;
    if (std.mem.startsWith(u8, path, "/private/var/folders/")) return true;
    return false;
}

/// Resolve a pathname for an open FD when the platform supports it.
/// macOS: F_GETPATH. Linux: /proc/self/fd/N. Other: null.
/// Caller must pass a buffer of at least `std.fs.max_path_bytes` (Darwin F_GETPATH
/// writes up to PATH_MAX; a short buffer would be a length-blind kernel write).
pub fn resolveFdPathname(fd: std.posix.fd_t, buf: []u8) ?[]const u8 {
    if (buf.len < std.fs.max_path_bytes) return null;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Darwin F_GETPATH (sys/fcntl.h) writes a NUL-terminated path into buf.
            const F_GETPATH: c_int = 50;
            @memset(buf[0..std.fs.max_path_bytes], 0);
            const rc = std.c.fcntl(@as(c_int, @intCast(fd)), F_GETPATH, buf.ptr);
            if (rc != 0) return null;
            return std.mem.sliceTo(buf, 0);
        },
        .linux => {
            var link_path_buf: [64]u8 = undefined;
            const link_path = std.fmt.bufPrint(&link_path_buf, "/proc/self/fd/{d}", .{fd}) catch return null;
            const n = std.posix.readlink(link_path, buf) catch return null;
            return buf[0..n];
        },
        else => return null,
    }
}

/// True when parent process stdout (1) or stderr (2) path is under ungranted host tmp.
/// Used for tip selection and pre-spawn warning (shell redirects open FDs before fork).
pub fn parentStdioHasUngrantedHostTmpRisk() bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (resolveFdPathname(1, &path_buf)) |path| {
        if (pathIsUngrantedHostTmpContent(path)) return true;
    }
    if (resolveFdPathname(2, &path_buf)) |path| {
        if (pathIsUngrantedHostTmpContent(path)) return true;
    }
    return false;
}

/// Inputs for empty-backpack post-exit tip selection (priority order below).
pub const EmptyBackpackExitTipInput = struct {
    /// Parent stdout/stderr path under classic ungranted host tmp.
    stdio_host_tmp_risk: bool = false,
    /// Captured agent stderr/stdout when available (inherit mode often has none).
    agent_output: ?[]const u8 = null,
};

/// True when text looks like Seatbelt path-walk residual (EPERM + lstat/realpath).
/// Case-insensitive on the operation keywords; used when agent output is retained.
pub fn stderrLooksLikeSeatbeltPathWalkResidual(text: []const u8) bool {
    if (text.len == 0) return false;
    const has_eperm = std.ascii.indexOfIgnoreCase(text, "EPERM") != null or
        std.ascii.indexOfIgnoreCase(text, "operation not permitted") != null or
        std.ascii.indexOfIgnoreCase(text, "Permission denied") != null or
        std.ascii.indexOfIgnoreCase(text, "PermissionError") != null;
    if (!has_eperm) return false;
    return std.ascii.indexOfIgnoreCase(text, "lstat") != null or
        std.ascii.indexOfIgnoreCase(text, "realpath") != null or
        std.ascii.indexOfIgnoreCase(text, "resolveMainPath") != null;
}

/// Pick empty-backpack post-exit tip:
/// 1) stdio/fstat residual when parent FD path is ungranted host tmp
/// 2) path-walk residual when agent_output matches EPERM + lstat/realpath
/// 3) generic tip (auth / gateway / remaining residuals)
pub fn selectEmptyBackpackAgentExitTip(input: EmptyBackpackExitTipInput) []const u8 {
    if (input.stdio_host_tmp_risk) return empty_backpack_stdio_fstat_exit_tip;
    if (input.agent_output) |text| {
        if (stderrLooksLikeSeatbeltPathWalkResidual(text)) return empty_backpack_pathwalk_exit_tip;
    }
    return empty_backpack_agent_exit_tip;
}

/// Choose the fail-closed stderr blob for a known host with unusable auth.
pub fn failClosedMessageFor(
    io: std.Io,
    argv0: []const u8,
    home: []const u8,
) []const u8 {
    const host = hostBasename(argv0);
    if (std.mem.eql(u8, host, "claude") and
        hostLoginMaterialPresent(io, argv0, home) and
        claudeLoginFreshness(io, home) == .expired)
    {
        return stale_login_fail_closed_message;
    }
    return missing_config_fail_closed_message;
}

/// Which loopback provider gateway can substitute host login for this agent.
pub const GatewayKind = enum {
    none,
    anthropic,
    openai,
};

/// Host → relevant gateway. Unknown / non-model hosts get `.none` (config only).
pub fn gatewayKindForHost(host: []const u8) GatewayKind {
    if (std.mem.eql(u8, host, "claude")) return .anthropic;
    if (std.mem.eql(u8, host, "codex")) return .openai;
    // pi / opencode / openclaw / hermes: no assumed env-key gateway substitute.
    return .none;
}

/// Empty-backpack agent launch without usable login material and without a
/// **relevant** provider gateway would blank-hang. Call only for known hosts.
/// `has_usable_auth` is typically `hostUsableAuthPresent` (login markers when
/// defined, else config-root presence).
pub fn shouldFailClosedMissingAuth(
    host: []const u8,
    has_anthropic_gateway: bool,
    has_openai_gateway: bool,
    has_usable_auth: bool,
) bool {
    if (has_usable_auth) return false;
    return switch (gatewayKindForHost(host)) {
        .anthropic => !has_anthropic_gateway,
        .openai => !has_openai_gateway,
        .none => true,
    };
}

test "hostBasename strips path components" {
    try std.testing.expectEqualStrings("claude", hostBasename("claude"));
    try std.testing.expectEqualStrings("claude", hostBasename("/Users/x/.local/bin/claude"));
    try std.testing.expectEqualStrings("codex", hostBasename("codex"));
    try std.testing.expectEqualStrings("", hostBasename(""));
}

test "specForHost exact allowlist only" {
    try std.testing.expect(specForHost("claude") != null);
    try std.testing.expect(specForHost("codex") != null);
    try std.testing.expect(specForHost("Claude") == null);
    try std.testing.expect(specForHost("echo") == null);
    try std.testing.expect(specForHost("") == null);
}

test "isForbiddenHostConfigPath rejects root home and ssh" {
    const home = "/Users/dev";
    try std.testing.expect(isForbiddenHostConfigPath("/", home));
    try std.testing.expect(isForbiddenHostConfigPath(home, home));
    try std.testing.expect(isForbiddenHostConfigPath("/Users/dev/.ssh", home));
    try std.testing.expect(isForbiddenHostConfigPath("/Users/dev/.ssh/id_rsa", home));
    try std.testing.expect(!isForbiddenHostConfigPath("/Users/dev/.claude", home));
    try std.testing.expect(!isForbiddenHostConfigPath("/Users/dev/.local/share/claude", home));
}

test "collectHostConfigPaths grants existing claude roots and skips missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home = try home_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);

    try home_tmp.dir.createDirPath(io, ".claude");
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".claude/settings.json", .data = "{}\n" });
    // No .local/share/claude — must be skipped.

    const want_claude = try std.fs.path.join(allocator, &.{ home, ".claude" });
    defer allocator.free(want_claude);
    // Prove the fixture is visible before collect (isolates collector bugs).
    try std.testing.expect(pathExists(io, want_claude));

    const paths = try collectHostConfigPaths(io, allocator, "claude", home);
    defer freeHostConfigPaths(allocator, paths);

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings(want_claude, paths[0]);

    // Sibling secret tree never granted even if present.
    try home_tmp.dir.createDirPath(io, ".ssh");
    const paths2 = try collectHostConfigPaths(io, allocator, "claude", home);
    defer freeHostConfigPaths(allocator, paths2);
    for (paths2) |p| {
        try std.testing.expect(std.mem.indexOf(u8, p, ".ssh") == null);
        try std.testing.expect(!std.mem.eql(u8, p, home));
    }
}

test "collectHostConfigPaths empty for non-host and missing config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home = try home_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);

    {
        const paths = try collectHostConfigPaths(io, allocator, "/bin/echo", home);
        defer freeHostConfigPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
    {
        // Known host but no config dir yet.
        const paths = try collectHostConfigPaths(io, allocator, "claude", home);
        defer freeHostConfigPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
        try std.testing.expect(!hostConfigPresent(io, "claude", home));
    }
}

test "collectHostConfigPaths rejects empty or relative HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        const paths = try collectHostConfigPaths(io, allocator, "claude", "");
        defer freeHostConfigPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
    {
        const paths = try collectHostConfigPaths(io, allocator, "claude", "relative-home");
        defer freeHostConfigPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
}

test "hostLoginMaterialPresent requires credentials not only config dir for claude" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home = try home_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);

    try home_tmp.dir.createDirPath(io, ".claude");
    try std.testing.expect(hostConfigPresent(io, "claude", home));
    try std.testing.expect(!hostLoginMaterialPresent(io, "claude", home));
    try std.testing.expect(!hostUsableAuthPresent(io, "claude", home));

    // No expiresAt → treat as present/fresh enough for preflight.
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".claude/.credentials.json", .data = "{\"claudeAiOauth\":{}}\n" });
    try std.testing.expect(hostLoginMaterialPresent(io, "claude", home));
    try std.testing.expect(hostUsableAuthPresent(io, "claude", home));
    try std.testing.expect(claudeLoginFreshness(io, home) == .fresh);

    // Empty credentials file is not usable.
    try home_tmp.dir.writeFile(io, .{ .sub_path = ".claude/.credentials.json", .data = "" });
    try std.testing.expect(!hostLoginMaterialPresent(io, "claude", home));

    // Expired access token → material present; stale fail-closed is separate.
    try home_tmp.dir.writeFile(io, .{
        .sub_path = ".claude/.credentials.json",
        .data = "{\"claudeAiOauth\":{\"expiresAt\":1}}\n",
    });
    try std.testing.expect(hostLoginMaterialPresent(io, "claude", home));
    try std.testing.expect(hostUsableAuthPresent(io, "claude", home));
    try std.testing.expect(claudeLoginFreshness(io, home) == .expired);
    try std.testing.expect(shouldFailClosedStaleClaudeLogin(io, &.{ "claude", "-p", "hi" }, home, false));
    try std.testing.expect(!shouldFailClosedStaleClaudeLogin(io, &.{ "claude", "--help" }, home, false));
    try std.testing.expect(!shouldFailClosedStaleClaudeLogin(io, &.{ "claude", "-p", "hi" }, home, true)); // gateway

    // Far-future expiry remains fresh.
    try home_tmp.dir.writeFile(io, .{
        .sub_path = ".claude/.credentials.json",
        .data = "{\"claudeAiOauth\":{\"expiresAt\":9999999999999}}\n",
    });
    try std.testing.expect(claudeLoginFreshness(io, home) == .fresh);
    try std.testing.expect(!shouldFailClosedStaleClaudeLogin(io, &.{"claude"}, home, false));

    try std.testing.expect(isAgentHelpOrVersionOnly(&.{ "claude", "--help" }));
    try std.testing.expect(isAgentHelpOrVersionOnly(&.{ "claude", "--version" }));
    try std.testing.expect(!isAgentHelpOrVersionOnly(&.{"claude"}));
    try std.testing.expect(!isAgentHelpOrVersionOnly(&.{ "claude", "-p", "x" }));

    // pi has no markers → config dir alone is enough.
    try home_tmp.dir.createDirPath(io, ".pi");
    try std.testing.expect(hostLoginMaterialPresent(io, "pi", home));
}

test "failClosedMessageFor prefers stale when credentials expired" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home = try home_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    try home_tmp.dir.createDirPath(io, ".claude");
    try home_tmp.dir.writeFile(io, .{
        .sub_path = ".claude/.credentials.json",
        .data = "{\"claudeAiOauth\":{\"expiresAt\":1}}\n",
    });
    try std.testing.expect(std.mem.indexOf(u8, failClosedMessageFor(io, "claude", home), "expired") != null);
}

test "shouldFailClosedMissingAuth edge matrix is host-aware" {
    // Claude: Anthropic gateway substitutes; OpenAI alone does not.
    try std.testing.expect(shouldFailClosedMissingAuth("claude", false, false, false));
    try std.testing.expect(!shouldFailClosedMissingAuth("claude", true, false, false));
    try std.testing.expect(shouldFailClosedMissingAuth("claude", false, true, false));
    try std.testing.expect(!shouldFailClosedMissingAuth("claude", false, false, true));

    // Codex: OpenAI gateway substitutes; Anthropic alone does not.
    try std.testing.expect(shouldFailClosedMissingAuth("codex", false, false, false));
    try std.testing.expect(!shouldFailClosedMissingAuth("codex", false, true, false));
    try std.testing.expect(shouldFailClosedMissingAuth("codex", true, false, false));

    // Pi / hermes: config only (no gateway substitute).
    try std.testing.expect(shouldFailClosedMissingAuth("pi", true, true, false));
    try std.testing.expect(!shouldFailClosedMissingAuth("pi", false, false, true));
}

test "relHasUnsafeComponents rejects traversal" {
    try std.testing.expect(relHasUnsafeComponents(""));
    try std.testing.expect(relHasUnsafeComponents(".claude/../.ssh"));
    try std.testing.expect(relHasUnsafeComponents("foo/./bar"));
    try std.testing.expect(!relHasUnsafeComponents(".claude"));
    try std.testing.expect(!relHasUnsafeComponents("Library/Application Support/Claude"));
}

test "isForbiddenHostConfigPath rejects keychains and traversal survivors" {
    const home = "/Users/dev";
    try std.testing.expect(isForbiddenHostConfigPath("/Users/dev/Library/Keychains", home));
    try std.testing.expect(isForbiddenHostConfigPath("/Users/dev/Library/Cookies/Cookies.binarycookies", home));
    try std.testing.expect(isForbiddenHostConfigPath("/Users/dev/Library", home));
    try std.testing.expect(!isForbiddenHostConfigPath("/Users/dev/Library/Application Support/Claude", home));
}

test "collectHostConfigPaths on real HOME includes .claude when present" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const home_z = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.span(home_z);
    if (!std.fs.path.isAbsolute(home)) return error.SkipZigTest;
    if (!hostConfigPresent(io, "claude", home)) return error.SkipZigTest;

    const paths = try collectHostConfigPaths(io, allocator, "claude", home);
    defer freeHostConfigPaths(allocator, paths);
    try std.testing.expect(paths.len >= 1);
    var found_claude = false;
    for (paths) |p| {
        try std.testing.expect(!std.mem.eql(u8, p, home));
        try std.testing.expect(std.mem.indexOf(u8, p, ".ssh") == null);
        if (std.mem.endsWith(u8, p, "/.claude")) found_claude = true;
    }
    try std.testing.expect(found_claude);
}

test "missing_config_fail_closed_message names login material" {
    try std.testing.expect(std.mem.indexOf(u8, missing_config_fail_closed_message, ".credentials.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_backpack_agent_exit_tip, "var/folders") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_backpack_agent_exit_tip, "Keychain") != null);
}

test "pathIsUngrantedHostTmpContent classifies classic tmp vs workspace" {
    try std.testing.expect(pathIsUngrantedHostTmpContent("/tmp/ryk-probe-out.txt"));
    try std.testing.expect(pathIsUngrantedHostTmpContent("/tmp"));
    try std.testing.expect(pathIsUngrantedHostTmpContent("/private/tmp/err.txt"));
    try std.testing.expect(pathIsUngrantedHostTmpContent("/private/tmp"));
    try std.testing.expect(pathIsUngrantedHostTmpContent("/var/folders/xx/yy/T/out.txt"));
    try std.testing.expect(pathIsUngrantedHostTmpContent("/private/var/folders/ab/cd/T/err.txt"));
    try std.testing.expect(!pathIsUngrantedHostTmpContent(""));
    try std.testing.expect(!pathIsUngrantedHostTmpContent("/Users/me/proj/.orca-tmp/out.txt"));
    try std.testing.expect(!pathIsUngrantedHostTmpContent("/dev/null"));
    try std.testing.expect(!pathIsUngrantedHostTmpContent("/private/var/log/system.log"));
    // Prefix must not false-positive adjacent names.
    try std.testing.expect(!pathIsUngrantedHostTmpContent("/tmpish/foo"));
    try std.testing.expect(!pathIsUngrantedHostTmpContent("/var/foldersish/x"));
}

test "selectEmptyBackpackAgentExitTip prefers stdio residual over re-login lead" {
    const stdio_tip = selectEmptyBackpackAgentExitTip(.{ .stdio_host_tmp_risk = true });
    try std.testing.expect(stdio_tip.ptr == empty_backpack_stdio_fstat_exit_tip.ptr);
    try std.testing.expect(std.mem.indexOf(u8, stdio_tip, "fstat") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdio_tip, "after sandbox attach") != null);
    // Must lead with stdio residual framing, not re-login / generic tip prefix.
    try std.testing.expect(std.mem.startsWith(u8, stdio_tip, "ryk run: empty-backpack: agent died after sandbox attach"));
    try std.testing.expect(std.mem.indexOf(u8, stdio_tip, "Do not treat this as missing login first") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdio_tip, "--with-host-secrets") == null);

    const generic_tip = selectEmptyBackpackAgentExitTip(.{});
    try std.testing.expect(generic_tip.ptr == empty_backpack_agent_exit_tip.ptr);
    try std.testing.expect(std.mem.indexOf(u8, generic_tip, "re-login") != null);
    try std.testing.expect(std.mem.indexOf(u8, generic_tip, "var/folders") != null);
    try std.testing.expect(std.mem.indexOf(u8, generic_tip, "path-walk") != null);
}

test "selectEmptyBackpackAgentExitTip prefers path-walk residual over re-login lead" {
    const node_stack =
        \\Error: EPERM: operation not permitted, lstat '/Users'
        \\    at Object.realpathSync (node:fs:1234:10)
        \\    at resolveMainPath (node:internal/modules/cjs/loader:1:1)
    ;
    const pathwalk_tip = selectEmptyBackpackAgentExitTip(.{ .agent_output = node_stack });
    try std.testing.expect(pathwalk_tip.ptr == empty_backpack_pathwalk_exit_tip.ptr);
    try std.testing.expect(std.mem.indexOf(u8, pathwalk_tip, "path-walk") != null);
    try std.testing.expect(std.mem.indexOf(u8, pathwalk_tip, "not missing host login") != null);
    try std.testing.expect(std.mem.indexOf(u8, pathwalk_tip, "re-login first") != null);
    // Must not lead operators to auth/gateway first.
    try std.testing.expect(std.mem.indexOf(u8, pathwalk_tip, "API key") == null);
    try std.testing.expect(std.mem.indexOf(u8, pathwalk_tip, "--with-host-secrets") == null);

    // Stdio residual still wins when both could apply.
    const stdio_wins = selectEmptyBackpackAgentExitTip(.{
        .stdio_host_tmp_risk = true,
        .agent_output = node_stack,
    });
    try std.testing.expect(stdio_wins.ptr == empty_backpack_stdio_fstat_exit_tip.ptr);

    try std.testing.expect(stderrLooksLikeSeatbeltPathWalkResidual(node_stack));
    try std.testing.expect(stderrLooksLikeSeatbeltPathWalkResidual(
        "PermissionError: [Errno 1] Operation not permitted\n  File \"...\", line 1, in <module>\n    os.lstat('/Users')\n",
    ));
    try std.testing.expect(!stderrLooksLikeSeatbeltPathWalkResidual("Error: invalid API key"));
    try std.testing.expect(!stderrLooksLikeSeatbeltPathWalkResidual("EPERM on fstat of redirected stderr"));
    try std.testing.expect(!stderrLooksLikeSeatbeltPathWalkResidual(""));
    try std.testing.expect(!stderrLooksLikeSeatbeltPathWalkResidual(
        "PermissionError: [Errno 1] Operation not permitted: '/Users'",
    ));
}

test "resolveFdPathname round-trips a /tmp file on supported platforms" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const path = "/tmp/ryk-stdio-risk-probe.txt";
    {
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "probe");
    }
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = resolveFdPathname(file.handle, &buf) orelse return error.SkipZigTest;
    try std.testing.expect(pathIsUngrantedHostTmpContent(resolved));
    // macOS often returns /private/tmp/...; Linux returns /tmp/...
    try std.testing.expect(
        std.mem.indexOf(u8, resolved, "ryk-stdio-risk-probe.txt") != null,
    );
}
