//! Single ApplyBeforeExec boundary for production agent launch.
//!
//! Production path:
//!   cli/run → applyBeforeExec → supervisor.run → process.prepareChild
//!     → sandboxed spawn (apply_posix) or std.process.spawn
//!
//! Scaffold `backend.prepare` was removed. Production attach is exclusively
//! applyBeforeExec + apply_posix child apply; capability detect stays in backend.
//!
//! This module:
//! - compiles a pure FS profile (`profile.compileProfile`)
//! - scrubs loader/startup injection env (`env_scrub`)
//! - attempts platform OS prepare: Landlock on Linux; Seatbelt on macOS
//! - retains child-apply materials (`ChildMaterials` union) so spawn can box the *agent* process
//!
//! Landlock restrict_self and Seatbelt sandbox_init run only in a **forked child**
//! so the parent Orca process stays free. Production agent exec must use
//! `apply_posix.forkApplyLandlockAndExec` / `forkApplySeatbeltAndExec` (FD scrub
//! runs in that child before exec).
//!
//! Session `active` only via `receipt.isActive()` after real OS apply for the agent child.
//! NEVER claims network Landlock/Seatbelt.

const std = @import("std");
const builtin = @import("builtin");
const posture = @import("posture.zig");
const profile = @import("profile.zig");
const env_scrub = @import("env_scrub.zig");
const landlock = @import("landlock.zig");
const macos_seatbelt = @import("macos_seatbelt.zig");
const macos_profile = @import("macos_profile.zig");
const apply_posix = @import("apply_posix.zig");
const session_tmp = @import("session_tmp.zig");

/// Re-export session-tmp surface for callers that only import apply.
pub const workspace_session_tmp_name = session_tmp.workspace_session_tmp_name;
pub const classic_tmp_fallback = session_tmp.classic_tmp_fallback;
pub const workspaceSessionTmpPath = session_tmp.workspaceSessionTmpPath;
pub const ensureWorkspaceSessionTmp = session_tmp.ensureWorkspaceSessionTmp;

/// Re-export mode for callers that only touch apply.
pub const OsSandboxMode = posture.OsSandboxMode;
pub const AttachReceipt = posture.AttachReceipt;

/// Error when mode is `on` (required) and OS apply cannot attach.
pub const ApplyError = error{
    /// `--os-sandbox on` but backend unavailable / apply failed / profile invalid.
    RequireFailed,
    OutOfMemory,
};

/// Named public error set for `ApplyResult.spawnAgent`.
/// Prefer this over an inferred set that surfaces bare `Unexpected`.
/// Invariant failures (no child materials, missing SBPL/profile, proof mint fail)
/// map to `ApplyFailed` so CLI spawn classifiers stay honest.
pub const SpawnAgentError = apply_posix.SpawnError;

/// What the agent spawn path must do after `applyBeforeExec`.
/// Tag matches `ChildMaterials` so kind is derived from materials.
pub const ChildApplyKind = enum {
    none,
    landlock,
    seatbelt,
};

/// Owned child-apply materials for agent spawn.
/// Invalid both-set states are unrepresentable: at most one backend payload.
pub const ChildMaterials = union(enum) {
    none,
    landlock: struct {
        compiled: profile.CompiledProfile,
        route_forcing: ?landlock.RouteForcing = null,
        /// Original compile input (not recoverable from grants when workspace is /tmp).
        include_tmp: bool = false,
    },
    seatbelt: struct {
        sbpl_z: [:0]u8,
        allocator: std.mem.Allocator,
        /// Precomputed at prepare from `CompiledProfile.effectiveFsScopeSummary(.seatbelt)`.
        /// Static string (not heap-owned). Used on activate so receipts cannot drift
        /// from a second hardcoded source of truth.
        fs_scope: []const u8,
        /// Residual grade used when rendering SBPL (receipts/network_scope honesty).
        profile_grade: macos_profile.SeatbeltProfileGrade = macos_profile.SeatbeltProfileGrade.default_grade,
    },

    pub fn deinit(self: *ChildMaterials) void {
        switch (self.*) {
            .none => {},
            .landlock => |*p| p.compiled.deinit(),
            .seatbelt => |*s| s.allocator.free(s.sbpl_z),
        }
        self.* = .none;
    }

    pub fn kind(self: ChildMaterials) ChildApplyKind {
        return switch (self) {
            .none => .none,
            .landlock => .landlock,
            .seatbelt => .seatbelt,
        };
    }
};

/// Inputs for the single apply-before-exec seam.
pub const ApplyBoundary = struct {
    allocator: std.mem.Allocator,
    mode: OsSandboxMode,
    /// Absolute workspace root (fail closed if relative when mode is on/auto).
    workspace_root: []const u8,
    /// Child env map mutated in place when scrub runs (on/auto).
    env_map: ?*std.process.Environ.Map = null,
    /// Extra profile options.
    include_tmp: bool = false,
    control_roots: []const []const u8 = &.{},
    /// Absolute launch-binary paths for `.exec` profile grants (see `collectLaunchExecPaths`).
    /// Agents installed outside workspace/system prefixes (e.g. `~/.local/...`) need these
    /// so child preflight after Seatbelt/Landlock can still read+exec argv0.
    launch_exec_paths: []const []const u8 = &.{},
    /// Empty-backpack sessions require OS enforcement for workspace `.env`
    /// and `.env.*` names (safe templates remain readable).
    protect_workspace_secrets: bool = false,
    /// Optional per-launch proxy TCP port. When set, supported platforms install
    /// child network rules that force outbound TCP through the loopback proxy.
    network_proxy_port: ?u16 = null,
    require_network_route_forcing: bool = false,
    /// macOS Seatbelt residual grade (ignored on non-macOS). Default hardened.
    seatbelt_profile: macos_profile.SeatbeltProfileGrade = macos_profile.SeatbeltProfileGrade.default_grade,
    /// When `error.RequireFailed` is returned, set to a static reason code if non-null.
    fail_reason_out: ?*[]const u8 = null,
};

pub const ApplyResult = struct {
    receipt: AttachReceipt,
    /// True when denylist env scrub ran against env_map.
    env_scrubbed: bool = false,
    /// True when launch allowlist ran (only with child-apply materials).
    env_launch_allowlisted: bool = false,
    /// Count of keys removed by denylist + optional launch allowlist (0 if none).
    env_keys_removed: usize = 0,
    /// Profile was compiled.
    profile_compiled: bool = false,
    /// By-value 64-hex digest of the compiled profile when compile succeeded (not heap-owned).
    profile_hash_hex: ?[64]u8 = null,
    /// Owned child-apply materials. Free with deinit. Default `.none`.
    materials: ChildMaterials = .none,
    /// True only when child-apply materials include OS network rules for the
    /// current proxy listener. This is per-launch, not a static doctor claim.
    network_route_forced: bool = false,
    /// Retained fork buffers for the last successful sandboxed spawn.
    /// Freed in `deinit` after the supervisor has waited/reaped the child.
    spawn_lease: ?apply_posix.SpawnLease = null,

    pub fn deinit(self: *ApplyResult) void {
        if (self.spawn_lease) |*lease| {
            // Production path waits/reaps via PreparedChild before deinit.
            // Multi-spawn and error paths must killAndReap before free; deinit
            // does not kill (pid may already be reaped — SIGKILL would race reuse).
            lease.deinit();
            self.spawn_lease = null;
        }
        self.materials.deinit();
        self.* = undefined;
    }

    /// Kind of child-side OS apply the spawn path must perform (derived from materials tag).
    pub fn childApplyKind(self: ApplyResult) ChildApplyKind {
        return self.materials.kind();
    }

    /// True when spawn must use apply_posix (agent would otherwise be unboxed).
    pub fn requiresChildApply(self: ApplyResult) bool {
        return self.childApplyKind() != .none;
    }

    /// Proof that agent-child OS FS apply handshake succeeded.
    /// Only `activateAfterHandshake` (via `spawnAgent`) constructs this after a real
    /// fork status-pipe success. No cross-module mint — magic seal dropped (same-module).
    pub const ChildAttachProof = struct {
        mechanism: posture.BackendMechanism,

        pub fn isValid(self: ChildAttachProof) bool {
            return self.mechanism != .none;
        }
    };

    /// Result of a successful sandboxed agent spawn (pid + attach proof).
    pub const SpawnedAgent = struct {
        pid: i32,
        proof: ChildAttachProof,
    };

    /// Build active receipt from materials after proven child handshake.
    /// File-private: only `spawnAgent` calls this. Bare materials alone never
    /// authorize active (S-GLO-01). Hard-fails on missing materials/hash or
    /// activeReceipt construction failure — never soft-skips.
    ///
    /// Network scope is mechanism-specific when route-forced (M-1 honesty):
    /// Landlock is TCP port-scoped only (any remote IP; UDP unrestricted);
    /// Seatbelt is loopback-proxy TCP only (localhost:port SBPL).
    fn activateAfterHandshake(self: *ApplyResult) error{ApplyFailed}!ChildAttachProof {
        const hash = self.profile_hash_hex orelse return error.ApplyFailed;
        const mechanism: posture.BackendMechanism = switch (self.materials) {
            .none => return error.ApplyFailed,
            .landlock => .landlock,
            .seatbelt => .seatbelt,
        };
        // Resolve network_scope once per mechanism (M-15: no duplicated receipt arms).
        const network_scope: []const u8 = switch (self.materials) {
            .none => unreachable,
            .landlock => if (self.network_route_forced)
                "proxy route-forced (TCP connect port-scoped to proxy port; not address-scoped; UDP unrestricted)"
            else
                "unrestricted",
            .seatbelt => |*s| macos_profile.networkScopeSummary(s.profile_grade, self.network_route_forced),
        };
        const fs_scope: []const u8 = switch (self.materials) {
            .none => unreachable,
            .landlock => |*p| p.compiled.effectiveFsScopeSummary(.landlock),
            .seatbelt => |*s| s.fs_scope, // precomputed at prepare (single source)
        };
        const seatbelt_profile: ?macos_profile.SeatbeltProfileGrade = switch (self.materials) {
            .seatbelt => |*s| s.profile_grade,
            else => null,
        };
        self.receipt = posture.activeReceiptWithNetworkAndGrade(
            mechanism,
            hash[0..],
            fs_scope,
            network_scope,
            seatbelt_profile,
        ) catch return error.ApplyFailed;
        return .{ .mechanism = mechanism };
    }

    /// Spawn the agent with OS FS apply in the child (Landlock / Seatbelt).
    /// Parent stays unrestricted. Blocks until status-pipe proves apply.
    /// On success, mutates this result to active via `activateAfterHandshake`.
    /// After a successful child handshake, activate failure kills/reaps the child
    /// and returns `ApplyFailed` — never a live agent without an active receipt.
    /// Errors: `SpawnAgentError` (named; invariants → `ApplyFailed`, never bare `Unexpected`).
    pub fn spawnAgent(
        self: *ApplyResult,
        io: std.Io,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env_map: ?*const std.process.Environ.Map,
        workspace_root: []const u8,
        stdio: apply_posix.StdioBehavior,
    ) SpawnAgentError!SpawnedAgent {
        // Match apply_posix empty-argv contract (ExecFailed, not FileNotFound).
        if (argv.len == 0) return error.ExecFailed;
        const resolved = try apply_posix.resolveArgv0(io, allocator, argv[0], env_map);
        defer if (resolved.owned) allocator.free(resolved.path);

        var argv_owned = try allocator.alloc([]const u8, argv.len);
        defer allocator.free(argv_owned);
        argv_owned[0] = resolved.path;
        @memcpy(argv_owned[1..], argv[1..]);

        // Drop any prior lease: kill+reap first. Freeing retained argv/env while
        // the prior child still runs is free-before-reap (fork COW UAF). One-shot
        // run never hits this; multi-spawn / retry paths must not free live buffers.
        if (self.spawn_lease) |*old| {
            if (old.pid > 0) apply_posix.killAndReapChild(old.pid);
            old.deinit();
            self.spawn_lease = null;
        }

        // Single switch on materials tag — invalid dual-backend state unrepresentable.
        var lease = switch (self.materials) {
            .none => return error.ApplyFailed,
            .landlock => |*ll| try apply_posix.forkApplyLandlockAndExec(
                io,
                &ll.compiled,
                ll.route_forcing,
                ll.include_tmp,
                argv_owned,
                env_map,
                workspace_root,
                stdio,
            ),
            .seatbelt => |*sb| try apply_posix.forkApplySeatbeltAndExec(
                sb.sbpl_z.ptr,
                argv_owned,
                env_map,
                workspace_root,
                stdio,
            ),
        };

        // Handshake proven: activate receipt from materials. Hard-fail after fork —
        // kill/reap so we never return a live agent without an active session receipt.
        const proof = self.activateAfterHandshake() catch {
            apply_posix.killAndReapChild(lease.pid);
            lease.deinit();
            return error.ApplyFailed;
        };
        const pid = lease.pid;
        self.spawn_lease = lease;
        return .{ .pid = pid, .proof = proof };
    }
};

/// Platform prepare outcome from Landlock/Seatbelt (parent seam only).
/// Parent seam never returns a live-session attach: only prepared_child materials
/// (or unavailable/failed). Session `active` requires child status-pipe + activate.
const PlatformApplyStatus = enum {
    /// Backend not present / not implemented for this build.
    unavailable,
    /// Backend present but prepare failed.
    failed,
    /// Profile prepared; agent child must apply before exec. Not active yet.
    prepared_child,
};

const PlatformApplyOutcome = struct {
    status: PlatformApplyStatus,
    mechanism: posture.BackendMechanism = .none,
    reason_code: []const u8,
    network_route_forced: bool = false,
    landlock_route_forcing: ?landlock.RouteForcing = null,
    /// Owned NUL-terminated SBPL when Seatbelt prepare succeeded. Free via `deinit`
    /// unless transferred with `takeSeatbeltSbpl`.
    seatbelt_sbpl_z: ?[:0]u8 = null,
    /// Allocator that owns `seatbelt_sbpl_z` when non-null.
    sbpl_allocator: ?std.mem.Allocator = null,
    /// Seatbelt residual grade for receipt honesty (macOS only).
    seatbelt_profile_grade: macos_profile.SeatbeltProfileGrade = macos_profile.SeatbeltProfileGrade.default_grade,

    pub fn deinit(self: *PlatformApplyOutcome) void {
        if (self.seatbelt_sbpl_z) |p| {
            if (self.sbpl_allocator) |a| a.free(p);
            self.seatbelt_sbpl_z = null;
            self.sbpl_allocator = null;
        }
    }

    /// Transfer SBPL ownership to the caller; `deinit` will not free it.
    pub fn takeSeatbeltSbpl(self: *PlatformApplyOutcome) ?[:0]u8 {
        const p = self.seatbelt_sbpl_z;
        self.seatbelt_sbpl_z = null;
        self.sbpl_allocator = null;
        return p;
    }
};

fn setFailReason(boundary: ApplyBoundary, reason: []const u8) void {
    if (boundary.fail_reason_out) |out| out.* = reason;
}

/// Pure: true when `path` is a macOS per-user `/var/folders/...` temp (not granted).
/// File-private — only used by attach rewrite tests in this module.
fn isUngrantedHostTmpdir(path: []const u8) bool {
    if (path.len == 0) return false;
    // macOS default TMPDIR shape: /var/folders/… or /private/var/folders/…
    if (std.mem.startsWith(u8, path, "/var/folders/")) return true;
    if (std.mem.startsWith(u8, path, "/private/var/folders/")) return true;
    return false;
}

/// Rewrite TMPDIR/TMP/TEMP into the workspace session temp for the attach path.
///
/// Host macOS TMPDIR under `/var/folders` is intentionally not granted (canary breadth).
/// Prefer `{workspace}/.orca-tmp` (workspace RW; mkdir so Landlock expand sees it).
///
/// Production defaults keep `include_tmp=false` (no classic `/tmp` RW grant). Do **not**
/// silently rewrite to classic `/tmp` when session temp cannot be prepared — that path
/// is agent-unwritable under the sandbox and misleads operators. Fail closed instead
/// (`error.SessionTmpPrepareFailed`); callers map to `session_tmp_prepare_failed`.
///
/// Mutates `env_map` in place only on success. Returns the path written into TMPDIR
/// (map-owned value).
pub fn rewriteTempEnvForAttach(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    workspace_root: []const u8,
) error{ OutOfMemory, SessionTmpPrepareFailed }![]const u8 {
    const preferred = try workspaceSessionTmpPath(allocator, workspace_root);
    defer allocator.free(preferred);

    // Create session surface first (shared with Landlock expand precreate).
    // Fail closed: production materials require session tmp under workspace RW.
    if (!ensureWorkspaceSessionTmp(workspace_root)) return error.SessionTmpPrepareFailed;

    // Map put duplicates via map allocator — preferred stack path is free'd after.
    try env_map.put("TMPDIR", preferred);
    try env_map.put("TMP", preferred);
    try env_map.put("TEMP", preferred);
    return env_map.get("TMPDIR") orelse error.SessionTmpPrepareFailed;
}

/// Resolve argv0 into narrow absolute **file** paths for `.exec` profile grants.
///
/// Returns an owned slice of owned path strings (caller frees each path, then the slice).
/// Empty slice when argv0 cannot be resolved or is not a regular file — never invents grants.
///
/// Always includes the lexical absolute path used for exec and, when different, the
/// realpath target (symlink → install tree). When the launch file is a shebang script,
/// also grants the shebang interpreter (absolute path, or PATH-resolved name from
/// `#!/usr/bin/env NAME` / minimal `env -S`) through the same file-only filters.
/// Rejects filesystem root and `$HOME` itself so Seatbelt `subpath` cannot open the
/// whole home tree. Does not recurse into nested scripts.
pub fn collectLaunchExecPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv0: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}![]const []const u8 {
    if (argv0.len == 0) return try allocator.alloc([]const u8, 0);

    const resolved = apply_posix.resolveArgv0(io, allocator, argv0, env_map) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer if (resolved.owned) allocator.free(resolved.path);

    const abs = try absolutePathForGrant(io, allocator, resolved.path);
    defer allocator.free(abs);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    try appendLaunchExecCandidate(io, allocator, &list, abs, env_map);

    // Symlink target when different (e.g. ~/.local/bin/claude → versions/N).
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (realpathInto(abs, &real_buf)) |real| {
        if (!std.mem.eql(u8, real, abs)) {
            try appendLaunchExecCandidate(io, allocator, &list, real, env_map);
        }
    }

    // Shebang interpreter of the launch file only (not nested scripts).
    try appendShebangInterpreterGrants(io, allocator, &list, abs, env_map);

    return try list.toOwnedSlice(allocator);
}

/// Free the slice returned by `collectLaunchExecPaths`.
pub fn freeLaunchExecPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Make `path` absolute (lexical). Relative paths join cwd.
fn absolutePathForGrant(io: std.Io, allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path) catch return error.OutOfMemory;
    }
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch {
        // Fall back to lexical join with "."; compile still requires absolute later.
        return std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return error.OutOfMemory;
    };
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path }) catch return error.OutOfMemory;
}

fn realpathInto(path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return null;
    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(in_buf[0..path.len], path);
    in_buf[path.len] = 0;
    const resolved = std.c.realpath(in_buf[0..path.len :0].ptr, out) orelse return null;
    return std.mem.span(resolved);
}

fn appendLaunchExecCandidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    path: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!void {
    if (path.len == 0) return;
    if (path.len == 1 and path[0] == '/') return;
    // Never grant bare $HOME (Seatbelt subpath would open the whole tree).
    if (envHome(env_map)) |home| {
        if (std.mem.eql(u8, path, home)) return;
    }
    // Regular files only — directory exec grants would subpath-open entire trees.
    if (!isRegularFile(io, path)) return;

    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

/// Max bytes scanned at the start of a launch file for a shebang line.
const shebang_scan_max: usize = 512;

/// If `script_path` begins with `#!`, resolve the interpreter and append file-only
/// `.exec` candidates (lexical + realpath). Unreadable / non-script / unparseable → no-op.
fn appendShebangInterpreterGrants(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    script_path: []const u8,
    env_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!void {
    const interp_token = (try readShebangInterpreterToken(io, allocator, script_path)) orelse return;
    defer allocator.free(interp_token);

    const resolved = apply_posix.resolveArgv0(io, allocator, interp_token, env_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer if (resolved.owned) allocator.free(resolved.path);

    const abs = try absolutePathForGrant(io, allocator, resolved.path);
    defer allocator.free(abs);

    try appendLaunchExecCandidate(io, allocator, list, abs, env_map);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (realpathInto(abs, &real_buf)) |real| {
        if (!std.mem.eql(u8, real, abs)) {
            try appendLaunchExecCandidate(io, allocator, list, real, env_map);
        }
    }
}

/// Read the first line of `path` when it is a shebang; return an owned interpreter
/// path or bare name for PATH resolution. `null` when no usable shebang.
fn readShebangInterpreterToken(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) error{OutOfMemory}!?[]u8 {
    if (path.len == 0 or !isRegularFile(io, path)) return null;

    var buf: [shebang_scan_max]u8 = undefined;
    const n: usize = blk: {
        if (std.fs.path.isAbsolute(path)) {
            const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
            defer file.close(io);
            break :blk std.Io.File.readStreaming(file, io, &.{buf[0..]}) catch return null;
        }
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);
        break :blk std.Io.File.readStreaming(file, io, &.{buf[0..]}) catch return null;
    };
    if (n < 2 or buf[0] != '#' or buf[1] != '!') return null;

    const body = buf[2..n];
    const line_end = std.mem.indexOfAny(u8, body, "\r\n") orelse body.len;
    const line = std.mem.trim(u8, body[0..line_end], " \t");
    if (line.len == 0) return null;

    const token = parseShebangInterpreterToken(line) orelse return null;
    return try allocator.dupe(u8, token);
}

/// Parse the body after `#!` into an interpreter path or bare name.
/// Supports absolute paths and `env` with flags/assignments (`-S`, `-u NAME`, `VAR=val`).
fn parseShebangInterpreterToken(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    var pos: usize = 0;
    const first = nextShebangToken(line, &pos) orelse return null;
    const base = std.fs.path.basename(first);
    if (!std.mem.eql(u8, base, "env")) return first;

    // #!/usr/bin/env [options|assignments…] NAME …
    while (nextShebangToken(line, &pos)) |tok| {
        if (tok[0] != '-') {
            if (isEnvAssignmentToken(tok)) continue;
            return tok;
        }

        // Long options: --unset=NAME / --unset NAME / --split-string=S / …
        if (std.mem.startsWith(u8, tok, "--")) {
            if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                if (std.mem.eql(u8, tok[0..eq], "--split-string")) {
                    return firstShebangWord(tok[eq + 1 ..]);
                }
                continue;
            }
            if (!envLongOptionTakesArg(tok)) continue;
            const arg = nextShebangToken(line, &pos) orelse return null;
            if (std.mem.eql(u8, tok, "--split-string")) return firstShebangWord(arg);
            continue;
        }

        // Short options: -i / -v / -0 / -u NAME / -uNAME / -S / -Snode / -P PATH …
        if (tok.len < 2) continue;
        const opt = tok[1];
        if (!envShortOptionTakesArg(opt)) continue;

        if (tok.len > 2) {
            // Attached argument: -uFOO, -Snode --flag, -P/opt/bin
            if (opt == 'S') return firstShebangWord(tok[2..]);
            continue;
        }

        // Separate argument for -u/-C/-P/-S.
        // Bare `-S` with no payload (`env -S -P /opt/bin node`) does not consume the next
        // token as an -S string — subsequent flags must still be scanned.
        if (opt == 'S') continue;

        _ = nextShebangToken(line, &pos) orelse return null;
    }
    return null;
}

fn nextShebangToken(line: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < line.len and (line[pos.*] == ' ' or line[pos.*] == '\t')) pos.* += 1;
    if (pos.* >= line.len) return null;
    const start = pos.*;
    while (pos.* < line.len and line[pos.*] != ' ' and line[pos.*] != '\t') pos.* += 1;
    if (pos.* == start) return null;
    return line[start..pos.*];
}

fn firstShebangWord(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len) return null;
    const start = i;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
    const word = s[start..i];
    if (word.len == 0 or word[0] == '-') return null;
    if (isEnvAssignmentToken(word)) return null;
    return word;
}

fn envShortOptionTakesArg(opt: u8) bool {
    return switch (opt) {
        'u', 'C', 'P', 'S' => true,
        else => false,
    };
}

fn envLongOptionTakesArg(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "--unset") or
        std.mem.eql(u8, tok, "--chdir") or
        std.mem.eql(u8, tok, "--path") or
        std.mem.eql(u8, tok, "--split-string");
}

fn isEnvAssignmentToken(tok: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    if (eq == 0) return false;
    // Paths can contain '=' rarely; treat slash before '=' as a path, not an assignment.
    if (std.mem.indexOfScalar(u8, tok[0..eq], '/') != null) return false;
    return true;
}

fn envHome(env_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (env_map) |map| {
        if (map.get("HOME")) |h| return h;
    }
    if (std.c.getenv("HOME")) |h| return std.mem.span(h);
    return null;
}

fn isRegularFile(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
        defer file.close(io);
        const st = file.stat(io) catch return false;
        return st.kind == .file;
    }
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    return st.kind == .file;
}

/// Apply OS sandbox policy for the production launch path.
///
/// - `off` → disabled receipt; no profile/platform apply; no env scrub at this seam
/// - `on` / `auto` → compile profile, denylist-scrub env, attempt platform apply
/// - `on` / `auto` + incomplete denylist scrub (OOM) → `error.RequireFailed` (fail closed; reason env_scrub_failed)
/// - allowlist / TMPDIR rewrite OOM → `error.OutOfMemory` (hard; not RequireFailed)
/// - launch allowlist runs only when prepare yields child-apply materials
/// - attach path rewrites TMPDIR/TMP/TEMP into workspace session temp (`.orca-tmp`)
/// - session-tmp prepare failure under materials → `session_tmp_prepare_failed`
///   (`on` → RequireFailed; `auto` → failed receipt; never silent classic `/tmp`)
/// - `on` + unavailable/failed (no child plan) → `error.RequireFailed` (fail closed)
/// - `on` + prepared child plan → returns materials; receipt stays non-active until promote
/// - `auto` + unavailable → unavailable receipt; denylist only (provider keys retained)
/// - Session `active` only after agent-child apply handshake + `activateAfterHandshake` (S-GLO-01)
pub fn applyBeforeExec(boundary: ApplyBoundary) ApplyError!ApplyResult {
    switch (boundary.mode) {
        .off => return .{
            .receipt = posture.disabledReceipt(),
            .env_scrubbed = false,
            .env_launch_allowlisted = false,
            .env_keys_removed = 0,
            .profile_compiled = false,
        },
        .on, .auto => {},
    }

    // Compile pure profile (grants model only — no syscalls).
    // OOM is never a soft grade-drop: propagate so callers fail closed hard.
    // InvalidWorkspace / InvalidExecPath / other compile failures → profile_compile_failed
    // (on→RequireFailed, auto→unavailable).
    var compiled = profile.compileProfile(boundary.allocator, .{
        .workspace_root = boundary.workspace_root,
        .control_roots = boundary.control_roots,
        .include_tmp = boundary.include_tmp,
        .exec_paths = boundary.launch_exec_paths,
        .protect_workspace_secrets = boundary.protect_workspace_secrets,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setFailReason(boundary, "profile_compile_failed");
            if (boundary.mode == .on) return error.RequireFailed;
            return .{
                .receipt = posture.unavailableReceipt("profile_compile_failed"),
                .env_scrubbed = false,
                .env_launch_allowlisted = false,
                .profile_compiled = false,
            };
        },
    };
    var transfer_landlock = false;
    defer if (!transfer_landlock) compiled.deinit();

    // F-1: reject symlink/non-dir control roots before platform prepare (path alias).
    var control_io_rt: std.Io.Threaded = .init_single_threaded;
    const control_io = control_io_rt.io();
    compiled.validateControlRootsOnDisk(control_io) catch {
        setFailReason(boundary, "control_root_unsafe");
        if (boundary.mode == .on) return error.RequireFailed;
        return .{
            .receipt = posture.unavailableReceipt("control_root_unsafe"),
            .env_scrubbed = false,
            .env_launch_allowlisted = false,
            .profile_compiled = true,
            .profile_hash_hex = blk: {
                var h: [64]u8 = undefined;
                @memcpy(h[0..], compiled.hash());
                break :blk h;
            },
        };
    };

    var hash_copy: [64]u8 = undefined;
    @memcpy(hash_copy[0..], compiled.hash());

    // Denylist scrub always on on/auto (injection fail-closed). Launch allowlist is
    // deferred until after prepare so pure grade-drop does not strip provider keys.
    var removed: usize = 0;
    var scrubbed = false;
    if (boundary.env_map) |env_map| {
        removed = env_scrub.scrubEnvMapInPlace(env_map) catch {
            setFailReason(boundary, "env_scrub_failed");
            return error.RequireFailed;
        };
        scrubbed = true;
    }

    // Platform OS prepare — Linux Landlock ABI probe; macOS Seatbelt prepare.
    // FD scrub / real attach run only in the forked agent child (`apply_posix`), never here.
    // OOM on Seatbelt prepare propagates as `error.OutOfMemory` (never soft .failed).
    var platform = try tryPlatformApply(
        boundary.allocator,
        &compiled,
        boundary.network_proxy_port,
        boundary.seatbelt_profile,
    );
    defer platform.deinit();

    if (boundary.require_network_route_forcing and !platform.network_route_forced) {
        setFailReason(boundary, "network_route_forcing_unavailable");
        return error.RequireFailed;
    }

    // Launch allowlist only when child-apply materials will be used (prepared_child).
    // Unavailable/failed grade-drop keeps denylist-only env (provider credentials retained).
    // Attach path rewrites TMPDIR into workspace session temp (R2-2) — host /var/folders
    // is not granted, and classic `/tmp` is not RW under production defaults.
    var allowlisted = false;
    if (platform.status == .prepared_child) {
        // Create `{workspace}/.orca-tmp` before Landlock expand enumerates children,
        // even when env_map is null (rewriteTempEnvForAttach also ensures when env present).
        // Fail closed when materials require session tmp (M-8): never lie with classic /tmp.
        if (!ensureWorkspaceSessionTmp(boundary.workspace_root)) {
            setFailReason(boundary, "session_tmp_prepare_failed");
            if (boundary.mode == .on) return error.RequireFailed;
            return .{
                .receipt = posture.failedReceipt("session_tmp_prepare_failed"),
                .env_scrubbed = scrubbed,
                .env_launch_allowlisted = false,
                .env_keys_removed = removed,
                .profile_compiled = true,
                .profile_hash_hex = hash_copy,
            };
        }
        if (boundary.env_map) |env_map| {
            // Allowlist/TMPDIR OOM must stay OutOfMemory (not lossy RequireFailed).
            const allow_removed = env_scrub.applyLaunchAllowlistInPlace(env_map) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            removed += allow_removed;
            allowlisted = true;
            // After allowlist keeps TMPDIR key, point it at workspace session temp.
            _ = rewriteTempEnvForAttach(boundary.allocator, env_map, boundary.workspace_root) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SessionTmpPrepareFailed => {
                    setFailReason(boundary, "session_tmp_prepare_failed");
                    if (boundary.mode == .on) return error.RequireFailed;
                    return .{
                        .receipt = posture.failedReceipt("session_tmp_prepare_failed"),
                        .env_scrubbed = scrubbed,
                        .env_launch_allowlisted = allowlisted,
                        .env_keys_removed = removed,
                        .profile_compiled = true,
                        .profile_hash_hex = hash_copy,
                    };
                },
            };
        }
    }

    switch (platform.status) {
        .prepared_child => {
            // Parent prepare only — not active until proven agent-child apply (status pipe).
            // Posture is `prepared`, not grade-drop `unavailable`.
            // Linux: transfer landlock profile. macOS: keep SBPL. Spawn path applies then activates.
            if (platform.mechanism == .landlock) {
                transfer_landlock = true;
                return .{
                    .receipt = posture.preparedReceipt(.landlock, platform.reason_code),
                    .env_scrubbed = scrubbed,
                    .env_launch_allowlisted = allowlisted,
                    .env_keys_removed = removed,
                    .profile_compiled = true,
                    .profile_hash_hex = hash_copy,
                    .materials = .{ .landlock = .{
                        .compiled = compiled,
                        .route_forcing = platform.landlock_route_forcing,
                        .include_tmp = boundary.include_tmp,
                    } },
                    .network_route_forced = platform.network_route_forced,
                };
            }
            const sbpl_z = platform.takeSeatbeltSbpl() orelse {
                // prepared_child + seatbelt without SBPL is a contract bug — fail closed.
                setFailReason(boundary, "seatbelt_sbpl_missing");
                if (boundary.mode == .on) return error.RequireFailed;
                return .{
                    .receipt = posture.failedReceipt("seatbelt_sbpl_missing"),
                    .env_scrubbed = scrubbed,
                    .env_launch_allowlisted = allowlisted,
                    .env_keys_removed = removed,
                    .profile_compiled = true,
                    .profile_hash_hex = hash_copy,
                };
            };
            // Precompute scope while `compiled` is still alive (static summary string).
            const seatbelt_scope = compiled.effectiveFsScopeSummary(.seatbelt);
            return .{
                .receipt = posture.preparedReceipt(.seatbelt, platform.reason_code),
                .env_scrubbed = scrubbed,
                .env_launch_allowlisted = allowlisted,
                .env_keys_removed = removed,
                .profile_compiled = true,
                .profile_hash_hex = hash_copy,
                .materials = .{ .seatbelt = .{
                    .sbpl_z = sbpl_z,
                    .allocator = boundary.allocator,
                    .fs_scope = seatbelt_scope,
                    .profile_grade = platform.seatbelt_profile_grade,
                } },
                .network_route_forced = platform.network_route_forced,
            };
        },
        .unavailable => {
            setFailReason(boundary, platform.reason_code);
            if (boundary.mode == .on) return error.RequireFailed;
            return .{
                .receipt = posture.unavailableReceipt(platform.reason_code),
                .env_scrubbed = scrubbed,
                .env_launch_allowlisted = false,
                .env_keys_removed = removed,
                .profile_compiled = true,
                .profile_hash_hex = hash_copy,
            };
        },
        .failed => {
            setFailReason(boundary, platform.reason_code);
            if (boundary.mode == .on) return error.RequireFailed;
            return .{
                .receipt = posture.failedReceipt(platform.reason_code),
                .env_scrubbed = scrubbed,
                .env_launch_allowlisted = false,
                .env_keys_removed = removed,
                .profile_compiled = true,
                .profile_hash_hex = hash_copy,
            };
        },
    }
}

/// Platform prepare: Linux → Landlock ABI probe + prepared child plan; macOS → Seatbelt prepare.
/// Neither path returns session-active from the parent seam alone.
/// Mode on/auto fail-closed is enforced by the caller (`applyBeforeExec`), not here.
/// Seatbelt OOM surfaces as `error.OutOfMemory` (never soft `.failed`).
fn tryPlatformApply(
    allocator: std.mem.Allocator,
    compiled: *const profile.CompiledProfile,
    network_proxy_port: ?u16,
    seatbelt_profile: macos_profile.SeatbeltProfileGrade,
) ApplyError!PlatformApplyOutcome {
    return switch (builtin.os.tag) {
        .linux => tryPlatformApplyLinux(network_proxy_port),
        .macos => try tryMacOsSeatbelt(allocator, compiled, network_proxy_port, seatbelt_profile),
        else => .{
            .status = .unavailable,
            .mechanism = .none,
            .reason_code = "backend_not_implemented",
        },
    };
}

fn tryMacOsSeatbelt(
    allocator: std.mem.Allocator,
    compiled: *const profile.CompiledProfile,
    network_proxy_port: ?u16,
    seatbelt_profile: macos_profile.SeatbeltProfileGrade,
) ApplyError!PlatformApplyOutcome {
    const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
        allocator,
        compiled,
        macos_seatbelt.evaluateSupport(),
        .{
            .network_route_forcing = if (network_proxy_port) |port| .{ .proxy_port = port } else null,
            .profile_grade = seatbelt_profile,
        },
    );
    return switch (prepared.status) {
        .unavailable => .{
            .status = .unavailable,
            .mechanism = .none,
            .reason_code = prepared.reason_code,
            .seatbelt_sbpl_z = null,
            .sbpl_allocator = null,
            .seatbelt_profile_grade = seatbelt_profile,
        },
        // Single OOM/soft-fail path (M-9): never twin the reason-code match inline.
        .failed => try mapSeatbeltPrepareFailure(prepared.reason_code),
        .prepared => .{
            .status = .prepared_child,
            .mechanism = .seatbelt,
            .reason_code = "seatbelt_child_apply_required",
            .seatbelt_sbpl_z = prepared.sbpl_z,
            .sbpl_allocator = allocator,
            .network_route_forced = network_proxy_port != null,
            .seatbelt_profile_grade = seatbelt_profile,
        },
    };
}

/// Map Seatbelt prepare fail reason codes: OOM → hard `OutOfMemory`, else soft failed.
/// Exposed for unit tests of the OOM fail-closed contract (M-15).
fn mapSeatbeltPrepareFailure(reason_code: []const u8) ApplyError!PlatformApplyOutcome {
    if (std.mem.eql(u8, reason_code, "seatbelt_profile_oom")) return error.OutOfMemory;
    return .{
        .status = .failed,
        .mechanism = .none,
        .reason_code = reason_code,
        .seatbelt_sbpl_z = null,
        .sbpl_allocator = null,
    };
}

/// Linux prepare: ABI probe only. Do not double-apply via verifyApplyInChild
/// on the production hot path — real Landlock attach is the agent child in apply_posix.
/// `landlock.verifyApplyInChild` remains available for unit tests in landlock.zig.
fn tryPlatformApplyLinux(network_proxy_port: ?u16) PlatformApplyOutcome {
    if (!landlock.isAbiAvailable()) {
        return .{
            .status = .unavailable,
            .mechanism = .none,
            .reason_code = "landlock_unavailable",
        };
    }

    const route_forcing: ?landlock.RouteForcing = if (network_proxy_port) |port|
        if (landlock.supportsTcpRouteForcing()) .{ .proxy_port = port } else null
    else
        null;

    return .{
        .status = .prepared_child,
        .mechanism = .landlock,
        .reason_code = "landlock_child_apply_required",
        .network_route_forced = route_forcing != null,
        .landlock_route_forcing = route_forcing,
    };
}

test "mode off returns disabled receipt without scrub or active claim" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("LD_PRELOAD", "evil.so");
    try env_map.put("PATH", "/bin");

    const result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .off,
        .workspace_root = "/tmp/ws",
        .env_map = &env_map,
    });

    try std.testing.expectEqual(posture.SessionPosture.disabled, result.receipt.posture);
    try std.testing.expect(!result.receipt.isActive());
    try std.testing.expect(!result.env_scrubbed);
    try std.testing.expect(!result.profile_compiled);
    // Off path does not scrub at this seam (policy env filter still applies upstream).
    try std.testing.expect(env_map.get("LD_PRELOAD") != null);
    try std.testing.expectEqualStrings("os_sandbox_off", result.receipt.reason_code.?);
    try std.testing.expectEqual(ChildApplyKind.none, result.childApplyKind());
}

test "mode auto without Landlock returns unavailable and scrubs env" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("LD_PRELOAD", "evil.so");
    try env_map.put("PATH", "/usr/bin");
    try env_map.put("ORCA_SESSION_ID", "s1");

    // Parent prepare is ABI/backend probe only — missing path is not a parent failure.
    // Denylist scrub must still run; session stays non-active until agent-child apply + promote.
    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = "/tmp/orca-apply-ws-nonexistent-u05",
        .env_map = &env_map,
    });
    defer result.deinit();

    try std.testing.expect(result.receipt.posture != .active);
    try std.testing.expect(!result.receipt.isActive());
    try std.testing.expect(result.env_scrubbed);
    try std.testing.expect(result.profile_compiled);
    try std.testing.expect(result.profile_hash_hex != null);
    try std.testing.expect(env_map.get("LD_PRELOAD") == null);
    try std.testing.expectEqualStrings("/usr/bin", env_map.get("PATH").?);
    try std.testing.expectEqualStrings("s1", env_map.get("ORCA_SESSION_ID").?);
    // Non-Linux: backend_not_implemented / macos_version_unsupported / prepared;
    // Linux without ABI: landlock_unavailable;
    // Linux with ABI: prepared (landlock_child_apply_required) — attach is spawn path.
    try std.testing.expect(result.receipt.posture == .unavailable or result.receipt.posture == .failed or result.receipt.posture == .prepared);
    // Allowlist only with child-apply materials.
    try std.testing.expectEqual(result.requiresChildApply(), result.env_launch_allowlisted);
}

test "auto grade-drop retains provider keys; attach path allowlists" {
    // Inherit-like env: provider credentials + injection key.
    // Denylist always strips injection. Launch allowlist only when materials require child apply.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    try env_map.put("HOME", "/tmp");
    try env_map.put("OPENAI_API_KEY", "sk-retain-on-grade-drop");
    try env_map.put("AWS_SECRET_ACCESS_KEY", "aws-secret-retain");
    try env_map.put("LD_PRELOAD", "evil.so");
    try env_map.put("SSL_CERT_FILE", "/etc/ssl/cert.pem");
    try env_map.put("SSH_AUTH_SOCK", "/tmp/ssh-agent.sock");

    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = "/tmp/orca-apply-ws-m2-allowlist",
        .env_map = &env_map,
    });
    defer result.deinit();

    // Injection denylist always runs on auto.
    try std.testing.expect(result.env_scrubbed);
    try std.testing.expect(env_map.get("LD_PRELOAD") == null);
    try std.testing.expectEqualStrings("/usr/bin:/bin", env_map.get("PATH").?);

    if (result.requiresChildApply()) {
        // Attach path: launch allowlist strips secrets and SSH_AUTH_SOCK; TLS trust kept.
        try std.testing.expect(result.env_launch_allowlisted);
        try std.testing.expect(env_map.get("OPENAI_API_KEY") == null);
        try std.testing.expect(env_map.get("AWS_SECRET_ACCESS_KEY") == null);
        try std.testing.expectEqualStrings("/etc/ssl/cert.pem", env_map.get("SSL_CERT_FILE").?);
        try std.testing.expect(env_map.get("SSH_AUTH_SOCK") == null);
    } else {
        // Pure grade-drop unavailable/failed: provider keys retained (no allowlist).
        try std.testing.expect(!result.env_launch_allowlisted);
        try std.testing.expectEqualStrings("sk-retain-on-grade-drop", env_map.get("OPENAI_API_KEY").?);
        try std.testing.expectEqualStrings("aws-secret-retain", env_map.get("AWS_SECRET_ACCESS_KEY").?);
        try std.testing.expectEqualStrings("/etc/ssl/cert.pem", env_map.get("SSL_CERT_FILE").?);
        try std.testing.expectEqualStrings("/tmp/ssh-agent.sock", env_map.get("SSH_AUTH_SOCK").?);
        try std.testing.expect(result.receipt.posture == .unavailable or result.receipt.posture == .failed);
    }
}

test "mode on without usable Landlock fails closed with RequireFailed" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/bin");

    var fail_reason: []const u8 = "unset";
    var result = applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = "/tmp/orca-apply-ws-nonexistent-u05",
        .env_map = &env_map,
        .fail_reason_out = &fail_reason,
    });
    // Linux without Landlock ABI → RequireFailed; with ABI → prepared_child (path open is spawn).
    // macOS matrix Seatbelt prepare succeeds (child apply still required; not active yet).
    if (result) |*ok| {
        defer ok.deinit();
        if (builtin.os.tag == .macos) {
            try std.testing.expect(ok.requiresChildApply());
            try std.testing.expectEqual(ChildApplyKind.seatbelt, ok.childApplyKind());
            try std.testing.expect(!ok.receipt.isActive());
        } else {
            // Parent seam never active: prepared child plan only if ABI available.
            try std.testing.expect(ok.requiresChildApply());
            try std.testing.expect(!ok.receipt.isActive());
        }
    } else |e| {
        try std.testing.expectEqual(error.RequireFailed, e);
        try std.testing.expect(!std.mem.eql(u8, fail_reason, "unset"));
        try std.testing.expect(!std.mem.eql(u8, fail_reason, "backend_not_implemented") or builtin.os.tag != .macos);
    }
}

test "mode on + invalid workspace fails closed" {
    var fail_reason: []const u8 = "unset";
    const err = applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = "relative-not-allowed",
        .env_map = null,
        .fail_reason_out = &fail_reason,
    });
    try std.testing.expectError(error.RequireFailed, err);
    try std.testing.expectEqualStrings("profile_compile_failed", fail_reason);
}

test "mode on and auto fail closed when env scrub is incomplete" {
    // Absolute workspace so profile compile succeeds; inject OOM on env scrub only.
    const modes = [_]OsSandboxMode{ .on, .auto };
    for (modes) |mode| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
        const alloc = failing.allocator();

        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();
        try env_map.put("PATH", "/bin");
        try env_map.put("LD_PRELOAD", "evil.so");
        try env_map.put("LD_AUDIT", "evil_audit.so");

        // Allow profile compile allocations; trip on the first scrub key dupe.
        // Profile compile uses boundary.allocator (testing allocator), env map uses failing.
        // Scrub uses env_map.allocator → failing. Force fail before scrub starts collecting.
        failing.fail_index = failing.alloc_index;

        var fail_reason: []const u8 = "unset";
        const err = applyBeforeExec(.{
            .allocator = std.testing.allocator,
            .mode = mode,
            .workspace_root = "/tmp/orca-apply-ws-scrub-fail",
            .env_map = &env_map,
            .fail_reason_out = &fail_reason,
        });
        try std.testing.expectError(error.RequireFailed, err);
        try std.testing.expectEqualStrings("env_scrub_failed", fail_reason);
        try std.testing.expect(failing.has_induced_failure);
    }
}

test "mode auto + invalid workspace degrades to unavailable" {
    const result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = "",
        .env_map = null,
    });
    try std.testing.expectEqual(posture.SessionPosture.unavailable, result.receipt.posture);
    try std.testing.expect(!result.receipt.isActive());
    try std.testing.expectEqualStrings("profile_compile_failed", result.receipt.reason_code.?);
}

test "profile compile OutOfMemory propagates (never soft unavailable)" {
    // OOM on compile is hard failure for both on and auto — not grade-drop.
    const modes = [_]OsSandboxMode{ .on, .auto };
    for (modes) |mode| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const err = applyBeforeExec(.{
            .allocator = failing.allocator(),
            .mode = mode,
            .workspace_root = "/tmp/orca-apply-ws-compile-oom",
            .env_map = null,
        });
        try std.testing.expectError(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
    }
}

test "seatbelt prepare OOM maps to OutOfMemory not soft failed" {
    // seatbelt_profile_oom must hard-fail like profile compile OOM (M-15).
    try std.testing.expectError(error.OutOfMemory, mapSeatbeltPrepareFailure("seatbelt_profile_oom"));
    var soft = try mapSeatbeltPrepareFailure("seatbelt_profile_render_failed");
    defer soft.deinit();
    try std.testing.expectEqual(PlatformApplyStatus.failed, soft.status);
    try std.testing.expectEqualStrings("seatbelt_profile_render_failed", soft.reason_code);
}

test "PlatformApplyOutcome deinit frees owned SBPL" {
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n(deny default)\n");
    var outcome: PlatformApplyOutcome = .{
        .status = .prepared_child,
        .mechanism = .seatbelt,
        .reason_code = "seatbelt_child_apply_required",
        .seatbelt_sbpl_z = sbpl,
        .sbpl_allocator = std.testing.allocator,
    };
    // take transfers ownership — deinit must not double-free.
    const taken = outcome.takeSeatbeltSbpl();
    try std.testing.expect(taken != null);
    outcome.deinit();
    std.testing.allocator.free(taken.?);

    const sbpl2 = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    var outcome2: PlatformApplyOutcome = .{
        .status = .prepared_child,
        .mechanism = .seatbelt,
        .reason_code = "seatbelt_child_apply_required",
        .seatbelt_sbpl_z = sbpl2,
        .sbpl_allocator = std.testing.allocator,
    };
    outcome2.deinit(); // frees sbpl2
    try std.testing.expect(outcome2.seatbelt_sbpl_z == null);
}

test "non-Linux never yields active receipt from apply seam without child spawn" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const modes = [_]OsSandboxMode{ .off, .auto };
    for (modes) |mode| {
        var result = try applyBeforeExec(.{
            .allocator = std.testing.allocator,
            .mode = mode,
            .workspace_root = "/tmp/orca-apply-ws",
            .env_map = null,
        });
        defer result.deinit();
        try std.testing.expect(result.receipt.posture != .active);
        try std.testing.expect(!result.receipt.isActive());
        try std.testing.expect(!result.receipt.posture.isOsEnforced());
    }
}

test "parent apply seam never claims active (probe/prepare only)" {
    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = "/workspace",
        .env_map = null,
    });
    defer result.deinit();
    // S-GLO-01: applyBeforeExec must not authorize session active from probe alone.
    try std.testing.expect(!result.receipt.isActive());

    if (result.requiresChildApply()) {
        try std.testing.expect(result.childApplyKind() == .landlock or result.childApplyKind() == .seatbelt);
    }
}

test "Linux Landlock prepares child plan without claiming active" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!landlock.isAbiAvailable()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = root,
        .env_map = null,
        .include_tmp = false,
    });
    defer result.deinit();

    // ABI available → prepared plan without parent-side Landlock apply; not session active.
    try std.testing.expect(!result.receipt.isActive());
    try std.testing.expectEqual(posture.SessionPosture.prepared, result.receipt.posture);
    try std.testing.expectEqual(ChildApplyKind.landlock, result.childApplyKind());
    try std.testing.expectEqual(std.meta.Tag(ChildMaterials).landlock, std.meta.activeTag(result.materials));
    try std.testing.expect(result.profile_hash_hex != null);
    try std.testing.expectEqualStrings("landlock_child_apply_required", result.receipt.reason_code.?);

    // S-GLO-01: bare materials never authorize active until activateAfterHandshake.
    try std.testing.expect(!result.receipt.isActive());
    // Same-module activate after (simulated) handshake builds active receipt.
    const proof = try result.activateAfterHandshake();
    try std.testing.expect(proof.isValid());
    try std.testing.expectEqual(posture.BackendMechanism.landlock, proof.mechanism);
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqual(posture.BackendMechanism.landlock, result.receipt.mechanism);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "workspace child RW") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "root RO") != null);
    // Default include_tmp=false → no classic platform tmp RW claim.
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "platform tmp RW") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "no home") != null);
    const hash_view = result.receipt.profileHashSlice().?;
    try std.testing.expectEqual(@as(usize, 64), hash_view.len);
    try std.testing.expectEqualStrings(result.profile_hash_hex.?[0..], hash_view);

    // mode on also prepares (not active) when Landlock works.
    var on_result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = null,
    });
    defer on_result.deinit();
    try std.testing.expect(!on_result.receipt.isActive());
    try std.testing.expectEqual(ChildApplyKind.landlock, on_result.childApplyKind());
}

test "never claims network in active landlock fs_scope" {
    const hash64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const complete = try posture.activeReceipt(.landlock, hash64, "workspace child RW, root RO, system RO, platform tmp RW, no home");
    try std.testing.expect(std.mem.indexOf(u8, complete.fs_scope, "network") == null);
    try std.testing.expect(std.mem.indexOf(u8, complete.fs_scope, "root RO") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete.fs_scope, "platform tmp RW") != null);
}

test "activateAfterHandshake activates from materials; materials alone stay inactive" {
    const hash: [64]u8 = .{'a'} ** 64;
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    // Precomputed scope with classic tmp (opt-in) — activate must use this verbatim.
    const scope_with_tmp = "workspace RW, system RO, platform tmp RW, no home, control write-deny (readable), mach-lookup residual";
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .materials = .{ .seatbelt = .{
            .sbpl_z = sbpl,
            .allocator = std.testing.allocator,
            .fs_scope = scope_with_tmp,
        } },
    };
    defer result.deinit();

    try std.testing.expectEqual(ChildApplyKind.seatbelt, result.childApplyKind());
    // S-GLO-01: materials alone never yield isActive.
    try std.testing.expect(!result.receipt.isActive());
    const proof = try result.activateAfterHandshake();
    try std.testing.expect(proof.isValid());
    try std.testing.expectEqual(posture.BackendMechanism.seatbelt, proof.mechanism);
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqual(posture.BackendMechanism.seatbelt, result.receipt.mechanism);
    try std.testing.expectEqualStrings(scope_with_tmp, result.receipt.fs_scope);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "network") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "platform tmp RW") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "no home") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "mach-lookup residual") != null);
}

test "seatbelt activate uses precomputed fs_scope without platform tmp by default" {
    const hash: [64]u8 = .{'c'} ** 64;
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    // Production default (include_tmp=false) summary from profile.effectiveFsScopeSummary(.seatbelt).
    const no_tmp_scope = "workspace RW, system RO, no home, control write-deny (readable), mach-lookup residual";
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .materials = .{ .seatbelt = .{
            .sbpl_z = sbpl,
            .allocator = std.testing.allocator,
            .fs_scope = no_tmp_scope,
        } },
    };
    defer result.deinit();

    _ = try result.activateAfterHandshake();
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqualStrings(no_tmp_scope, result.receipt.fs_scope);
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.fs_scope, "platform tmp") == null);
}

test "activateAfterHandshake hard-fails on missing profile hash" {
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = null,
        .materials = .{ .seatbelt = .{
            .sbpl_z = sbpl,
            .allocator = std.testing.allocator,
            .fs_scope = "workspace RW, system RO, no home, control write-deny (readable), mach-lookup residual",
        } },
    };
    defer result.deinit();

    try std.testing.expectError(error.ApplyFailed, result.activateAfterHandshake());
    try std.testing.expect(!result.receipt.isActive());
}

test "activateAfterHandshake sets seatbelt loopback route-forced network_scope" {
    const hash: [64]u8 = .{'e'} ** 64;
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    const fs_scope = "workspace RW, system RO, no home, control write-deny (readable), mach-lookup residual";
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .network_route_forced = true,
        .materials = .{ .seatbelt = .{
            .sbpl_z = sbpl,
            .allocator = std.testing.allocator,
            .fs_scope = fs_scope,
            .profile_grade = .hardened,
        } },
    };
    defer result.deinit();

    _ = try result.activateAfterHandshake();
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqual(macos_profile.SeatbeltProfileGrade.hardened, result.receipt.seatbelt_profile.?);
    try std.testing.expectEqualStrings(
        "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind unrestricted)",
        result.receipt.network_scope,
    );
    var banner_buf: [posture.session_banner_buf_len]u8 = undefined;
    const banner = try posture.formatSessionBanner(&banner_buf, result.receipt);
    try std.testing.expect(std.mem.indexOf(u8, banner, "seatbelt_profile=hardened") != null);
    var audit_buf: [posture.audit_reason_buf_len]u8 = undefined;
    const audit = try posture.formatAuditReason(&audit_buf, result.receipt);
    try std.testing.expect(std.mem.indexOf(u8, audit, "seatbelt_profile=hardened") != null);
    // Unforced path stays unrestricted under hardened.
    var unforced: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .network_route_forced = false,
        .materials = .{ .seatbelt = .{
            .sbpl_z = try std.testing.allocator.dupeZ(u8, "(version 1)\n"),
            .allocator = std.testing.allocator,
            .fs_scope = fs_scope,
            .profile_grade = .hardened,
        } },
    };
    defer unforced.deinit();
    _ = try unforced.activateAfterHandshake();
    try std.testing.expectEqualStrings("unrestricted", unforced.receipt.network_scope);
    try std.testing.expectEqual(macos_profile.SeatbeltProfileGrade.hardened, unforced.receipt.seatbelt_profile.?);
}

test "activateAfterHandshake strict route-forced denies inbound/bind in network_scope" {
    const hash: [64]u8 = .{'f'} ** 64;
    const sbpl = try std.testing.allocator.dupeZ(u8, "(version 1)\n");
    const fs_scope = "workspace RW, system RO, no home, control write-deny (readable), mach-lookup residual";
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.seatbelt, "seatbelt_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .network_route_forced = true,
        .materials = .{ .seatbelt = .{
            .sbpl_z = sbpl,
            .allocator = std.testing.allocator,
            .fs_scope = fs_scope,
            .profile_grade = .strict,
        } },
    };
    defer result.deinit();

    _ = try result.activateAfterHandshake();
    try std.testing.expectEqual(macos_profile.SeatbeltProfileGrade.strict, result.receipt.seatbelt_profile.?);
    try std.testing.expectEqualStrings(
        "proxy route-forced (outbound TCP to Orca loopback proxy only; inbound/bind denied)",
        result.receipt.network_scope,
    );
    var banner_buf: [posture.session_banner_buf_len]u8 = undefined;
    const banner = try posture.formatSessionBanner(&banner_buf, result.receipt);
    try std.testing.expect(std.mem.indexOf(u8, banner, "seatbelt_profile=strict") != null);
}

test "require_network_route_forcing without proxy port fails closed" {
    // Fail-closed before platform grade-drop: no port → no route force materials.
    var fail_reason: []const u8 = "unset";
    const err = applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = "/tmp/orca-apply-ws-route-force-req",
        .env_map = null,
        .network_proxy_port = null,
        .require_network_route_forcing = true,
        .fail_reason_out = &fail_reason,
    });
    try std.testing.expectError(error.RequireFailed, err);
    try std.testing.expectEqualStrings("network_route_forcing_unavailable", fail_reason);
}

test "activateAfterHandshake landlock route-forced network_scope is port-scoped not loopback" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!landlock.isAbiAvailable()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = null,
        .network_proxy_port = 43123,
    });
    defer result.deinit();

    try std.testing.expectEqual(ChildApplyKind.landlock, result.childApplyKind());
    // Without ABI>=4 TCP support, materials may still prepare FS-only (not route-forced).
    if (!result.network_route_forced) return error.SkipZigTest;

    _ = try result.activateAfterHandshake();
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqualStrings(
        "proxy route-forced (TCP connect port-scoped to proxy port; not address-scoped; UDP unrestricted)",
        result.receipt.network_scope,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.receipt.network_scope, "loopback") == null);
}

test "activateAfterHandshake hard-fails without materials" {
    const hash: [64]u8 = .{'b'} ** 64;
    var result: ApplyResult = .{
        .receipt = posture.preparedReceipt(.landlock, "landlock_child_apply_required"),
        .profile_compiled = true,
        .profile_hash_hex = hash,
        .materials = .none,
    };
    defer result.deinit();
    try std.testing.expectError(error.ApplyFailed, result.activateAfterHandshake());
    try std.testing.expect(!result.receipt.isActive());
}

test "spawnAgent without child materials returns ApplyFailed not Unexpected" {
    var result: ApplyResult = .{
        .receipt = posture.disabledReceipt(),
        .profile_compiled = false,
        .profile_hash_hex = null,
        .materials = .none,
    };
    defer result.deinit();
    try std.testing.expectEqual(ChildApplyKind.none, result.childApplyKind());
    try std.testing.expectError(error.ApplyFailed, result.spawnAgent(
        std.testing.io,
        std.testing.allocator,
        &[_][]const u8{"/usr/bin/true"},
        null,
        "/tmp",
        .ignore,
    ));
}

test "spawnAgent promotes with typed proof on macOS Seatbelt" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!macos_seatbelt.sandboxInitAvailable()) return error.SkipZigTest;
    const ver = macos_seatbelt.detectProductVersion() catch return error.SkipZigTest;
    if (!macos_seatbelt.isMatrixMajor(ver.major)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "neighbor.txt", .data = "ok" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = null,
    });
    defer result.deinit();
    try std.testing.expectEqual(ChildApplyKind.seatbelt, result.childApplyKind());
    try std.testing.expect(!result.receipt.isActive());

    const spawned = try result.spawnAgent(
        std.testing.io,
        std.testing.allocator,
        &[_][]const u8{"/usr/bin/true"},
        null,
        root,
        .ignore,
    );
    try std.testing.expect(spawned.proof.isValid());
    try std.testing.expectEqual(posture.BackendMechanism.seatbelt, spawned.proof.mechanism);
    try std.testing.expect(result.receipt.isActive());
    try std.testing.expectEqual(posture.BackendMechanism.seatbelt, result.receipt.mechanism);

    var status: c_int = 0;
    _ = std.c.waitpid(spawned.pid, &status, 0);
    try std.testing.expect((status & 0x7f) == 0);
}

// Regression: agents installed outside workspace/system (e.g. ~/.local/share/claude)
// must receive narrow .exec grants or child preflight fails with ApplyFailed.
test "spawnAgent attaches when launch binary is outside workspace with exec grant" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.os.tag == .macos) {
        if (!macos_seatbelt.sandboxInitAvailable()) return error.SkipZigTest;
        const ver = macos_seatbelt.detectProductVersion() catch return error.SkipZigTest;
        if (!macos_seatbelt.isMatrixMajor(ver.major)) return error.SkipZigTest;
    } else if (!landlock.isAbiAvailable()) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(std.testing.io, ".orca");
    const root = try ws_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    // Separate temp dir = "install tree" outside workspace (like ~/.local/...).
    var bin_tmp = std.testing.tmpDir(.{});
    defer bin_tmp.cleanup();
    const bin_root = try bin_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(bin_root);

    const true_src: []const u8 = blk: {
        std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };
    const outside_bin = try std.fs.path.join(std.testing.allocator, &.{ bin_root, "agent-true" });
    defer std.testing.allocator.free(outside_bin);
    try std.Io.Dir.copyFileAbsolute(true_src, outside_bin, std.testing.io, .{});

    // Without exec grant: outside binary fails child apply handshake.
    {
        var result = try applyBeforeExec(.{
            .allocator = std.testing.allocator,
            .mode = .on,
            .workspace_root = root,
            .env_map = null,
        });
        defer result.deinit();
        try std.testing.expect(result.requiresChildApply());
        try std.testing.expectError(error.ApplyFailed, result.spawnAgent(
            std.testing.io,
            std.testing.allocator,
            &[_][]const u8{outside_bin},
            null,
            root,
            .ignore,
        ));
        try std.testing.expect(!result.receipt.isActive());
    }

    // With launch_exec_paths: attach succeeds and agent runs.
    {
        const exec_paths = try collectLaunchExecPaths(std.testing.io, std.testing.allocator, outside_bin, null);
        defer freeLaunchExecPaths(std.testing.allocator, exec_paths);
        try std.testing.expect(exec_paths.len >= 1);

        var result = try applyBeforeExec(.{
            .allocator = std.testing.allocator,
            .mode = .on,
            .workspace_root = root,
            .env_map = null,
            .launch_exec_paths = exec_paths,
        });
        defer result.deinit();
        try std.testing.expect(result.requiresChildApply());

        const spawned = try result.spawnAgent(
            std.testing.io,
            std.testing.allocator,
            &[_][]const u8{outside_bin},
            null,
            root,
            .ignore,
        );
        try std.testing.expect(spawned.proof.isValid());
        try std.testing.expect(result.receipt.isActive());

        var status: c_int = 0;
        _ = std.c.waitpid(spawned.pid, &status, 0);
        try std.testing.expect((status & 0x7f) == 0);
    }
}

test "collectLaunchExecPaths resolves regular file and rejects HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const true_src: []const u8 = blk: {
        std.Io.Dir.cwd().access(io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };
    const paths = try collectLaunchExecPaths(io, allocator, true_src, null);
    defer freeLaunchExecPaths(allocator, paths);
    try std.testing.expect(paths.len >= 1);
    try std.testing.expect(std.mem.eql(u8, paths[0], true_src) or std.mem.endsWith(u8, paths[0], "true"));

    // Directories are never granted (Seatbelt subpath would open the whole tree).
    // Bare HOME is also rejected when equal to a candidate path (defense in depth).
    var dir_tmp = std.testing.tmpDir(.{});
    defer dir_tmp.cleanup();
    const dir_path = try dir_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", dir_path);
    const home_paths = try collectLaunchExecPaths(io, allocator, dir_path, &env_map);
    defer freeLaunchExecPaths(allocator, home_paths);
    try std.testing.expectEqual(@as(usize, 0), home_paths.len);
}

fn pathsContain(paths: []const []const u8, want: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, want)) return true;
    }
    return false;
}

fn pathsContainHomeOrDir(paths: []const []const u8, home: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, home)) return true;
        if (std.mem.eql(u8, p, "/")) return true;
    }
    return false;
}

test "collectLaunchExecPaths grants env shebang interpreter outside workspace" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bin_tmp = std.testing.tmpDir(.{});
    defer bin_tmp.cleanup();
    const bin_root = try bin_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(bin_root);

    const true_src: []const u8 = blk: {
        std.Io.Dir.cwd().access(io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };
    const node_bin = try std.fs.path.join(allocator, &.{ bin_root, "fake-node" });
    defer allocator.free(node_bin);
    try std.Io.Dir.copyFileAbsolute(true_src, node_bin, io, .{});
    try bin_tmp.dir.setFilePermissions(io, "fake-node", std.Io.File.Permissions.fromMode(0o755), .{});

    const script_body = "#!/usr/bin/env fake-node\n";
    try bin_tmp.dir.writeFile(io, .{ .sub_path = "agent-script", .data = script_body });
    try bin_tmp.dir.setFilePermissions(io, "agent-script", std.Io.File.Permissions.fromMode(0o755), .{});
    const script_path = try std.fs.path.join(allocator, &.{ bin_root, "agent-script" });
    defer allocator.free(script_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PATH", bin_root);
    try env_map.put("HOME", bin_root);

    const paths = try collectLaunchExecPaths(io, allocator, script_path, &env_map);
    defer freeLaunchExecPaths(allocator, paths);

    try std.testing.expect(pathsContain(paths, script_path));
    try std.testing.expect(pathsContain(paths, node_bin));
    try std.testing.expect(!pathsContainHomeOrDir(paths, bin_root));
    for (paths) |p| {
        try std.testing.expect(isRegularFile(io, p));
    }
}

test "collectLaunchExecPaths grants absolute shebang interpreter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bin_tmp = std.testing.tmpDir(.{});
    defer bin_tmp.cleanup();
    const bin_root = try bin_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(bin_root);

    const true_src: []const u8 = blk: {
        std.Io.Dir.cwd().access(io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };
    const interp = try std.fs.path.join(allocator, &.{ bin_root, "interp-true" });
    defer allocator.free(interp);
    try std.Io.Dir.copyFileAbsolute(true_src, interp, io, .{});
    try bin_tmp.dir.setFilePermissions(io, "interp-true", std.Io.File.Permissions.fromMode(0o755), .{});

    const script_body = try std.fmt.allocPrint(allocator, "#!{s}\n", .{interp});
    defer allocator.free(script_body);
    try bin_tmp.dir.writeFile(io, .{ .sub_path = "abs-script", .data = script_body });
    try bin_tmp.dir.setFilePermissions(io, "abs-script", std.Io.File.Permissions.fromMode(0o755), .{});
    const script_path = try std.fs.path.join(allocator, &.{ bin_root, "abs-script" });
    defer allocator.free(script_path);

    const paths = try collectLaunchExecPaths(io, allocator, script_path, null);
    defer freeLaunchExecPaths(allocator, paths);

    try std.testing.expect(pathsContain(paths, script_path));
    try std.testing.expect(pathsContain(paths, interp));
}

test "collectLaunchExecPaths rejects directory shebang interpreter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bin_tmp = std.testing.tmpDir(.{});
    defer bin_tmp.cleanup();
    const bin_root = try bin_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(bin_root);

    try bin_tmp.dir.createDirPath(io, "not-a-binary");
    const dir_interp = try std.fs.path.join(allocator, &.{ bin_root, "not-a-binary" });
    defer allocator.free(dir_interp);

    const script_body = try std.fmt.allocPrint(allocator, "#!{s}\n", .{dir_interp});
    defer allocator.free(script_body);
    try bin_tmp.dir.writeFile(io, .{ .sub_path = "bad-interp-script", .data = script_body });
    try bin_tmp.dir.setFilePermissions(io, "bad-interp-script", std.Io.File.Permissions.fromMode(0o755), .{});
    const script_path = try std.fs.path.join(allocator, &.{ bin_root, "bad-interp-script" });
    defer allocator.free(script_path);

    const paths = try collectLaunchExecPaths(io, allocator, script_path, null);
    defer freeLaunchExecPaths(allocator, paths);

    try std.testing.expect(pathsContain(paths, script_path));
    try std.testing.expect(!pathsContain(paths, dir_interp));
    try std.testing.expect(!pathsContain(paths, bin_root));
}

test "spawnAgent attaches when shebang script and interpreter are outside workspace" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.os.tag == .macos) {
        if (!macos_seatbelt.sandboxInitAvailable()) return error.SkipZigTest;
        const ver = macos_seatbelt.detectProductVersion() catch return error.SkipZigTest;
        if (!macos_seatbelt.isMatrixMajor(ver.major)) return error.SkipZigTest;
    } else if (!landlock.isAbiAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");
    const root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var bin_tmp = std.testing.tmpDir(.{});
    defer bin_tmp.cleanup();
    const bin_root = try bin_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(bin_root);

    const true_src: []const u8 = blk: {
        std.Io.Dir.cwd().access(io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };
    const interp = try std.fs.path.join(allocator, &.{ bin_root, "interp-true" });
    defer allocator.free(interp);
    try std.Io.Dir.copyFileAbsolute(true_src, interp, io, .{});
    try bin_tmp.dir.setFilePermissions(io, "interp-true", std.Io.File.Permissions.fromMode(0o755), .{});

    const script_body = try std.fmt.allocPrint(allocator, "#!{s}\n", .{interp});
    defer allocator.free(script_body);
    try bin_tmp.dir.writeFile(io, .{ .sub_path = "shebang-agent", .data = script_body });
    try bin_tmp.dir.setFilePermissions(io, "shebang-agent", std.Io.File.Permissions.fromMode(0o755), .{});
    const script_path = try std.fs.path.join(allocator, &.{ bin_root, "shebang-agent" });
    defer allocator.free(script_path);

    const exec_paths = try collectLaunchExecPaths(io, allocator, script_path, null);
    defer freeLaunchExecPaths(allocator, exec_paths);
    try std.testing.expect(pathsContain(exec_paths, script_path));
    try std.testing.expect(pathsContain(exec_paths, interp));
    try std.testing.expect(!pathsContainHomeOrDir(exec_paths, bin_root));

    var result = try applyBeforeExec(.{
        .allocator = allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = null,
        .launch_exec_paths = exec_paths,
    });
    defer result.deinit();
    try std.testing.expect(result.requiresChildApply());

    const spawned = try result.spawnAgent(
        io,
        allocator,
        &[_][]const u8{script_path},
        null,
        root,
        .ignore,
    );
    try std.testing.expect(spawned.proof.isValid());
    try std.testing.expect(result.receipt.isActive());

    var status: c_int = 0;
    _ = std.c.waitpid(spawned.pid, &status, 0);
    try std.testing.expect((status & 0x7f) == 0);
}

test "parseShebangInterpreterToken handles env and absolute forms" {
    try std.testing.expectEqualStrings("/usr/bin/python3", parseShebangInterpreterToken("/usr/bin/python3").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env -S node --experimental").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env -Snode --experimental").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env -u FOO node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env -uFOO node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env -S -P /opt/bin node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env FOO=bar node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env --unset=FOO node").?);
    try std.testing.expectEqualStrings("node", parseShebangInterpreterToken("/usr/bin/env --split-string=node --experimental").?);
    try std.testing.expect(parseShebangInterpreterToken("/usr/bin/env") == null);
    try std.testing.expect(parseShebangInterpreterToken("/usr/bin/env -u") == null);
    try std.testing.expect(parseShebangInterpreterToken("") == null);
}

test "mode on surfaces real reason_code via fail_reason_out on this host" {
    var fail_reason: []const u8 = "unset";
    var result = applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = "/tmp/orca-apply-ws-u07-reason",
        .env_map = null,
        .fail_reason_out = &fail_reason,
    });
    // On hosts without a usable backend, RequireFailed with a real reason (not placeholder).
    if (result) |*ok| {
        defer ok.deinit();
        // Prepared child plan only — never session-active from the parent seam.
        try std.testing.expect(ok.requiresChildApply());
        try std.testing.expect(!ok.receipt.isActive());
    } else |e| {
        try std.testing.expectEqual(error.RequireFailed, e);
        try std.testing.expect(!std.mem.eql(u8, fail_reason, "unset"));
        // Real reason codes only — never the backend_not_implemented placeholder on Darwin.
        if (builtin.os.tag == .macos) {
            try std.testing.expect(std.mem.indexOf(u8, fail_reason, "backend_not_implemented") == null);
        }
    }
}

test "session banner helper remains mechanism-neutral for apply receipts" {
    var buf: [320]u8 = undefined;
    const hash64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const active = try posture.activeReceipt(.seatbelt, hash64, "workspace RW, system RO, platform tmp RW, no home");
    const line = try posture.formatSessionBanner(&buf, active);
    try std.testing.expect(std.mem.indexOf(u8, line, "OS sandbox: active") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Seatbelt") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Landlock") == null);
}

test "isUngrantedHostTmpdir detects macOS var/folders shapes" {
    try std.testing.expect(isUngrantedHostTmpdir("/var/folders/xx/yy/T/"));
    try std.testing.expect(isUngrantedHostTmpdir("/private/var/folders/xx/yy/T"));
    try std.testing.expect(!isUngrantedHostTmpdir("/tmp"));
    try std.testing.expect(!isUngrantedHostTmpdir("/private/tmp"));
    try std.testing.expect(!isUngrantedHostTmpdir("/workspace/.orca-tmp"));
}

test "rewriteTempEnvForAttach points TMPDIR at workspace session temp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    // Simulate macOS host TMPDIR (ungranted under Seatbelt defaults).
    try env_map.put("TMPDIR", "/var/folders/ns/xmz0/T/");
    try env_map.put("TMP", "/var/folders/ns/xmz0/T/");
    try env_map.put("TEMP", "/var/folders/ns/xmz0/T/");

    const rewritten = try rewriteTempEnvForAttach(std.testing.allocator, &env_map, root);
    try std.testing.expect(!isUngrantedHostTmpdir(rewritten));
    // Production defaults: session temp only — never silent classic /tmp fallback (M-8).
    try std.testing.expect(std.mem.endsWith(u8, rewritten, "/.orca-tmp"));
    try std.testing.expect(!std.mem.eql(u8, rewritten, classic_tmp_fallback));
    try std.testing.expectEqualStrings(rewritten, env_map.get("TMPDIR").?);
    try std.testing.expectEqualStrings(rewritten, env_map.get("TMP").?);
    try std.testing.expectEqualStrings(rewritten, env_map.get("TEMP").?);

    // Preferred path must exist when rewrite succeeds.
    var io_rt: std.Io.Threaded = .init_single_threaded;
    const io = io_rt.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, rewritten, .{});
    dir.close(io);
}

test "rewriteTempEnvForAttach fails closed when session tmp cannot be prepared" {
    // Empty workspace → ensureWorkspaceSessionTmp returns false; must not rewrite to /tmp.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TMPDIR", "/var/folders/ns/xmz0/T/");
    try env_map.put("TMP", "/var/folders/ns/xmz0/T/");
    try env_map.put("TEMP", "/var/folders/ns/xmz0/T/");

    try std.testing.expectError(
        error.SessionTmpPrepareFailed,
        rewriteTempEnvForAttach(std.testing.allocator, &env_map, ""),
    );
    // Env must remain unchanged (no lying classic /tmp rewrite).
    try std.testing.expectEqualStrings("/var/folders/ns/xmz0/T/", env_map.get("TMPDIR").?);
    try std.testing.expectEqualStrings("/var/folders/ns/xmz0/T/", env_map.get("TMP").?);
    try std.testing.expectEqualStrings("/var/folders/ns/xmz0/T/", env_map.get("TEMP").?);

    // Over-long workspace also fails ensure (path buffer overflow) without classic fallback.
    var long_root: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&long_root, 'x');
    long_root[0] = '/';
    try std.testing.expectError(
        error.SessionTmpPrepareFailed,
        rewriteTempEnvForAttach(std.testing.allocator, &env_map, long_root[0..]),
    );
    try std.testing.expectEqualStrings("/var/folders/ns/xmz0/T/", env_map.get("TMPDIR").?);
}

test "attach path rewrites host TMPDIR out of var/folders (R2-2)" {
    // Only meaningful when prepare yields child-apply materials (macOS Seatbelt / Linux Landlock).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    try env_map.put("HOME", "/tmp");
    try env_map.put("TMPDIR", "/var/folders/xx/yy/T/");
    try env_map.put("LD_PRELOAD", "evil.so");

    var result = try applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .auto,
        .workspace_root = root,
        .env_map = &env_map,
    });
    defer result.deinit();

    try std.testing.expect(env_map.get("LD_PRELOAD") == null);
    if (result.requiresChildApply()) {
        const td = env_map.get("TMPDIR") orelse "";
        try std.testing.expect(td.len > 0);
        try std.testing.expect(!isUngrantedHostTmpdir(td));
        // Production defaults: session temp under workspace only (M-8; no classic /tmp).
        try std.testing.expect(std.mem.endsWith(u8, td, "/.orca-tmp"));
        try std.testing.expect(!std.mem.eql(u8, td, classic_tmp_fallback));
        // Pure grants: rewritten path must be agent-writable under production model.
        switch (result.materials) {
            .landlock => |*p| {
                try std.testing.expect(p.compiled.isAgentWritable(td));
            },
            else => {
                var compiled = try profile.compileProfile(std.testing.allocator, .{
                    .workspace_root = root,
                });
                defer compiled.deinit();
                try std.testing.expect(compiled.isAgentWritable(td));
            },
        }
    } else {
        // Grade-drop: no rewrite (attach-only contract).
        try std.testing.expectEqualStrings("/var/folders/xx/yy/T/", env_map.get("TMPDIR").?);
    }
}

test "protect_workspace_secrets compiles into profile hash material" {
    var compiled = try profile.compileProfile(std.testing.allocator, .{
        .workspace_root = "/tmp/orca-ws-protect",
        .include_tmp = false,
        .protect_workspace_secrets = true,
    });
    defer compiled.deinit();
    try std.testing.expect(compiled.protect_workspace_secrets);
    try std.testing.expect(std.mem.indexOf(u8, compiled.canonical_bytes, "protect_workspace_secrets\ttrue") != null);
}
