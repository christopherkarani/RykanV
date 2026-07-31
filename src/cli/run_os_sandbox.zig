//! OS filesystem sandbox helpers for `ryk run`.
//!
//! Keeps apply-before-exec wiring, spawn hooks, auto-degrade messaging, and
//! posture audit/banner helpers out of the main `run.zig` orchestration file.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("orca_core").core;
const core_api = @import("orca_core").api;
const sandbox = @import("../sandbox/mod.zig");
const exit_codes = @import("exit_codes.zig");
const tui = @import("../tui/mod.zig");

/// ~12 fps — same cadence as `ryk scan` spinner.
const prepare_spinner_tick = std.Io.Duration.fromNanoseconds(80 * std.time.ns_per_ms);

pub const ApplyForRunOutcome = union(enum) {
    /// `--os-sandbox on` failed closed; already printed reason to stderr.
    require_failed: u8,
    /// Prepared (or disabled) result — caller must `deinit`.
    ok: sandbox.apply.ApplyResult,
};

/// TTY activity for the long protect-on / platform prepare window so monorepo
/// hardlink scans do not look hung. No residual success line — the session
/// banner follows. Spinner thread is joined before return so agent fork stays
/// free of this ticker (Seatbelt multi-thread residual).
fn PrepareActivity(comptime Writer: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        writer: Writer,
        label: []const u8,
        spinner: ?tui.spinner.Spinner(Writer) = null,
        active: bool = false,
        mutex: std.Io.Mutex = .init,
        stop_ticker: std.atomic.Value(bool) = .init(true),
        ticker_thread: ?std.Thread = null,

        fn start(self: *Self) void {
            if (!tui.theme.active(self.io, self.writer).capability.hasColor()) return;
            self.spinner = .{
                .label = self.label,
                .io = self.io,
                .stdout = self.writer,
            };
            self.spinner.?.start() catch {};
            self.active = true;
            self.startTicker();
        }

        fn startTicker(self: *Self) void {
            if (tui.theme.reducedMotion(self.io, self.writer)) return;
            if (!tui.theme.active(self.io, self.writer).capability.hasColor()) return;
            if (self.ticker_thread != null) return;
            self.stop_ticker.store(false, .release);
            self.ticker_thread = std.Thread.spawn(.{}, tickerLoop, .{self}) catch null;
        }

        fn stopTicker(self: *Self) void {
            self.stop_ticker.store(true, .release);
            if (self.ticker_thread) |t| {
                t.join();
                self.ticker_thread = null;
            }
        }

        fn clear(self: *Self) void {
            if (!self.active) return;
            self.stopTicker();
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Clear in-place frame only; no ✓/✗ line (session banner or error follows).
            if (tui.theme.active(self.io, self.writer).capability.hasColor() and
                !tui.theme.reducedMotion(self.io, self.writer))
            {
                self.writer.writeAll("\r\x1b[2K\r") catch {};
            }
            flushWriter(self.writer) catch {};
            self.active = false;
            self.spinner = null;
        }

        fn tickLocked(self: *Self) void {
            if (self.spinner) |*sp| sp.tick() catch {};
        }

        fn tickerLoop(self: *Self) void {
            while (!self.stop_ticker.load(.acquire)) {
                std.Io.sleep(self.io, prepare_spinner_tick, .awake) catch {};
                if (self.stop_ticker.load(.acquire)) break;
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (!self.active) continue;
                self.tickLocked();
            }
        }
    };
}

fn flushWriter(writer: anytype) !void {
    const Writer = @TypeOf(writer);
    switch (@typeInfo(Writer)) {
        .pointer => |pointer| if (@hasDecl(pointer.child, "flush")) try writer.flush(),
        else => if (@hasDecl(Writer, "flush")) try writer.flush(),
    }
}

/// Apply OS sandbox for the production run path.
///
/// `progress` is the TTY stream for prepare activity (typically stdout, same as
/// the session banner). Errors still print on `stderr`.
///
/// `launch_argv0` is the agent command (first argv of `ryk run -- <cmd>`). When set,
/// resolved absolute file paths are granted as narrow `.exec` profile entries so
/// agents installed outside workspace/system prefixes (typical `~/.local/...`) can
/// pass child preflight after Seatbelt/Landlock attach.
pub fn applyForRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    mode: sandbox.posture.OsSandboxMode,
    workspace_root: []const u8,
    env_map: *std.process.Environ.Map,
    minted_env_lookup: ?sandbox.env_scrub.MintedEnvLookup,
    with_host_secrets: bool,
    network_proxy_port: ?u16,
    require_network_route_forcing: bool,
    seatbelt_profile: sandbox.posture.SeatbeltProfileGrade,
    protect_workspace_secrets: bool,
    progress: anytype,
    stderr: anytype,
    launch_argv0: ?[]const u8,
) !ApplyForRunOutcome {
    const label: []const u8 = if (protect_workspace_secrets)
        "Preparing OS sandbox (scanning workspace secrets)"
    else
        "Preparing OS sandbox";

    var activity = PrepareActivity(@TypeOf(progress)){
        .io = io,
        .writer = progress,
        .label = label,
    };
    // Only animate when apply will do real work (on/auto). Join ticker in clear
    // before return so later agent fork is not multi-threaded solely for UX.
    if (mode != .off) activity.start();
    defer activity.clear();

    var fail_reason: []const u8 = "unknown";
    var io_rt: std.Io.Threaded = .init_single_threaded;
    const launch_io = io_rt.io();
    const launch_exec_paths: []const []const u8 = if (launch_argv0) |argv0|
        try sandbox.apply.collectLaunchExecPaths(launch_io, allocator, argv0, env_map)
    else
        &.{};
    defer if (launch_argv0 != null) sandbox.apply.freeLaunchExecPaths(allocator, launch_exec_paths);

    const result = sandbox.apply.applyBeforeExec(.{
        .allocator = allocator,
        .mode = mode,
        .workspace_root = workspace_root,
        .env_map = env_map,
        .minted_env_lookup = minted_env_lookup,
        .with_host_secrets = with_host_secrets,
        .launch_exec_paths = launch_exec_paths,
        .network_proxy_port = network_proxy_port,
        .require_network_route_forcing = require_network_route_forcing,
        .seatbelt_profile = seatbelt_profile,
        .protect_workspace_secrets = protect_workspace_secrets,
        .fail_reason_out = &fail_reason,
    }) catch |err| switch (err) {
        error.RequireFailed => {
            // Clear activity before the durable error line.
            activity.clear();
            // Incomplete env scrub fails closed on both on and auto; wording must not
            // always claim the user passed `--os-sandbox on`.
            switch (mode) {
                .on => try stderr.print(
                    "ryk run: OS sandbox required but unavailable ({s}).\n",
                    .{fail_reason},
                ),
                .auto => try stderr.print(
                    "ryk run: OS sandbox failed closed under --os-sandbox auto ({s}).\n",
                    .{fail_reason},
                ),
                .off => try stderr.print(
                    "ryk run: OS sandbox unavailable ({s}).\n",
                    .{fail_reason},
                ),
            }
            return .{ .require_failed = exit_codes.unsupported };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = result };
}

/// True when `err` is a sandbox child-apply/spawn failure that must not look like a
/// generic command launch issue.
pub fn isSandboxSpawnFailure(err: anyerror) bool {
    return switch (err) {
        error.ApplyFailed,
        error.ForkFailed,
        error.Unsupported,
        error.ExecFailed,
        error.ProfileHashMismatch,
        error.HandshakeTimeout,
        error.FuseDeviceUnavailable,
        error.ProfileRebuildFailed,
        error.FuseMountFailed,
        error.FuseDaemonStartFailed,
        error.FuseInitFailed,
        error.NamespaceSetupFailed,
        error.LandlockUnavailable,
        error.LandlockAttachFailed,
        error.CapabilityLockdownFailed,
        error.MountVerificationFailed,
        error.TooManyExecPaths,
        => true,
        else => false,
    };
}

/// Operator-facing reason for a failed sandboxed spawn.
pub fn sandboxSpawnFailReason(err: anyerror) []const u8 {
    return switch (err) {
        error.ApplyFailed => "child_apply_failed",
        error.ForkFailed => "sandbox_fork_failed",
        error.Unsupported => "sandbox_backend_unsupported",
        error.ExecFailed => "sandbox_exec_failed",
        error.ProfileHashMismatch => "profile_hash_mismatch",
        error.HandshakeTimeout => "handshake_timeout",
        error.FuseDeviceUnavailable => "fuse_device_unavailable",
        error.ProfileRebuildFailed => "profile_rebuild_failed",
        error.FuseMountFailed => "fuse_mount_failed",
        error.FuseDaemonStartFailed => "fuse_daemon_start_failed",
        error.FuseInitFailed => "fuse_init_failed",
        error.NamespaceSetupFailed => "namespace_setup_failed",
        error.LandlockUnavailable => "landlock_unavailable",
        error.LandlockAttachFailed => "landlock_attach_failed",
        error.CapabilityLockdownFailed => "capability_lockdown_failed",
        error.MountVerificationFailed => "mount_verification_failed",
        error.TooManyExecPaths => "too_many_exec_paths",
        else => "sandbox_spawn_failed",
    };
}

/// Loud grade-drop warning for `--os-sandbox auto` when no child apply plan exists.
pub fn warnAutoDegrade(
    mode: sandbox.posture.OsSandboxMode,
    apply_result: *const sandbox.apply.ApplyResult,
    stderr: anytype,
) !void {
    if (mode != .auto or apply_result.childApplyKind() != .none) return;
    switch (apply_result.receipt.posture) {
        .unavailable, .failed => {
            const reason = apply_result.receipt.reason_code orelse "unknown";
            try stderr.print(
                "ryk run: WARNING: OS sandbox unavailable ({s}); continuing without OS FS isolation (grade drop). Use --os-sandbox on to require it, or --os-sandbox off to silence.\n",
                .{reason},
            );
        },
        // prepared has child materials — not a grade drop.
        .active, .prepared, .disabled => {},
    }
}

/// Build production `OsChildApply` from prepared materials (Landlock/Seatbelt).
/// `apply_result` must outlive the returned hook (spawn mutates it to active).
pub fn buildOsChildApply(
    apply_result: *sandbox.apply.ApplyResult,
    ctx: *SandboxSpawnCtx,
) core.process.OsChildApply {
    ctx.* = .{ .apply_result = apply_result };
    return switch (apply_result.childApplyKind()) {
        .none => .none,
        .landlock, .seatbelt => .{ .custom = .{
            .context = ctx,
            .spawnFn = SandboxSpawnCtx.spawn,
        } },
    };
}

pub const SandboxSpawnCtx = struct {
    apply_result: *sandbox.apply.ApplyResult,

    pub fn spawn(context: *anyopaque, request: core.process.CustomSpawnRequest) anyerror!std.process.Child {
        const self: *@This() = @ptrCast(@alignCast(context));
        const child_stdio: sandbox.apply_posix.StdioBehavior = switch (request.stdio) {
            .inherit => .inherit,
            .ignore => .ignore,
        };
        // spawnAgent activates receipt after child handshake.
        const spawned = try self.apply_result.spawnAgent(
            request.io,
            request.allocator,
            request.argv,
            request.env_map,
            request.workspace_root,
            child_stdio,
        );
        return core.process.childFromPid(spawned.pid);
    }
};

/// Emit sandbox_posture at session start (posture/hash/fs_scope/grade only — no rule blobs).
pub fn auditSandboxPosture(
    audit_context: anytype,
    session: core.session.Session,
    receipt: sandbox.posture.AttachReceipt,
) !void {
    if (audit_context.writer == null) return;
    var reason_buf: [sandbox.posture.audit_reason_buf_len]u8 = undefined;
    const reason = try sandbox.posture.formatAuditReason(&reason_buf, receipt);
    const ts = core.time.Timestamp.now(audit_context.io);
    const ev: core.event.Event = .{
        .session_id = session.id,
        .event_id = try core.event.generateEventId(ts),
        .timestamp = ts,
        .event_type = .sandbox_posture,
        .actor = .{ .kind = .orca, .display = "ryk" },
        .target = .{ .kind = .session, .value = "os_filesystem_sandbox" },
        .decision = .{
            .result = .observe,
            .reason = reason,
            .ci_may_proceed = true,
        },
    };
    try core_api.appendAuditEvent(&audit_context.writer.?, ev);
}

/// Format mechanism-neutral OS sandbox banner line for session start.
pub fn formatOsSandboxBannerLine(
    buf: []u8,
    receipt: sandbox.posture.AttachReceipt,
    with_host_secrets: bool,
) []const u8 {
    // Thin wrapper: on format overflow, keep the receipt posture tag only.
    // Never invent "unavailable" for an active/disabled/failed receipt.
    if (with_host_secrets and receipt.posture == .active) {
        return if (receipt.seatbelt_profile) |grade|
            std.fmt.bufPrint(
                buf,
                "OS sandbox: active (filesystem: {s}; network: {s}; seatbelt_profile={s}; credentials: host environment retained (explicit escape); tools: wrapper-mediated)",
                .{ receipt.fs_scope, receipt.network_scope, grade.toString() },
            ) catch "OS sandbox: active (credentials: host environment retained; explicit escape)"
        else
            std.fmt.bufPrint(
                buf,
                "OS sandbox: active (filesystem: {s}; network: {s}; credentials: host environment retained (explicit escape); tools: wrapper-mediated)",
                .{ receipt.fs_scope, receipt.network_scope },
            ) catch "OS sandbox: active (credentials: host environment retained; explicit escape)";
    }
    return sandbox.posture.formatSessionBanner(buf, receipt) catch switch (receipt.posture) {
        .active => "OS sandbox: active",
        .prepared => "OS sandbox: prepared",
        .unavailable => "OS sandbox: unavailable",
        .failed => "OS sandbox: failed",
        .disabled => "OS sandbox: disabled",
    };
}

test "PrepareActivity start/clear is idempotent without residual success glyph" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var activity = PrepareActivity(*std.Io.Writer){
        .io = std.testing.io,
        .writer = &writer,
        .label = "Preparing OS sandbox",
    };
    // No color under test io → start is a no-op; clear must stay safe.
    activity.start();
    activity.clear();
    activity.clear();
    try std.testing.expect(!activity.active);
    try std.testing.expect(activity.spinner == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "✓") == null);
}

test "isSandboxSpawnFailure classifies ApplyFailed ForkFailed Unsupported ExecFailed; not FileNotFound" {
    try std.testing.expect(isSandboxSpawnFailure(error.ApplyFailed));
    try std.testing.expect(isSandboxSpawnFailure(error.ForkFailed));
    try std.testing.expect(isSandboxSpawnFailure(error.Unsupported));
    try std.testing.expect(isSandboxSpawnFailure(error.ExecFailed));
    try std.testing.expect(isSandboxSpawnFailure(error.ProfileHashMismatch));
    try std.testing.expect(isSandboxSpawnFailure(error.HandshakeTimeout));
    try std.testing.expect(isSandboxSpawnFailure(error.FuseMountFailed));
    try std.testing.expect(isSandboxSpawnFailure(error.LandlockAttachFailed));
    try std.testing.expect(isSandboxSpawnFailure(error.TooManyExecPaths));
    try std.testing.expect(!isSandboxSpawnFailure(error.FileNotFound));
}

test "sandboxSpawnFailReason maps classified spawn errors" {
    try std.testing.expectEqualStrings("child_apply_failed", sandboxSpawnFailReason(error.ApplyFailed));
    try std.testing.expectEqualStrings("sandbox_fork_failed", sandboxSpawnFailReason(error.ForkFailed));
    try std.testing.expectEqualStrings("sandbox_backend_unsupported", sandboxSpawnFailReason(error.Unsupported));
    try std.testing.expectEqualStrings("sandbox_exec_failed", sandboxSpawnFailReason(error.ExecFailed));
    try std.testing.expectEqualStrings("profile_hash_mismatch", sandboxSpawnFailReason(error.ProfileHashMismatch));
    try std.testing.expectEqualStrings("handshake_timeout", sandboxSpawnFailReason(error.HandshakeTimeout));
    try std.testing.expectEqualStrings("fuse_device_unavailable", sandboxSpawnFailReason(error.FuseDeviceUnavailable));
    try std.testing.expectEqualStrings("profile_rebuild_failed", sandboxSpawnFailReason(error.ProfileRebuildFailed));
    try std.testing.expectEqualStrings("fuse_mount_failed", sandboxSpawnFailReason(error.FuseMountFailed));
    try std.testing.expectEqualStrings("landlock_attach_failed", sandboxSpawnFailReason(error.LandlockAttachFailed));
    try std.testing.expectEqualStrings("too_many_exec_paths", sandboxSpawnFailReason(error.TooManyExecPaths));
    // Unrelated errors fall through to a generic reason (not classified true above).
    try std.testing.expectEqualStrings("sandbox_spawn_failed", sandboxSpawnFailReason(error.FileNotFound));
}

test "formatOsSandboxBannerLine does not invent unavailable for active on format error" {
    // Tiny buffer forces formatSessionBanner NoSpaceLeft; fallback must keep posture tag.
    var tiny: [8]u8 = undefined;
    const active = try sandbox.posture.activeReceipt(
        .landlock,
        "abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123",
        "workspace child RW, root RO, system RO, platform tmp RW, no home",
    );
    try std.testing.expect(active.posture == .active);
    const line = formatOsSandboxBannerLine(&tiny, active, false);
    try std.testing.expect(std.mem.indexOf(u8, line, "unavailable") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "active") != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "OS sandbox:"));
}

test "formatOsSandboxBannerLine attests explicit host-secret escape" {
    var buf: [512]u8 = undefined;
    const active = try sandbox.posture.activeReceipt(
        .landlock,
        "abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123",
        "workspace child RW, root RO, system RO, no home",
    );
    const line = formatOsSandboxBannerLine(&buf, active, true);
    try std.testing.expect(std.mem.indexOf(u8, line, "host environment retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "explicit escape") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "secrets stripped") == null);
}

test "warnAutoDegrade is silent for disabled posture (mode off materials)" {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer: std.Io.Writer = .fixed(&stderr_buf);
    const result = try sandbox.apply.applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .off,
        .workspace_root = "/tmp/ws",
        .env_map = null,
    });
    // mode off → disabled receipt; even under .auto mode flag, no grade-drop warn.
    try warnAutoDegrade(.auto, &result, &stderr_writer);
    try std.testing.expectEqual(@as(usize, 0), stderr_writer.buffered().len);
}

test "apply materials alone never authorize active" {
    var result = try sandbox.apply.applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .off,
        .workspace_root = "/tmp/ws",
        .env_map = null,
    });
    defer result.deinit();
    // activateAfterHandshake is file-private; materials/receipt from apply must stay non-active.
    try std.testing.expect(!result.receipt.isActive());
    try std.testing.expectEqual(sandbox.apply.ChildApplyKind.none, result.childApplyKind());
}

/// M-27: waitpid with EINTR retry for integration tests (mirrors apply_posix).
fn waitpidRetry(pid: std.c.pid_t, status: *c_int) void {
    while (true) {
        const rc = std.c.waitpid(pid, status, 0);
        if (rc >= 0) return;
        if (std.c.errno(rc) == .INTR) continue;
        return;
    }
}

test "run path spawnAgent attach when Seatbelt available" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandbox.macos_seatbelt.sandboxInitAvailable()) return error.SkipZigTest;
    const ver = sandbox.macos_seatbelt.detectProductVersion() catch return error.SkipZigTest;
    if (!sandbox.macos_seatbelt.isMatrixMajor(ver.major)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "neighbor.txt", .data = "ok" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    try env_map.put("HOME", "/tmp");
    try env_map.put("OPENAI_API_KEY", "sk-should-be-stripped");

    var apply_result = try sandbox.apply.applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = &env_map,
    });
    defer apply_result.deinit();
    try std.testing.expectEqual(sandbox.apply.ChildApplyKind.seatbelt, apply_result.childApplyKind());
    // Secret stripped by launch allowlist.
    try std.testing.expect(env_map.get("OPENAI_API_KEY") == null);
    try std.testing.expect(env_map.get("PATH") != null);

    var ctx: SandboxSpawnCtx = undefined;
    const os_apply = buildOsChildApply(&apply_result, &ctx);
    try std.testing.expect(os_apply == .custom);

    const child = try SandboxSpawnCtx.spawn(@ptrCast(&ctx), .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{"/usr/bin/true"},
        .workspace_root = root,
        .env_map = &env_map,
        .stdio = .ignore,
    });
    try std.testing.expect(apply_result.receipt.isActive());
    try std.testing.expectEqual(sandbox.posture.BackendMechanism.seatbelt, apply_result.receipt.mechanism);

    var status: c_int = 0;
    if (child.id) |pid| {
        waitpidRetry(pid, &status);
    }
    try std.testing.expect((status & 0x7f) == 0);
}

// M-29: Linux mirror of the macOS spawnAgent attach integration above.
test "run path spawnAgent attach when Landlock available" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!sandbox.landlock.isAbiAvailable()) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".orca");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "neighbor.txt", .data = "ok" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    try env_map.put("HOME", "/tmp");
    try env_map.put("OPENAI_API_KEY", "sk-should-be-stripped");

    var apply_result = try sandbox.apply.applyBeforeExec(.{
        .allocator = std.testing.allocator,
        .mode = .on,
        .workspace_root = root,
        .env_map = &env_map,
    });
    defer apply_result.deinit();
    try std.testing.expectEqual(sandbox.apply.ChildApplyKind.landlock, apply_result.childApplyKind());
    try std.testing.expect(env_map.get("OPENAI_API_KEY") == null);
    try std.testing.expect(env_map.get("PATH") != null);

    var ctx: SandboxSpawnCtx = undefined;
    const os_apply = buildOsChildApply(&apply_result, &ctx);
    try std.testing.expect(os_apply == .custom);

    const true_bin: []const u8 = blk: {
        std.Io.Dir.cwd().access(std.testing.io, "/usr/bin/true", .{}) catch break :blk "/bin/true";
        break :blk "/usr/bin/true";
    };

    const child = try SandboxSpawnCtx.spawn(@ptrCast(&ctx), .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{true_bin},
        .workspace_root = root,
        .env_map = &env_map,
        .stdio = .ignore,
    });
    try std.testing.expect(apply_result.receipt.isActive());
    try std.testing.expectEqual(sandbox.posture.BackendMechanism.landlock, apply_result.receipt.mechanism);
    try std.testing.expect(apply_result.receipt.profileHashSlice() != null);
    try std.testing.expectEqual(@as(usize, 64), apply_result.receipt.profileHashSlice().?.len);

    var status: c_int = 0;
    if (child.id) |pid| {
        waitpidRetry(pid, &status);
    }
    try std.testing.expect((status & 0x7f) == 0);
}
