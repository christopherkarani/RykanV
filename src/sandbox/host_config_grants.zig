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

/// Home-relative config roots for a launch host basename (exact match).
pub const HostConfigSpec = struct {
    host: []const u8,
    /// Directory roots under `$HOME` (no leading `/`).
    home_rel_dirs: []const []const u8,
};

/// Authoritative grant table for host-launch aliases that need host login stores.
/// Keep this tighter than scan session discovery (full config root, not only
/// `projects/` / `sessions/` leaves).
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
    },
    .{
        .host = "codex",
        .home_rel_dirs = &.{".codex"},
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
/// Caller frees with `freeHostConfigRoPaths`.
pub fn collectHostConfigRoPaths(
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

pub fn freeHostConfigRoPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
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
    \\No agent config directory was found (for example ~/.claude) and no matching provider gateway is active.
    \\Fix one of:
    \\  • run the agent once outside ryk to create host login (e.g. `claude` then login), then retry
    \\  • for Claude: export ANTHROPIC_API_KEY; for Codex: export OPENAI_API_KEY (host-matched gateway)
    \\  • escape with `ryk run --with-host-secrets -- <agent>` (loud; may expose host secrets)
    \\See docs/credentials.md
    \\
;

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

/// Empty-backpack agent launch without host config and without a **relevant**
/// provider gateway would blank-hang. Call only for known host-config agents.
pub fn shouldFailClosedMissingAuth(
    host: []const u8,
    has_anthropic_gateway: bool,
    has_openai_gateway: bool,
    has_host_config: bool,
) bool {
    if (has_host_config) return false;
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

test "collectHostConfigRoPaths grants existing claude roots and skips missing" {
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

    const paths = try collectHostConfigRoPaths(io, allocator, "claude", home);
    defer freeHostConfigRoPaths(allocator, paths);

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings(want_claude, paths[0]);

    // Sibling secret tree never granted even if present.
    try home_tmp.dir.createDirPath(io, ".ssh");
    const paths2 = try collectHostConfigRoPaths(io, allocator, "claude", home);
    defer freeHostConfigRoPaths(allocator, paths2);
    for (paths2) |p| {
        try std.testing.expect(std.mem.indexOf(u8, p, ".ssh") == null);
        try std.testing.expect(!std.mem.eql(u8, p, home));
    }
}

test "collectHostConfigRoPaths empty for non-host and missing config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home = try home_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);

    {
        const paths = try collectHostConfigRoPaths(io, allocator, "/bin/echo", home);
        defer freeHostConfigRoPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
    {
        // Known host but no config dir yet.
        const paths = try collectHostConfigRoPaths(io, allocator, "claude", home);
        defer freeHostConfigRoPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
        try std.testing.expect(!hostConfigPresent(io, "claude", home));
    }
}

test "collectHostConfigRoPaths rejects empty or relative HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        const paths = try collectHostConfigRoPaths(io, allocator, "claude", "");
        defer freeHostConfigRoPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
    {
        const paths = try collectHostConfigRoPaths(io, allocator, "claude", "relative-home");
        defer freeHostConfigRoPaths(allocator, paths);
        try std.testing.expectEqual(@as(usize, 0), paths.len);
    }
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

test "collectHostConfigRoPaths on real HOME includes .claude when present" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const home_z = std.c.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.span(home_z);
    if (!std.fs.path.isAbsolute(home)) return error.SkipZigTest;
    if (!hostConfigPresent(io, "claude", home)) return error.SkipZigTest;

    const paths = try collectHostConfigRoPaths(io, allocator, "claude", home);
    defer freeHostConfigRoPaths(allocator, paths);
    try std.testing.expect(paths.len >= 1);
    var found_claude = false;
    for (paths) |p| {
        try std.testing.expect(!std.mem.eql(u8, p, home));
        try std.testing.expect(std.mem.indexOf(u8, p, ".ssh") == null);
        if (std.mem.endsWith(u8, p, "/.claude")) found_claude = true;
    }
    try std.testing.expect(found_claude);
}
