//! Managed store for discovered inference hostnames (AINA P3 S3).
//!
//! Normative: planning/2026-08-02-aina-p3-discovery-plan.md §3.5;
//! SoT: A-P3-2, A-P3-3, DIS-5/7, SEC-3, EFF-4.
//! Ownership contracts (producer **p3-managed** → launch/start-init):
//!
//! Public seams:
//!
//!   managedPath / writeManaged / loadManaged / mergePreserveUserAllows
//!   refreshManagedDiscovery / managedEntryMatchesHostKey
//!
//!   loadManaged re-validates every host through `extractHostname` (soft-drop
//!   wildcards, class tokens, non-loopback IPs). writeManaged is atomic
//!   (temp+rename), refuses symlink targets, and only emits validated hosts.
//!
//!   mergePreserveUserAllows uses the shared `unionOwnedStringLists` helper.
//!   refreshManagedDiscovery lives here (not in CLI init) so start/init stay
//!   thin callers without CLI layering inversion.
//!
//! Preferred YAML shape (plan §3.5):
//!
//! ```yaml
//! version: 1
//! hosts:
//!   - host: auth.x.ai
//!     sources: [pi:discover]
//! ```
//!
//! Re-export from `src/policy/mod.zig`.

const std = @import("std");
const schema = @import("schema.zig");
const inference_hostname = @import("inference_hostname.zig");
const agent_inference_hosts = @import("agent_inference_hosts.zig");
const inference_discover = @import("inference_discover.zig");

// ---------------------------------------------------------------------------
// Bounds — fail-closed soft skip on oversize / hostile (never panic launch)
// ---------------------------------------------------------------------------

/// Max bytes read from the managed YAML file. Oversize → soft-empty load.
const max_managed_file_bytes: usize = 256 * 1024;

/// Cap host entries accepted on load (plan §3.3 bound).
const max_managed_hosts: usize = 256;

// ---------------------------------------------------------------------------
// Public types + seams (producer **p3-managed**)
// ---------------------------------------------------------------------------

/// One managed discovery contribution: hostname + opaque source tags (paths/fields).
/// On `writeManaged` input, fields are **borrowed**. Inside `ManagedStore` they are
/// **allocator-owned** and freed by `ManagedStore.deinit`.
pub const ManagedHost = struct {
    host: []const u8,
    sources: []const []const u8,
};

/// Loaded managed discovery store. Soft-empty when file missing/corrupt/empty.
pub const ManagedStore = struct {
    version: u16 = 1,
    hosts: []const ManagedHost = &.{},

    pub fn deinit(self: *ManagedStore, allocator: std.mem.Allocator) void {
        for (self.hosts) |entry| {
            freeOwnedHost(allocator, entry);
        }
        if (self.hosts.len > 0) allocator.free(self.hosts);
        self.* = .{};
    }
};

/// Product path: `<workspace_root>/.orca/network-discovered.yaml`.
/// Allocator-owned; caller frees. Independent of process cwd.
pub fn managedPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ workspace_root, ".orca", managed_filename });
}

/// Full-file regenerate of managed discovery YAML under workspace_root.
/// Writes hostnames + source tags only (A-P3-2 / SEC-3). Never tokens/keys/refresh.
/// Creates `.orca/` as needed. Atomic temp+rename; refuses symlink product path.
/// Soft-skips invalid hosts / sources on write (never panics).
pub fn writeManaged(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hosts: []const ManagedHost,
) !void {
    const orca_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".orca" });
    defer allocator.free(orca_dir);
    try std.Io.Dir.cwd().createDirPath(io, orca_dir);

    const path = try managedPath(allocator, workspace_root);
    defer allocator.free(path);

    // Refuse writing through a symlink (integrity: product path must not be a link).
    if (try pathIsSymlink(allocator, path)) return error.ManagedPathIsSymlink;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "version: 1\n");
    try buf.appendSlice(allocator, "hosts:\n");
    for (hosts) |entry| {
        const normalized = (try inference_hostname.extractHostname(allocator, entry.host)) orelse continue;
        defer allocator.free(normalized);

        try buf.appendSlice(allocator, "  - host: ");
        try buf.appendSlice(allocator, normalized);
        try buf.appendSlice(allocator, "\n    sources: [");
        var first_src = true;
        for (entry.sources) |src| {
            if (!isSafeSourceTag(src)) continue;
            if (!first_src) try buf.appendSlice(allocator, ", ");
            first_src = false;
            try buf.appendSlice(allocator, src);
        }
        try buf.appendSlice(allocator, "]\n");
    }

    // Atomic same-directory temp write + rename (mirrors allowlist_store).
    const pid = std.c.getpid();
    const nonce = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}.{d}", .{ path, pid, nonce });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    {
        const file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, buf.items);
        try file.sync(io);
    }
    try std.Io.Dir.renameAbsolute(temp_path, path, io);
}

/// Load managed store from workspace_root. Soft-empty on missing / corrupt /
/// empty / oversize (do not fail launch). Only OOM is a hard error.
pub fn loadManaged(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) !ManagedStore {
    const path = try managedPath(allocator, workspace_root);
    defer allocator.free(path);

    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_managed_file_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Missing, access, too-big, etc. → soft empty (launch skip).
        else => return emptyStore(),
    };
    defer allocator.free(text);

    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return emptyStore();

    return parseManagedYaml(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return emptyStore(),
    };
}

/// `user ∪ managed` with exact-host dedupe. Every pre-existing user allow is
/// preserved (A-P3-3 / EFF-4 / DIS-7). First-wins order: user entries first,
/// then managed hosts not already present. Owned outer + strings; free with
/// `schema.freeStringList`. Empty result is `&.{}` (safe freeStringList).
pub fn mergePreserveUserAllows(
    allocator: std.mem.Allocator,
    user_allows: []const []const u8,
    managed_hosts: []const []const u8,
) ![]const []const u8 {
    return agent_inference_hosts.unionOwnedStringLists(allocator, user_allows, managed_hosts);
}

/// True when a managed entry's source tags are scoped to `host_key`
/// (prefix `host_key:` or exact `host_key`). Empty sources → no match.
pub fn managedEntryMatchesHostKey(entry: ManagedHost, host_key: []const u8) bool {
    if (host_key.len == 0) return false;
    for (entry.sources) |src| {
        if (std.mem.eql(u8, src, host_key)) return true;
        if (src.len > host_key.len and
            std.mem.startsWith(u8, src, host_key) and
            src[host_key.len] == ':')
            return true;
    }
    return false;
}

/// Run adapters for `host_keys` under `home`; regenerate managed store under
/// `workspace_root`. Hostnames + source tags only. Never edits policy.yaml.
/// Soft success when host_keys/home empty or adapters soft-empty (no hard fail).
/// Empty rediscovery leaves any existing managed file untouched.
pub fn refreshManagedDiscovery(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    home: []const u8,
    host_keys: []const []const u8,
) !void {
    if (host_keys.len == 0) return;

    var collected: std.ArrayList(ManagedHost) = .empty;
    errdefer freeRefreshManagedHosts(allocator, &collected);

    for (host_keys) |key| {
        if (key.len == 0) continue;
        const discovered = try inference_discover.discoverForHost(io, allocator, key, home);
        defer schema.freeStringList(allocator, discovered);

        const sources = refreshSourceTag(key);
        for (discovered) |host| {
            if (host.len == 0) continue;
            if (refreshListContainsHost(collected.items, host)) continue;
            const owned = try allocator.dupe(u8, host);
            errdefer allocator.free(owned);
            try collected.append(allocator, .{
                .host = owned,
                .sources = sources,
            });
        }
    }

    if (collected.items.len == 0) {
        freeRefreshManagedHosts(allocator, &collected);
        return;
    }

    try writeManaged(io, allocator, workspace_root, collected.items);
    freeRefreshManagedHosts(allocator, &collected);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

const refresh_source_pi = [_][]const u8{"pi:discover"};
const refresh_source_opencode = [_][]const u8{"opencode:discover"};
const refresh_source_generic = [_][]const u8{"discover"};

fn refreshSourceTag(host_key: []const u8) []const []const u8 {
    if (std.mem.eql(u8, host_key, "pi")) return &refresh_source_pi;
    if (std.mem.eql(u8, host_key, "opencode")) return &refresh_source_opencode;
    return &refresh_source_generic;
}

fn freeRefreshManagedHosts(allocator: std.mem.Allocator, hosts: *std.ArrayList(ManagedHost)) void {
    for (hosts.items) |entry| {
        allocator.free(entry.host);
        // sources are static slices — do not free.
    }
    hosts.deinit(allocator);
}

fn refreshListContainsHost(hosts: []const ManagedHost, needle: []const u8) bool {
    for (hosts) |entry| {
        if (std.mem.eql(u8, entry.host, needle)) return true;
    }
    return false;
}

fn emptyStore() ManagedStore {
    return .{ .version = 1, .hosts = &.{} };
}

fn freeOwnedHost(allocator: std.mem.Allocator, entry: ManagedHost) void {
    allocator.free(entry.host);
    schema.freeStringList(allocator, entry.sources);
}

/// Source tags are opaque path/field markers — reject whitespace / YAML metacharacters.
/// Colon is allowed (`pi:discover`); spaces, brackets, quotes, control chars are not.
fn isSafeSourceTag(src: []const u8) bool {
    if (src.len == 0 or src.len > 256) return false;
    for (src) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
        if (c == '[' or c == ']' or c == '{' or c == '}' or c == ',' or c == '#' or c == '"' or c == '\'')
            return false;
        if (c < 0x20) return false;
    }
    return true;
}

fn pathIsSymlink(allocator: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.c.readlink(path_z.ptr, &buf, buf.len);
    if (n < 0) {
        // EINVAL / not a symlink, ENOENT, etc. → treat as non-symlink.
        return false;
    }
    return true;
}

/// Minimal YAML parse for product shape (version + hosts[{host, sources}]).
/// Fail → error (caller soft-empties). Never panics.
fn parseManagedYaml(allocator: std.mem.Allocator, text: []const u8) !ManagedStore {
    var version: u16 = 1;
    var hosts_list: std.ArrayList(ManagedHost) = .empty;
    errdefer {
        for (hosts_list.items) |entry| freeOwnedHost(allocator, entry);
        hosts_list.deinit(allocator);
    }

    var cur_host: ?[]u8 = null;
    var cur_sources: std.ArrayList([]const u8) = .empty;
    errdefer {
        if (cur_host) |h| allocator.free(h);
        for (cur_sources.items) |s| allocator.free(s);
        cur_sources.deinit(allocator);
    }

    var in_hosts = false;
    var in_sources_block = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Root version (optional).
        if (!in_hosts and std.mem.startsWith(u8, trimmed, "version:")) {
            const rest = std.mem.trim(u8, trimmed["version:".len..], " \t");
            if (rest.len > 0) {
                version = std.fmt.parseInt(u16, rest, 10) catch return error.InvalidManaged;
            }
            continue;
        }

        // Enter hosts section.
        if (std.mem.eql(u8, trimmed, "hosts:") or
            (std.mem.startsWith(u8, trimmed, "hosts:") and
                std.mem.trim(u8, trimmed["hosts:".len..], " \t").len == 0))
        {
            try flushHost(allocator, &hosts_list, &cur_host, &cur_sources);
            in_hosts = true;
            in_sources_block = false;
            continue;
        }

        if (!in_hosts) {
            // Unknown root keys (e.g. hand-corrupted token: lines) ignored.
            continue;
        }

        // New list item: `- host: …` — re-validate via extractHostname (soft-drop).
        if (std.mem.startsWith(u8, trimmed, "- host:")) {
            try flushHost(allocator, &hosts_list, &cur_host, &cur_sources);
            in_sources_block = false;
            if (hosts_list.items.len >= max_managed_hosts) return error.InvalidManaged;
            const val = std.mem.trim(u8, trimmed["- host:".len..], " \t\"'");
            if (val.len == 0) {
                // Soft-drop empty host (keep parsing subsequent entries).
                continue;
            }
            if (try inference_hostname.extractHostname(allocator, val)) |normalized| {
                cur_host = normalized;
            }
            // Invalid / reserved / wildcard → soft-drop (cur_host stays null).
            continue;
        }

        // Bare list dash starting a host entry without inline host:
        // `-` then nested `host:` / `sources:` on following lines.
        if (std.mem.eql(u8, trimmed, "-") or std.mem.eql(u8, trimmed, "- ")) {
            try flushHost(allocator, &hosts_list, &cur_host, &cur_sources);
            in_sources_block = false;
            if (hosts_list.items.len >= max_managed_hosts) return error.InvalidManaged;
            continue;
        }

        // Nested `host:` under a list item.
        // Allocate first, then free old: free-before-null leaves cur_host
        // dangling so OOM on dupe would double-free via function errdefer.
        if (std.mem.startsWith(u8, trimmed, "host:")) {
            const val = std.mem.trim(u8, trimmed["host:".len..], " \t\"'");
            if (val.len == 0) {
                if (cur_host) |old| allocator.free(old);
                cur_host = null;
                in_sources_block = false;
                continue;
            }
            const new_host = (try inference_hostname.extractHostname(allocator, val)) orelse {
                // Soft-drop invalid host; free prior if any.
                if (cur_host) |old| allocator.free(old);
                cur_host = null;
                in_sources_block = false;
                continue;
            };
            if (cur_host) |old| allocator.free(old);
            cur_host = new_host;
            in_sources_block = false;
            continue;
        }

        // `sources: [a, b]` or `sources:` (block).
        if (std.mem.startsWith(u8, trimmed, "sources:")) {
            const rest = std.mem.trim(u8, trimmed["sources:".len..], " \t");
            // Drop any prior sources for this host (last-wins within entry).
            for (cur_sources.items) |s| allocator.free(s);
            cur_sources.clearRetainingCapacity();
            if (rest.len == 0) {
                in_sources_block = true;
                continue;
            }
            in_sources_block = false;
            if (rest[0] == '[') {
                try parseFlowSequenceInto(allocator, rest, &cur_sources);
            } else {
                // Single scalar source.
                const owned = try allocator.dupe(u8, trimScalar(rest));
                errdefer allocator.free(owned);
                try cur_sources.append(allocator, owned);
            }
            continue;
        }

        // Block source items under `sources:`.
        if (in_sources_block and std.mem.startsWith(u8, trimmed, "- ")) {
            const val = trimScalar(trimmed[2..]);
            if (val.len == 0) continue;
            const owned = try allocator.dupe(u8, val);
            errdefer allocator.free(owned);
            try cur_sources.append(allocator, owned);
            continue;
        }

        // Unknown nested key under hosts — ignore (soft tolerance).
        in_sources_block = false;
    }

    try flushHost(allocator, &hosts_list, &cur_host, &cur_sources);
    // flushHost always leaves cur_sources as .empty (capacity freed). Do not
    // deinit here: Zig 0.16 ArrayList.deinit sets self=undefined, so a later
    // OOM on toOwnedSlice would re-enter errdefer and double-free.

    if (hosts_list.items.len == 0) {
        hosts_list.deinit(allocator);
        return .{ .version = version, .hosts = &.{} };
    }
    return .{
        .version = version,
        .hosts = try hosts_list.toOwnedSlice(allocator),
    };
}

fn flushHost(
    allocator: std.mem.Allocator,
    hosts_list: *std.ArrayList(ManagedHost),
    cur_host: *?[]u8,
    cur_sources: *std.ArrayList([]const u8),
) !void {
    const host = cur_host.* orelse {
        // Sources without a host — drop sources and free capacity (no leak).
        for (cur_sources.items) |s| allocator.free(s);
        cur_sources.deinit(allocator);
        cur_sources.* = .empty;
        return;
    };

    var sources: []const []const u8 = &.{};
    if (cur_sources.items.len > 0) {
        sources = try cur_sources.toOwnedSlice(allocator);
        // toOwnedSlice empties the list; reset to a fresh empty for reuse.
        cur_sources.* = .empty;
    } else {
        // No items — free any retained capacity so we do not leak.
        cur_sources.deinit(allocator);
        cur_sources.* = .empty;
    }
    errdefer {
        if (sources.len > 0) {
            for (sources) |s| allocator.free(s);
            allocator.free(sources);
        }
    }

    try hosts_list.append(allocator, .{
        .host = host,
        .sources = sources,
    });
    cur_host.* = null;
}

fn trimScalar(value: []const u8) []const u8 {
    var v = std.mem.trim(u8, value, " \t");
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        v = v[1 .. v.len - 1];
    }
    return v;
}

fn parseFlowSequenceInto(
    allocator: std.mem.Allocator,
    flow: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const trimmed = std.mem.trim(u8, flow, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidManaged;
    }
    const body = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (body.len == 0) return;

    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |part| {
        const item = trimScalar(part);
        if (item.len == 0) continue;
        const owned = try allocator.dupe(u8, item);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }
}

// ---------------------------------------------------------------------------
// Synthetic markers — must never appear in managed file bytes (A-P3-2 / SEC-3)
// ---------------------------------------------------------------------------

/// Token-like fixture needles. Round-trip / write paths must never emit these.
const fixture_secret_needles = [_][]const u8{
    "sk-fixture-managed-token-NOT-REAL-aa11",
    "sk-fixture-managed-refresh-NOT-REAL-bb22",
    "Bearer fixture-managed-oauth-DEADBEEF",
    "xai-api-key-fixture-managed-cc33",
};

const managed_filename = "network-discovered.yaml";
const managed_rel = ".orca/network-discovered.yaml";

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn listContainsExact(list: []const []const u8, needle: []const u8) bool {
    for (list) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

fn countExact(list: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (list) |h| {
        if (std.mem.eql(u8, h, needle)) n += 1;
    }
    return n;
}

fn workspaceAbs(tmp: anytype) ![]u8 {
    // realPathFileAlloc returns [:0]u8 (dupeZ). Re-dupe to plain []u8 so
    // `allocator.free(root)` matches allocation size under DebugAllocator
    // (Zig 0.16 free of coerced []u8 from [:0]u8 frees len, not len+1).
    const z = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(z);
    return try std.testing.allocator.dupe(u8, z);
}

fn readManagedFileBytes(tmp: anytype) ![]u8 {
    return try tmp.dir.readFileAlloc(
        std.testing.io,
        managed_rel,
        std.testing.allocator,
        .limited(256 * 1024),
    );
}

fn assertNoFixtureSecretsInBytes(bytes: []const u8) !void {
    for (fixture_secret_needles) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sk-fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NOT-REAL") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "DEADBEEF") == null);
    // Hosts only — no credential-bearing URL authorities in the file.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "://") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "@") == null);
}

fn storeHostnames(allocator: std.mem.Allocator, store: anytype) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |h| allocator.free(h);
        list.deinit(allocator);
    }
    for (store.hosts) |entry| {
        const owned = try allocator.dupe(u8, entry.host);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    return try list.toOwnedSlice(allocator);
}

fn entrySourcesContain(entry: anytype, needle: []const u8) bool {
    for (entry.sources) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Composition — product path is workspace-root based (not process cwd)
// ---------------------------------------------------------------------------

test "network_discovered managedPath is workspace_root/.orca/network-discovered.yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const path = try managedPath(std.testing.allocator, root);
    defer std.testing.allocator.free(path);

    try std.testing.expect(std.mem.startsWith(u8, path, root));
    try std.testing.expect(std.mem.endsWith(u8, path, managed_rel) or
        std.mem.endsWith(u8, path, "network-discovered.yaml"));
    // Path join under root: .../.orca/network-discovered.yaml
    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, ".orca", managed_filename });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "network_discovered nested-cwd write then workspace-root load hits the same file" {
    // Writer↔loader parity: both APIs key off workspace_root, never process cwd alone.
    // Exercise real process cwd nested under the workspace while still passing abs root.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "nested/deep/cwd");
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const nested_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "nested/deep/cwd", std.testing.allocator);
    defer std.testing.allocator.free(nested_abs);
    const original_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.Io.Threaded.chdir(nested_abs);
    defer std.Io.Threaded.chdir(original_cwd) catch {};

    const entries = [_]ManagedHost{
        .{
            .host = "auth.x.ai",
            .sources = &.{"pi:auth.json:tokenEndpoint"},
        },
        .{
            .host = "api.x.ai",
            .sources = &.{"pi:auth.json:baseUrl"},
        },
    };

    // Process cwd is nested; writeManaged must still land under workspace_root.
    try writeManaged(std.testing.io, std.testing.allocator, root, &entries);

    // File exists at product path relative to workspace root (tmp dir), not under nested cwd.
    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "auth.x.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "api.x.ai") != null);
    try assertNoFixtureSecretsInBytes(bytes);

    // Nested relative path must not hold a decoy product file from a cwd-relative writer.
    if (tmp.dir.access(std.testing.io, "nested/deep/cwd/.orca/network-discovered.yaml", .{})) |_| {
        try std.testing.expect(false);
    } else |_| {}

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);

    const hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, hosts);
    try std.testing.expect(listContainsExact(hosts, "auth.x.ai"));
    try std.testing.expect(listContainsExact(hosts, "api.x.ai"));

    // managedPath absolute must resolve to the same file we wrote under root.
    const path = try managedPath(std.testing.allocator, root);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, root) != null);
    try std.testing.expect(std.mem.indexOf(u8, path, managed_filename) != null);
}

// ---------------------------------------------------------------------------
// A-P3-2 — hostnames + source tags only; no secret material in file bytes
// ---------------------------------------------------------------------------

test "network_discovered A-P3-2 writeManaged round-trip is hostnames and sources only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const entries = [_]ManagedHost{
        .{
            .host = "auth.x.ai",
            .sources = &.{ "pi:auth.json:tokenEndpoint", "pi:auth.json:provider_id" },
        },
        .{
            .host = "openrouter.ai",
            .sources = &.{"pi:auth.json:provider_id"},
        },
        .{
            .host = "opencode.ai",
            .sources = &.{"opencode:auth.json:provider_id"},
        },
    };

    try writeManaged(std.testing.io, std.testing.allocator, root, &entries);

    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);

    // Product shape: version + hosts with host/sources fields.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "hosts") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "auth.x.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "openrouter.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "opencode.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "pi:auth.json:tokenEndpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "opencode:auth.json:provider_id") != null);

    // A-P3-2 / SEC-3: synthetic token-like values never appear in file bytes.
    try assertNoFixtureSecretsInBytes(bytes);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.hosts.len >= 3);
    const hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, hosts);
    try std.testing.expect(listContainsExact(hosts, "auth.x.ai"));
    try std.testing.expect(listContainsExact(hosts, "openrouter.ai"));
    try std.testing.expect(listContainsExact(hosts, "opencode.ai"));

    // Sources round-trip (tags, not secret values).
    var saw_token_endpoint_source = false;
    for (store.hosts) |entry| {
        if (std.mem.eql(u8, entry.host, "auth.x.ai")) {
            if (entrySourcesContain(entry, "pi:auth.json:tokenEndpoint")) {
                saw_token_endpoint_source = true;
            }
        }
        // Host field is a hostname only — no scheme/path/userinfo.
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "://") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "/") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.host, "@") == null);
        for (fixture_secret_needles) |secret| {
            try std.testing.expect(std.mem.indexOf(u8, entry.host, secret) == null);
            for (entry.sources) |src| {
                try std.testing.expect(std.mem.indexOf(u8, src, secret) == null);
            }
        }
    }
    try std.testing.expect(saw_token_endpoint_source);
}

test "network_discovered A-P3-2 synthetic token-like fixture values never appear in file bytes" {
    // Even when the surrounding test context knows secret-like strings, the
    // managed writer is only fed hostnames + source tags — file must not gain secrets.
    // Keep secret needles as test-local locals (adjacent to writer) so a template
    // leak that interpolates ambient fixture constants would still be caught.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    // Secret-shaped strings live as test-local locals adjacent to the write call
    // (not fed into ManagedHost). Writer must not invent them into file bytes.
    const ambient_token = "sk-fixture-managed-token-NOT-REAL-aa11";
    const ambient_refresh = "sk-fixture-managed-refresh-NOT-REAL-bb22";
    const ambient_bearer = "Bearer fixture-managed-oauth-DEADBEEF";
    const ambient_api_key = "xai-api-key-fixture-managed-cc33";

    // Source tags name fields/paths (DIS-3), never credential values.
    const entries = [_]ManagedHost{
        .{
            .host = "api.x.ai",
            .sources = &.{"pi:auth.json:baseUrl"},
        },
        .{
            .host = "models.opencode.ai",
            .sources = &.{"opencode:auth.json:provider_id"},
        },
    };
    try writeManaged(std.testing.io, std.testing.allocator, root, &entries);

    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);

    // Explicit needles via ambient locals (also covered by assert helper).
    try std.testing.expect(std.mem.indexOf(u8, bytes, ambient_token) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ambient_refresh) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ambient_bearer) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ambient_api_key) == null);
    try assertNoFixtureSecretsInBytes(bytes);

    // Loaded store also clean.
    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);
    for (store.hosts) |entry| {
        for (fixture_secret_needles) |secret| {
            try std.testing.expect(std.mem.indexOf(u8, entry.host, secret) == null);
        }
    }
}

test "network_discovered A-P3-2 rewrite regenerates and drops hand-corrupted secret lines" {
    // Hostile adjacent path: pre-seed managed file with a secret-like line; full
    // regenerate must replace the file so secret needles are gone (SEC-3 / DIS-7).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const polluted =
            \\version: 1
            \\hosts:
            \\  - host: evil.example
            \\    sources: [polluted]
            \\token: sk-fixture-managed-token-NOT-REAL-aa11
            \\
        ;
        const f = try tmp.dir.createFile(std.testing.io, managed_rel, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, polluted);
    }
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const clean = [_]ManagedHost{
        .{ .host = "auth.x.ai", .sources = &.{"pi:auth.json:tokenEndpoint"} },
    };
    try writeManaged(std.testing.io, std.testing.allocator, root, &clean);

    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "auth.x.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sk-fixture-managed-token-NOT-REAL-aa11") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "evil.example") == null);
    try assertNoFixtureSecretsInBytes(bytes);
}

// ---------------------------------------------------------------------------
// Soft empty — missing / corrupt never hard-fail (launch soft skip)
// ---------------------------------------------------------------------------

test "network_discovered loadManaged soft-empty when managed file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.hosts.len);
}

test "network_discovered loadManaged soft-empty when managed file is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const f = try tmp.dir.createFile(std.testing.io, managed_rel, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "this is not: valid: [yaml {{{");
    }
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.hosts.len);
}

test "network_discovered loadManaged soft-empty when managed file is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const f = try tmp.dir.createFile(std.testing.io, managed_rel, .{});
        defer f.close(std.testing.io);
        // zero-length file — soft empty, not hard fail
    }
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.hosts.len);
}

// ---------------------------------------------------------------------------
// DIS-7 — re-write regenerates managed hosts (replace contribution)
// ---------------------------------------------------------------------------

test "network_discovered rewrite regenerates managed hosts (full-file replace)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const first = [_]ManagedHost{
        .{ .host = "auth.x.ai", .sources = &.{"pi:auth.json:tokenEndpoint"} },
        .{ .host = "openrouter.ai", .sources = &.{"pi:auth.json:provider_id"} },
    };
    try writeManaged(std.testing.io, std.testing.allocator, root, &first);

    const second = [_]ManagedHost{
        .{ .host = "api.openai.com", .sources = &.{"codex:config:base_url"} },
    };
    try writeManaged(std.testing.io, std.testing.allocator, root, &second);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);

    const hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, hosts);

    try std.testing.expect(listContainsExact(hosts, "api.openai.com"));
    // Full regenerate: previous managed hosts are replaced, not accumulated forever.
    try std.testing.expect(!listContainsExact(hosts, "auth.x.ai"));
    try std.testing.expect(!listContainsExact(hosts, "openrouter.ai"));

    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);
    try assertNoFixtureSecretsInBytes(bytes);
}

// ---------------------------------------------------------------------------
// A-P3-3 / EFF-4 / DIS-7 — merge preserves all pre-existing user allows
// ---------------------------------------------------------------------------

test "network_discovered A-P3-3 mergePreserveUserAllows keeps every pre-existing user allow" {
    const user = [_][]const u8{
        "github.com",
        "my-corp.internal",
        "registry.npmjs.org",
    };
    const managed = [_][]const u8{
        "auth.x.ai",
        "api.x.ai",
        "openrouter.ai",
    };

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    // Every user allow survives (A-P3-3).
    try std.testing.expect(listContainsExact(merged, "github.com"));
    try std.testing.expect(listContainsExact(merged, "my-corp.internal"));
    try std.testing.expect(listContainsExact(merged, "registry.npmjs.org"));

    // Managed hosts are added.
    try std.testing.expect(listContainsExact(merged, "auth.x.ai"));
    try std.testing.expect(listContainsExact(merged, "api.x.ai"));
    try std.testing.expect(listContainsExact(merged, "openrouter.ai"));
}

test "network_discovered A-P3-3 rediscovery managed replace still preserves user allows" {
    // Simulates: user allows stable; managed contribution changes on rediscovery.
    const user = [_][]const u8{
        "github.com",
        "pastebin-allow.example", // user-authored; merge must not drop even if odd
    };

    const managed_first = [_][]const u8{ "auth.x.ai", "openrouter.ai" };
    const merged1 = try mergePreserveUserAllows(std.testing.allocator, &user, &managed_first);
    defer schema.freeStringList(std.testing.allocator, merged1);

    try std.testing.expect(listContainsExact(merged1, "github.com"));
    try std.testing.expect(listContainsExact(merged1, "pastebin-allow.example"));
    try std.testing.expect(listContainsExact(merged1, "auth.x.ai"));

    // Rediscovery yields a different managed set — merge still starts from user allows.
    const managed_second = [_][]const u8{ "api.openai.com", "api.anthropic.com" };
    const merged2 = try mergePreserveUserAllows(std.testing.allocator, &user, &managed_second);
    defer schema.freeStringList(std.testing.allocator, merged2);

    try std.testing.expect(listContainsExact(merged2, "github.com"));
    try std.testing.expect(listContainsExact(merged2, "pastebin-allow.example"));
    try std.testing.expect(listContainsExact(merged2, "api.openai.com"));
    try std.testing.expect(listContainsExact(merged2, "api.anthropic.com"));
    // Prior managed hosts are not part of *this* merge input — not required in output.
    // Critical: user entries never disappear across rediscovery merges.
    try std.testing.expectEqual(@as(usize, 1), countExact(merged2, "github.com"));
    try std.testing.expectEqual(@as(usize, 1), countExact(merged2, "pastebin-allow.example"));
}

test "network_discovered mergePreserveUserAllows dedupes exact hosts already in user allows" {
    const user = [_][]const u8{ "api.x.ai", "github.com" };
    const managed = [_][]const u8{ "api.x.ai", "auth.x.ai" };

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    try std.testing.expectEqual(@as(usize, 1), countExact(merged, "api.x.ai"));
    try std.testing.expect(listContainsExact(merged, "github.com"));
    try std.testing.expect(listContainsExact(merged, "auth.x.ai"));
    try std.testing.expectEqual(@as(usize, 3), merged.len);
}

test "network_discovered mergePreserveUserAllows first-wins order is user then managed" {
    // Module contract: user entries first (stable order), then new managed hosts.
    const user = [_][]const u8{ "github.com", "crates.io" };
    const managed = [_][]const u8{ "auth.x.ai", "api.x.ai" };

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    try std.testing.expect(merged.len >= 4);
    try std.testing.expectEqualStrings("github.com", merged[0]);
    try std.testing.expectEqualStrings("crates.io", merged[1]);
    // Managed contribution follows user block (order among new managed hosts may match input).
    try std.testing.expectEqualStrings("auth.x.ai", merged[2]);
    try std.testing.expectEqualStrings("api.x.ai", merged[3]);
}

test "network_discovered mergePreserveUserAllows with empty managed keeps user allows only" {
    const user = [_][]const u8{ "github.com", "gitlab.com" };
    const managed = [_][]const u8{};

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    try std.testing.expect(listContainsExact(merged, "github.com"));
    try std.testing.expect(listContainsExact(merged, "gitlab.com"));
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}

test "network_discovered mergePreserveUserAllows with empty user yields managed hosts" {
    const user = [_][]const u8{};
    const managed = [_][]const u8{ "auth.x.ai", "api.x.ai" };

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    try std.testing.expect(listContainsExact(merged, "auth.x.ai"));
    try std.testing.expect(listContainsExact(merged, "api.x.ai"));
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}

test "network_discovered mergePreserveUserAllows result is owned independent of inputs" {
    var user_buf = [_]u8{ 'g', 'i', 't', 'h', 'u', 'b', '.', 'c', 'o', 'm' };
    var managed_buf = [_]u8{ 'a', 'p', 'i', '.', 'x', '.', 'a', 'i' };
    const user = [_][]const u8{user_buf[0..]};
    const managed = [_][]const u8{managed_buf[0..]};

    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, &managed);
    defer schema.freeStringList(std.testing.allocator, merged);

    // Mutate inputs after merge — owned result must be unchanged.
    @memset(user_buf[0..], 'X');
    @memset(managed_buf[0..], 'Y');

    try std.testing.expect(listContainsExact(merged, "github.com"));
    try std.testing.expect(listContainsExact(merged, "api.x.ai"));
}

// ---------------------------------------------------------------------------
// End-to-end store → host list → merge (composition helper path)
// ---------------------------------------------------------------------------

test "network_discovered load then mergePreserveUserAllows preserves user and adds managed hosts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    const entries = [_]ManagedHost{
        .{ .host = "auth.x.ai", .sources = &.{"pi:auth.json:tokenEndpoint"} },
        .{ .host = "api.x.ai", .sources = &.{"pi:auth.json:baseUrl"} },
    };
    try writeManaged(std.testing.io, std.testing.allocator, root, &entries);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);

    const managed_hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, managed_hosts);

    const user = [_][]const u8{ "github.com", "crates.io" };
    const merged = try mergePreserveUserAllows(std.testing.allocator, &user, managed_hosts);
    defer schema.freeStringList(std.testing.allocator, merged);

    try std.testing.expect(listContainsExact(merged, "github.com"));
    try std.testing.expect(listContainsExact(merged, "crates.io"));
    try std.testing.expect(listContainsExact(merged, "auth.x.ai"));
    try std.testing.expect(listContainsExact(merged, "api.x.ai"));

    const bytes = try readManagedFileBytes(&tmp);
    defer std.testing.allocator.free(bytes);
    try assertNoFixtureSecretsInBytes(bytes);
}

// ---------------------------------------------------------------------------
// Load-side revalidation — poisoned / class-token / wildcard soft-drop
// ---------------------------------------------------------------------------

test "network_discovered loadManaged soft-drops reserved class tokens and wildcards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    {
        const polluted =
            \\version: 1
            \\hosts:
            \\  - host: private
            \\    sources: [poison]
            \\  - host: metadata
            \\    sources: [poison]
            \\  - host: cloud-metadata
            \\    sources: [poison]
            \\  - host: direct-ip
            \\    sources: [poison]
            \\  - host: "*"
            \\    sources: [poison]
            \\  - host: "*.amazonaws.com"
            \\    sources: [poison]
            \\  - host: auth.x.ai
            \\    sources: [pi:discover]
            \\
        ;
        const f = try tmp.dir.createFile(std.testing.io, managed_rel, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, polluted);
    }
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    var store = try loadManaged(std.testing.io, std.testing.allocator, root);
    defer store.deinit(std.testing.allocator);

    const hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, hosts);

    try std.testing.expect(listContainsExact(hosts, "auth.x.ai"));
    try std.testing.expect(!listContainsExact(hosts, "private"));
    try std.testing.expect(!listContainsExact(hosts, "metadata"));
    try std.testing.expect(!listContainsExact(hosts, "cloud-metadata"));
    try std.testing.expect(!listContainsExact(hosts, "direct-ip"));
    try std.testing.expect(!listContainsExact(hosts, "*"));
    try std.testing.expect(!listContainsExact(hosts, "*.amazonaws.com"));
}

test "network_discovered writeManaged refuses symlink product path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceAbs(&tmp);
    defer std.testing.allocator.free(root);

    try tmp.dir.createDirPath(std.testing.io, ".orca");
    // Target outside .orca; product path is a symlink to it.
    {
        const target = try tmp.dir.createFile(std.testing.io, "outside-target.txt", .{});
        defer target.close(std.testing.io);
        try target.writeStreamingAll(std.testing.io, "pre-existing\n");
    }
    // Create symlink at managed path → outside-target.txt (relative).
    // Create symlink at managed path → outside-target.txt (relative under tmp root).
    tmp.dir.symLink(std.testing.io, "outside-target.txt", managed_rel, .{}) catch |err| switch (err) {
        // Some CI environments block symlink creation — soft-skip test.
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    const entries = [_]ManagedHost{
        .{ .host = "auth.x.ai", .sources = &.{"pi:discover"} },
    };
    try std.testing.expectError(
        error.ManagedPathIsSymlink,
        writeManaged(std.testing.io, std.testing.allocator, root, &entries),
    );

    // Target must be untouched.
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "outside-target.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "pre-existing") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "auth.x.ai") == null);
}

test "network_discovered managedEntryMatchesHostKey scopes by source prefix" {
    const pi_entry = ManagedHost{ .host = "auth.x.ai", .sources = &.{"pi:discover"} };
    const oc_entry = ManagedHost{ .host = "opencode.ai", .sources = &.{"opencode:discover"} };
    const bare = ManagedHost{ .host = "x.invalid", .sources = &.{} };
    try std.testing.expect(managedEntryMatchesHostKey(pi_entry, "pi"));
    try std.testing.expect(!managedEntryMatchesHostKey(pi_entry, "opencode"));
    try std.testing.expect(managedEntryMatchesHostKey(oc_entry, "opencode"));
    try std.testing.expect(!managedEntryMatchesHostKey(oc_entry, "pi"));
    try std.testing.expect(!managedEntryMatchesHostKey(bare, "pi"));
}

test "network_discovered refreshManagedDiscovery writes hostnames for pi/opencode" {
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const workspace_root = try workspaceAbs(&ws_tmp);
    defer std.testing.allocator.free(workspace_root);

    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    // Minimal pi auth with xai-oauth URLs (catalog hosts).
    try home_tmp.dir.createDirPath(std.testing.io, ".pi/agent");
    {
        const f = try home_tmp.dir.createFile(std.testing.io, ".pi/agent/auth.json", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"xai-oauth":{"type":"oauth","tokenEndpoint":"https://auth.x.ai/oauth2/token","baseUrl":"https://api.x.ai/v1","access":"fixture-refresh-NOT-REAL","refresh":"fixture-refresh2-NOT-REAL"}}
        );
    }
    const home = try workspaceAbs(&home_tmp);
    defer std.testing.allocator.free(home);

    try refreshManagedDiscovery(
        std.testing.io,
        std.testing.allocator,
        workspace_root,
        home,
        &.{"pi"},
    );

    var store = try loadManaged(std.testing.io, std.testing.allocator, workspace_root);
    defer store.deinit(std.testing.allocator);
    const hosts = try storeHostnames(std.testing.allocator, store);
    defer schema.freeStringList(std.testing.allocator, hosts);
    try std.testing.expect(listContainsExact(hosts, "auth.x.ai"));
    try std.testing.expect(listContainsExact(hosts, "api.x.ai"));
}
