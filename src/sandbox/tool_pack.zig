//! Essentials tool pack + PATH honesty for OS-attached agent sessions.
//!
//! ## Tool pack (`ORCA_TOOL_PACK`)
//! When OS sandbox attach is active, a small **essentials** pack may add
//! file-only `.exec` grants for everyday coding tools that exist on the host:
//! `rg`, `fd`, `jq`, project `./scripts/zig` (or `zig` on PATH), and `git`.
//! Cap keeps SBPL size bounded. Never grants bare `$HOME` or package trees.
//!
//! ## PATH filter
//! **Honesty level: denylist (v1).** Under attach, child PATH drops well-known
//! ungranted host package prefixes (Homebrew, linuxbrew, …) so the agent does
//! not see tools that then EPERM. Safe system prefixes (`/usr/bin`, `/bin`, CLT,
//! …), the session shim dir, workspace paths, and parent dirs of pack-granted
//! tools are retained. Structure (`PathFilterHonesty`) allows a future
//! grant-aligned filter without API churn. Do **not** claim full grant alignment
//! while honesty remains `denylist`.

const std = @import("std");
const builtin = @import("builtin");
const apply_posix = @import("apply_posix.zig");

/// Env kill switch / selector.
pub const tool_pack_env = "ORCA_TOOL_PACK";

/// Max file-only `.exec` paths emitted by the pack (link + realpath + shebang extras).
pub const max_pack_exec_paths: usize = 16;

/// Pack selection.
pub const ToolPack = enum {
    /// Resolve and grant a small set of coding tools when present.
    essentials,
    /// No pack grants.
    none,

    pub fn toString(self: ToolPack) []const u8 {
        return switch (self) {
            .essentials => "essentials",
            .none => "none",
        };
    }
};

/// Documented honesty level for PATH filtering (banner/docs).
pub const PathFilterHonesty = enum {
    /// Drop known-bad ungranted package prefixes; keep safe system + shim + pack parents.
    denylist,
    /// Future: keep only dirs covered by RO/exec grants.
    grant_aligned,

    pub fn toString(self: PathFilterHonesty) []const u8 {
        return switch (self) {
            .denylist => "denylist",
            .grant_aligned => "grant-aligned",
        };
    }
};

/// Current PATH filter implementation level.
pub const path_filter_honesty: PathFilterHonesty = .denylist;

/// Options for `filterPathForSandbox`.
pub const PathFilterOpts = struct {
    /// Session shim directory — always first when non-null/non-empty.
    shim_dir: ?[]const u8 = null,
    /// Workspace root — keep PATH entries under this tree.
    workspace_root: ?[]const u8 = null,
    /// Absolute file paths granted by the essentials pack; their parent dirs stay on PATH.
    pack_exec_paths: []const []const u8 = &.{},
    /// Honesty mode (only denylist is implemented for v1).
    honesty: PathFilterHonesty = path_filter_honesty,
};

/// Parse `ORCA_TOOL_PACK` value. Unknown / empty → null (caller applies default).
pub fn parseToolPack(value: ?[]const u8) ?ToolPack {
    const raw = value orelse return null;
    if (raw.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(raw, "essentials")) return .essentials;
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
    return null;
}

/// Default pack when env is unset: essentials under OS attach (empty-backpack / host alias
/// or any attach path); none when sandbox is off.
pub fn defaultToolPack(os_attach: bool) ToolPack {
    return if (os_attach) .essentials else .none;
}

/// Resolve pack from env map + attach posture.
pub fn resolveToolPack(env_map: *const std.process.Environ.Map, os_attach: bool) ToolPack {
    if (parseToolPack(env_map.get(tool_pack_env))) |parsed| return parsed;
    return defaultToolPack(os_attach);
}

/// Resolve essentials binaries to owned absolute file paths for `.exec` grants.
/// Caller frees with `freePackExecPaths`. Empty when pack is none or nothing found.
pub fn collectPackExecPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    pack: ToolPack,
    workspace_root: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}![]const []const u8 {
    if (pack != .essentials) return try allocator.alloc([]const u8, 0);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeList(allocator, &list);

    // Project zig first (workspace pin), then PATH tools.
    try appendProjectZig(io, allocator, &list, workspace_root, env_map);
    try appendPathTool(io, allocator, &list, "rg", env_map);
    try appendPathTool(io, allocator, &list, "fd", env_map);
    try appendPathTool(io, allocator, &list, "jq", env_map);
    // git: shim resolves real binary after stripping shim dir — grant realpath so shim is usable.
    try appendPathTool(io, allocator, &list, "git", env_map);
    // Fallback: bare `zig` on PATH when project scripts/zig was missing.
    if (!listHasBasename(list.items, "zig")) {
        try appendPathTool(io, allocator, &list, "zig", env_map);
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freePackExecPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Max narrow RO trees for pack dylib/formula support (SBPL bound).
/// Includes macOS Data-form firmlink twins (~2× path count).
pub const max_pack_ro_paths: usize = 48;

/// Collect narrow **read-only** trees so pack-granted Homebrew binaries can load
/// linked dylibs (e.g. ripgrep → pcre2). Never bare `/opt/homebrew`. Caller frees
/// with `freePackExecPaths` (same shape).
pub fn collectPackRoPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    pack_exec_paths: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    if (pack_exec_paths.len == 0) return try allocator.alloc([]const u8, 0);
    if (builtin.os.tag != .macos) return try allocator.alloc([]const u8, 0);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeList(allocator, &list);

    // Dylib parents first (needed to load brew tools), then formula roots.
    for (pack_exec_paths) |exec_path| {
        try appendLinkedLibRoDirs(io, allocator, &list, exec_path);
    }
    for (pack_exec_paths) |exec_path| {
        try appendFormulaRoIfCellar(allocator, &list, exec_path);
    }

    return try list.toOwnedSlice(allocator);
}

/// Filter PATH for sandbox honesty. Returns owned string; caller frees.
/// When `honesty` is denylist: drop known package-manager trees; keep system/shim/workspace/pack parents.
pub fn filterPathForSandbox(
    allocator: std.mem.Allocator,
    path_value: []const u8,
    opts: PathFilterOpts,
) error{OutOfMemory}![]u8 {
    // grant_aligned not implemented — fall through to denylist structure.
    _ = opts.honesty;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const delim = pathDelimiter();
    var first = true;

    // Shim dir always first when present.
    if (opts.shim_dir) |shim| {
        if (shim.len > 0) {
            try out.appendSlice(allocator, shim);
            first = false;
        }
    }

    var parts = std.mem.splitScalar(u8, path_value, delim);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (opts.shim_dir) |shim| {
            if (pathPartEquals(part, shim)) continue; // already first
        }
        if (!shouldKeepPathEntry(part, opts)) continue;
        if (!first) try out.append(allocator, delim);
        try out.appendSlice(allocator, part);
        first = false;
    }

    // Re-add pack tool parents only when they are not under the denylist.
    // Brew Cellar parents stay off PATH (honesty): file .exec may still be granted
    // for absolute use, but advertising a brew tree that dyld/EPERM-fails is a lie.
    for (opts.pack_exec_paths) |exec_path| {
        const parent = std.fs.path.dirname(exec_path) orelse continue;
        if (parent.len == 0) continue;
        if (matchesDenylist(parent)) continue;
        if (pathContainsEntry(out.items, parent, delim)) continue;
        if (!first) try out.append(allocator, delim);
        try out.appendSlice(allocator, parent);
        first = false;
    }

    return try out.toOwnedSlice(allocator);
}

/// Apply PATH filter to env map when attach is active. No-op when `os_attach` is false.
/// Sets `ORCA_PATH_FILTER` / `ORCA_TOOL_PACK` honesty labels for the child session.
pub fn applyPathFilterToEnv(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    os_attach: bool,
    pack: ToolPack,
    opts: PathFilterOpts,
) error{OutOfMemory}!void {
    if (!os_attach) return;
    const old = env_map.get("PATH") orelse "";
    const filtered = try filterPathForSandbox(allocator, old, opts);
    defer allocator.free(filtered);
    try env_map.put("PATH", filtered);
    try env_map.put("ORCA_PATH_FILTER", path_filter_honesty.toString());
    try env_map.put("ORCA_TOOL_PACK", pack.toString());
}

// --- internals ---

const path_tool_names = [_][]const u8{ "rg", "fd", "jq", "git", "zig" };

/// Host package trees that OS attach does not grant as RO/exec directories.
/// Structured list so grant-aligned filter can replace this later.
const denylist_prefixes = [_][]const u8{
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/opt/homebrew",
    "/home/linuxbrew/.linuxbrew/bin",
    "/home/linuxbrew/.linuxbrew/sbin",
    "/home/linuxbrew/.linuxbrew",
    "/usr/local/Homebrew",
    "/linuxbrew",
};

/// Safe system prefixes retained under denylist honesty (system RO already allows these).
const safe_system_prefixes = [_][]const u8{
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/Library/Developer/CommandLineTools/usr/bin",
    "/Library/Developer/CommandLineTools/usr/sbin",
    "/Library/Developer/CommandLineTools/usr/libexec",
    "/System/Library",
    "/usr/libexec",
};

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |p| allocator.free(p);
    list.deinit(allocator);
}

fn listHasBasename(paths: []const []const u8, name: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, std.fs.path.basename(p), name)) return true;
    }
    return false;
}

fn pathListContains(list: *const std.ArrayList([]const u8), path: []const u8) bool {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return true;
    }
    return false;
}

fn appendOwnedPath(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) error{OutOfMemory}!void {
    if (path.len == 0) return;
    if (path.len == 1 and path[0] == '/') return;
    if (pathListContains(list, path)) return;
    if (list.items.len >= max_pack_exec_paths) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn realpathInto(path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return null;
    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(in_buf[0..path.len], path);
    in_buf[path.len] = 0;
    const resolved = std.c.realpath(in_buf[0..path.len :0].ptr, out) orelse return null;
    return std.mem.span(resolved);
}

fn isRegularFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    return st.kind == .file;
}

/// Grant link path + realpath when different (file only).
fn appendFileAndRealpath(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    path: []const u8,
) error{OutOfMemory}!void {
    if (!isRegularFile(io, path)) return;
    try appendOwnedPath(allocator, list, path);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (realpathInto(path, &real_buf)) |real| {
        if (!std.mem.eql(u8, real, path)) {
            if (isRegularFile(io, real)) {
                try appendOwnedPath(allocator, list, real);
            }
        }
    }
}

fn appendProjectZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    workspace_root: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!void {
    _ = env_map;
    if (workspace_root.len == 0) return;
    const script_path = std.fs.path.join(allocator, &.{ workspace_root, "scripts", "zig" }) catch return error.OutOfMemory;
    defer allocator.free(script_path);
    std.Io.Dir.cwd().access(io, script_path, .{}) catch return;
    // Absolute for grant.
    const abs = if (std.fs.path.isAbsolute(script_path))
        try allocator.dupe(u8, script_path)
    else blk: {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch {
            try appendFileAndRealpath(io, allocator, list, script_path);
            return;
        };
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, script_path });
    };
    defer allocator.free(abs);
    try appendFileAndRealpath(io, allocator, list, abs);

    // scripts/zig is often a shell wrapper: also grant nested absolute targets lightly
    // by reading a small head for `exec`/`ZIG` paths — keep simple: shebang interpreter only.
    try appendShebangIfPresent(io, allocator, list, abs);
}

fn appendShebangIfPresent(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    script_path: []const u8,
) error{OutOfMemory}!void {
    const file = std.Io.Dir.cwd().openFile(io, script_path, .{}) catch return;
    defer file.close(io);
    var buf: [256]u8 = undefined;
    const n = std.Io.File.readStreaming(file, io, &.{buf[0..]}) catch return;
    if (n < 3 or buf[0] != '#' or buf[1] != '!') return;
    var line_end: usize = 2;
    while (line_end < n and buf[line_end] != '\n') : (line_end += 1) {}
    var interp = std.mem.trim(u8, buf[2..line_end], " \t\r");
    if (interp.len == 0) return;
    // Drop args after interpreter path.
    if (std.mem.indexOfScalar(u8, interp, ' ')) |sp| interp = interp[0..sp];
    if (interp.len == 0) return;
    if (std.fs.path.isAbsolute(interp)) {
        try appendFileAndRealpath(io, allocator, list, interp);
    }
}

fn appendPathTool(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    name: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!void {
    if (list.items.len >= max_pack_exec_paths) return;
    const resolved = apply_posix.resolveArgv0(io, allocator, name, env_map) catch return;
    defer if (resolved.owned) allocator.free(resolved.path);
    try appendFileAndRealpath(io, allocator, list, resolved.path);
}

/// If path is under `/opt/homebrew/Cellar/<formula>/<ver>/...`, RO that version root.
fn appendFormulaRoIfCellar(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    exec_path: []const u8,
) error{OutOfMemory}!void {
    const cellar = "/opt/homebrew/Cellar/";
    if (!std.mem.startsWith(u8, exec_path, cellar)) return;
    const rest = exec_path[cellar.len..];
    // rest = formula/ver/bin/tool
    const slash1 = std.mem.indexOfScalar(u8, rest, '/') orelse return;
    const after_formula = rest[slash1 + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, after_formula, '/') orelse return;
    const ver_end = cellar.len + slash1 + 1 + slash2;
    const formula_root = exec_path[0..ver_end];
    try appendOwnedRoPath(allocator, list, formula_root);
}

/// Use `otool -L` when present to RO-grant parent dirs of non-system absolute dylibs.
fn appendLinkedLibRoDirs(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    exec_path: []const u8,
) error{OutOfMemory}!void {
    if (list.items.len >= max_pack_ro_paths) return;
    // Only needed for host package trees (system libs already covered by system RO).
    if (!std.mem.startsWith(u8, exec_path, "/opt/homebrew") and
        !std.mem.startsWith(u8, exec_path, "/usr/local/Cellar") and
        !std.mem.startsWith(u8, exec_path, "/usr/local/opt"))
        return;

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "otool", "-L", exec_path },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(1024),
        .timeout = .none,
    }) catch return;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return,
        else => return,
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        // First line is the binary path itself.
        if (first) {
            first = false;
            continue;
        }
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        // Format: `\t/path/to/lib.dylib (compatibility version …)`
        const path_end = std.mem.indexOf(u8, line, " (") orelse line.len;
        const lib_path = std.mem.trim(u8, line[0..path_end], " \t");
        if (!std.fs.path.isAbsolute(lib_path)) continue;
        // System frameworks / libs already in system RO prefixes.
        if (std.mem.startsWith(u8, lib_path, "/usr/lib") or
            std.mem.startsWith(u8, lib_path, "/System/") or
            std.mem.startsWith(u8, lib_path, "/Library/Frameworks"))
            continue;
        // Grant the lib directory (covers versioned sibling dylibs in the same formula).
        const lib_dir = std.fs.path.dirname(lib_path) orelse continue;
        try appendOwnedRoPath(allocator, list, lib_dir);
        // Also grant realpath target dir when opt/ is a symlink into Cellar.
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (realpathInto(lib_path, &real_buf)) |real| {
            if (!std.mem.eql(u8, real, lib_path)) {
                if (std.fs.path.dirname(real)) |real_dir| {
                    try appendOwnedRoPath(allocator, list, real_dir);
                }
            }
        }
    }
}

fn appendOwnedRoPath(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) error{OutOfMemory}!void {
    if (path.len == 0) return;
    if (path.len == 1 and path[0] == '/') return;
    // Never bare brew root.
    if (std.mem.eql(u8, path, "/opt/homebrew") or
        std.mem.eql(u8, path, "/usr/local") or
        std.mem.eql(u8, path, "/home/linuxbrew/.linuxbrew") or
        std.mem.eql(u8, path, "/System/Volumes/Data/opt/homebrew"))
        return;
    try appendOwnedRoPathOnce(allocator, list, path);
    // macOS firmlink residual: Seatbelt last-match denies `/System/Volumes/Data`
    // after grants. Non-Users Data grants need Data-form paths so re-allow fires.
    // Twin /opt/homebrew → /System/Volumes/Data/opt/homebrew (and same for /usr/local).
    if (std.mem.startsWith(u8, path, "/opt/homebrew/") or std.mem.eql(u8, path, "/opt/homebrew")) {
        const data_twin = try std.fmt.allocPrint(allocator, "/System/Volumes/Data{s}", .{path});
        defer allocator.free(data_twin);
        try appendOwnedRoPathOnce(allocator, list, data_twin);
    }
}

fn appendOwnedRoPathOnce(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) error{OutOfMemory}!void {
    if (pathListContains(list, path)) return;
    if (list.items.len >= max_pack_ro_paths) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn shouldKeepPathEntry(part: []const u8, opts: PathFilterOpts) bool {
    // Keep pack parents that are not denylisted (system/workspace installs).
    for (opts.pack_exec_paths) |exec_path| {
        const parent = std.fs.path.dirname(exec_path) orelse continue;
        if (pathPartEquals(part, parent) and !matchesDenylist(parent)) return true;
    }

    // Keep workspace-relative entries.
    if (opts.workspace_root) |ws| {
        if (ws.len > 0 and (pathPartEquals(part, ws) or isUnderPrefix(part, ws))) return true;
    }

    // Drop denylisted package trees (including brew Cellar pack parents).
    if (matchesDenylist(part)) return false;

    // Keep safe system prefixes.
    if (matchesSafeSystem(part)) return true;

    // Residual: keep other dirs (not claimed grant-aligned). Caller docs residual.
    // Host trees outside denylist may still EPERM for individual binaries.
    return true;
}

fn matchesDenylist(part: []const u8) bool {
    for (denylist_prefixes) |prefix| {
        if (isPathPrefixMatch(part, prefix)) return true;
    }
    // Intel Homebrew package trees under /usr/local (not /usr/local/bin itself).
    if (isPathPrefixMatch(part, "/usr/local/Cellar") or
        isPathPrefixMatch(part, "/usr/local/opt") or
        isPathPrefixMatch(part, "/usr/local/Homebrew") or
        isPathPrefixMatch(part, "/usr/local/Caskroom"))
        return true;
    return false;
}

fn matchesSafeSystem(part: []const u8) bool {
    for (safe_system_prefixes) |prefix| {
        if (isPathPrefixMatch(part, prefix)) return true;
    }
    return false;
}

fn isPathPrefixMatch(path: []const u8, prefix: []const u8) bool {
    if (pathPartEquals(path, prefix)) return true;
    return isUnderPrefix(path, prefix);
}

fn isUnderPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (path.len <= prefix.len) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    // prefix must be a path boundary
    if (prefix[prefix.len - 1] == '/') return true;
    return path[prefix.len] == '/';
}

fn pathContainsEntry(path_value: []const u8, entry: []const u8, delim: u8) bool {
    var parts = std.mem.splitScalar(u8, path_value, delim);
    while (parts.next()) |part| {
        if (pathPartEquals(part, entry)) return true;
    }
    return false;
}

fn pathPartEquals(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn pathDelimiter() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

// Silence unused const for future extension of path_tool_names.
comptime {
    _ = path_tool_names;
}

// --- tests ---

test "parseToolPack accepts essentials and none" {
    try std.testing.expectEqual(ToolPack.essentials, parseToolPack("essentials").?);
    try std.testing.expectEqual(ToolPack.essentials, parseToolPack("ESSENTIALS").?);
    try std.testing.expectEqual(ToolPack.none, parseToolPack("none").?);
    try std.testing.expect(parseToolPack(null) == null);
    try std.testing.expect(parseToolPack("") == null);
    try std.testing.expect(parseToolPack("full") == null);
}

test "defaultToolPack essentials when attach else none" {
    try std.testing.expectEqual(ToolPack.essentials, defaultToolPack(true));
    try std.testing.expectEqual(ToolPack.none, defaultToolPack(false));
}

test "resolveToolPack env overrides default" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put(tool_pack_env, "none");
    try std.testing.expectEqual(ToolPack.none, resolveToolPack(&map, true));
    try map.put(tool_pack_env, "essentials");
    try std.testing.expectEqual(ToolPack.essentials, resolveToolPack(&map, false));
}

test "filterPathForSandbox drops homebrew keeps system and shim first" {
    const shim = "/tmp/session/shims";
    const input = "/opt/homebrew/bin:/usr/bin:/bin:/opt/homebrew/sbin:/usr/local/bin";
    const filtered = try filterPathForSandbox(std.testing.allocator, input, .{
        .shim_dir = shim,
        .workspace_root = "/Users/dev/project",
    });
    defer std.testing.allocator.free(filtered);

    try std.testing.expect(std.mem.startsWith(u8, filtered, shim));
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/opt/homebrew/bin") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/opt/homebrew/sbin") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/usr/bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/usr/local/bin") != null);
}

test "filterPathForSandbox does not re-add denylisted brew pack parents" {
    // Honesty: brew parents stay off PATH even when the binary is file-granted.
    const pack = [_][]const u8{"/opt/homebrew/bin/rg"};
    const input = "/opt/homebrew/bin:/usr/bin";
    const filtered = try filterPathForSandbox(std.testing.allocator, input, .{
        .shim_dir = "/shims",
        .pack_exec_paths = &pack,
    });
    defer std.testing.allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/opt/homebrew/bin") == null);
    try std.testing.expect(std.mem.startsWith(u8, filtered, "/shims"));
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/usr/bin") != null);
}

test "filterPathForSandbox re-adds non-denylist pack parents" {
    const pack = [_][]const u8{"/usr/local/bin/rg"};
    const input = "/usr/bin";
    const filtered = try filterPathForSandbox(std.testing.allocator, input, .{
        .pack_exec_paths = &pack,
    });
    defer std.testing.allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/usr/local/bin") != null);
}

test "filterPathForSandbox keeps workspace path entries" {
    const ws = "/Users/dev/myproj";
    const input = "/opt/homebrew/bin:/Users/dev/myproj/scripts:/usr/bin";
    const filtered = try filterPathForSandbox(std.testing.allocator, input, .{
        .workspace_root = ws,
    });
    defer std.testing.allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/Users/dev/myproj/scripts") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/opt/homebrew/bin") == null);
}

test "filterPathForSandbox re-adds pack parent when missing from PATH" {
    const pack = [_][]const u8{"/opt/tools/bin/rg"};
    const input = "/usr/bin:/bin";
    const filtered = try filterPathForSandbox(std.testing.allocator, input, .{
        .pack_exec_paths = &pack,
    });
    defer std.testing.allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/opt/tools/bin") != null);
}

test "collectPackExecPaths none returns empty" {
    const paths = try collectPackExecPaths(
        std.testing.io,
        std.testing.allocator,
        .none,
        "/tmp",
        null,
    );
    defer freePackExecPaths(std.testing.allocator, paths);
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "collectPackExecPaths essentials resolves existing tools or empty" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    // Narrow PATH to system only so test is deterministic when brew is present.
    try map.put("PATH", "/usr/bin:/bin");

    const paths = try collectPackExecPaths(
        std.testing.io,
        std.testing.allocator,
        .essentials,
        "/nonexistent/workspace/for/tool-pack-test",
        &map,
    );
    defer freePackExecPaths(std.testing.allocator, paths);

    try std.testing.expect(paths.len <= max_pack_exec_paths);
    for (paths) |p| {
        try std.testing.expect(std.fs.path.isAbsolute(p));
        // Never bare home or root.
        try std.testing.expect(!std.mem.eql(u8, p, "/"));
        try std.testing.expect(p.len > 1);
    }
}

test "collectPackExecPaths resolves project scripts/zig when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "scripts", .default_dir);
    {
        const f = try tmp.dir.createFile(io, "scripts/zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\necho zig-stub\n");
    }
    // Make executable
    const ws = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws);
    const script = try std.fs.path.join(std.testing.allocator, &.{ ws, "scripts", "zig" });
    defer std.testing.allocator.free(script);
    {
        const z = try std.testing.allocator.dupeZ(u8, script);
        defer std.testing.allocator.free(z);
        _ = std.c.chmod(z.ptr, 0o755);
    }

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");

    const paths = try collectPackExecPaths(io, std.testing.allocator, .essentials, ws, &map);
    defer freePackExecPaths(std.testing.allocator, paths);

    var found = false;
    for (paths) |p| {
        if (std.mem.eql(u8, p, script) or std.mem.endsWith(u8, p, "/scripts/zig")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "collectPackExecPaths caps at max_pack_exec_paths" {
    // Smoke: cap constant is positive and collect never exceeds it (tested above).
    try std.testing.expect(max_pack_exec_paths >= 4);
    try std.testing.expect(max_pack_exec_paths <= 64);
}

test "path filter honesty is denylist for docs" {
    try std.testing.expectEqual(PathFilterHonesty.denylist, path_filter_honesty);
    try std.testing.expectEqualStrings("denylist", path_filter_honesty.toString());
}

test "matchesDenylist covers brew and linuxbrew" {
    try std.testing.expect(matchesDenylist("/opt/homebrew/bin"));
    try std.testing.expect(matchesDenylist("/opt/homebrew/sbin"));
    try std.testing.expect(matchesDenylist("/home/linuxbrew/.linuxbrew/bin"));
    try std.testing.expect(!matchesDenylist("/usr/bin"));
    try std.testing.expect(!matchesDenylist("/bin"));
}

test "appendFormulaRoIfCellar extracts version root" {
    var list: std.ArrayList([]const u8) = .empty;
    defer freeList(std.testing.allocator, &list);
    try appendFormulaRoIfCellar(
        std.testing.allocator,
        &list,
        "/opt/homebrew/Cellar/ripgrep/15.2.0/bin/rg",
    );
    // Path form + Data firmlink twin.
    try std.testing.expect(list.items.len >= 1);
    try std.testing.expectEqualStrings("/opt/homebrew/Cellar/ripgrep/15.2.0", list.items[0]);
    if (list.items.len > 1) {
        try std.testing.expectEqualStrings(
            "/System/Volumes/Data/opt/homebrew/Cellar/ripgrep/15.2.0",
            list.items[1],
        );
    }
}

test "collectPackRoPaths never returns bare homebrew root" {
    const execs = [_][]const u8{"/opt/homebrew/Cellar/ripgrep/15.2.0/bin/rg"};
    const ros = try collectPackRoPaths(std.testing.io, std.testing.allocator, &execs);
    defer freePackExecPaths(std.testing.allocator, ros);
    for (ros) |p| {
        try std.testing.expect(!std.mem.eql(u8, p, "/opt/homebrew"));
        try std.testing.expect(p.len > "/opt/homebrew".len);
    }
}

test "collectPackRoPaths includes pcre2 lib dir for real homebrew rg" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const rg_path = "/opt/homebrew/Cellar/ripgrep/15.2.0/bin/rg";
    std.Io.Dir.cwd().access(std.testing.io, rg_path, .{}) catch return error.SkipZigTest;
    const execs = [_][]const u8{rg_path};
    const ros = try collectPackRoPaths(std.testing.io, std.testing.allocator, &execs);
    defer freePackExecPaths(std.testing.allocator, ros);
    var saw_pcre = false;
    var saw_formula = false;
    for (ros) |p| {
        if (std.mem.indexOf(u8, p, "pcre2") != null) saw_pcre = true;
        if (std.mem.eql(u8, p, "/opt/homebrew/Cellar/ripgrep/15.2.0")) saw_formula = true;
    }
    try std.testing.expect(saw_formula);
    // otool must surface pcre2; if missing, pack RO is incomplete for brew rg.
    try std.testing.expect(saw_pcre);
}
