//! Seatbelt real-FS deny and canary integration tests.
//! Imported from macos_seatbelt.zig so production apply code stays scannable.
//! Mirrors landlock_deny_tests.zig.

const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const canary = @import("canary.zig");
const macos_seatbelt = @import("macos_seatbelt.zig");

const sandboxInitAvailable = macos_seatbelt.sandboxInitAvailable;
const detectProductVersion = macos_seatbelt.detectProductVersion;
const isMatrixMajor = macos_seatbelt.isMatrixMajor;
const evaluateSupport = macos_seatbelt.evaluateSupport;
const prepareForChildApply = macos_seatbelt.prepareForChildApply;
const applyInChild = macos_seatbelt.applyInChild;
const SupportStatus = macos_seatbelt.SupportStatus;

fn waitExitCode(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    // Retry waitpid on EINTR. On other failure return error — do not invent exit 0
    // from the zero-initialized status when waitpid never reaped the child.
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (std.c.errno(rc) == .INTR) continue;
        return error.WaitpidFailed;
    }
    try std.testing.expect((status & 0x7f) == 0);
    return @intCast((status >> 8) & 0xff);
}

fn childExecNc(port_text: [*:0]const u8) noreturn {
    const argv = [_:null]?[*:0]const u8{
        "nc",
        "-z",
        "-G",
        "1",
        "127.0.0.1",
        port_text,
        null,
    };
    _ = std.c.execve("/usr/bin/nc", @ptrCast(&argv), @ptrCast(std.c.environ));
    std.c._exit(8);
}

// CTRL template: unsandboxed canary readable; sandboxed child denies outside grant,
// allows workspace neighbor read/write, and denies control-root write.
// Uses prepare SBPL + applyInChild.
// Exit codes from child: 0=ok, 2=apply fail, 3=outside readable (leak), 4=ws read fail,
// 5=ws write fail, 6=control root writable (leak).
test "real FS deny: outside canary denied; workspace readable and writable" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;

    const ver = try detectProductVersion();
    // Only claim matrix enforcement when this host major is in the advertised range.
    try std.testing.expect(isMatrixMajor(ver.major));
    try std.testing.expectEqual(SupportStatus.supported, evaluateSupport());

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    // Control root must exist under the workspace before apply so the write probe
    // targets a real path (profile always carves {workspace}/.orca).
    try ws_tmp.dir.createDirPath(io, ".orca");
    // realPath so Seatbelt grants match kernel paths (/private/var vs /var).
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_root = try out_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(out_root);

    var synth = try canary.generate(allocator);
    defer synth.deinit();

    // Outside canary (must NOT be under workspace grant).
    try out_tmp.dir.writeFile(io, .{ .sub_path = "canary.txt", .data = synth.body });
    const canary_path = try std.fs.path.join(allocator, &.{ out_root, "canary.txt" });
    defer allocator.free(canary_path);
    const canary_z = try allocator.dupeZ(u8, canary_path);
    defer allocator.free(canary_z);

    // Workspace neighbor (must remain readable/writable under grant).
    try ws_tmp.dir.writeFile(io, .{ .sub_path = "neighbor.txt", .data = "WORKSPACE_NEIGHBOR_OK" });
    const neighbor_path = try std.fs.path.join(allocator, &.{ ws_root, "neighbor.txt" });
    defer allocator.free(neighbor_path);
    const neighbor_z = try allocator.dupeZ(u8, neighbor_path);
    defer allocator.free(neighbor_z);

    const write_probe_path = try std.fs.path.join(allocator, &.{ ws_root, "write_probe.txt" });
    defer allocator.free(write_probe_path);
    const write_probe_z = try allocator.dupeZ(u8, write_probe_path);
    defer allocator.free(write_probe_z);

    const control_write_path = try std.fs.path.join(allocator, &.{ ws_root, ".orca", "policy.yaml" });
    defer allocator.free(control_write_path);
    const control_write_z = try allocator.dupeZ(u8, control_write_path);
    defer allocator.free(control_write_z);

    // CTRL-BASELINE: unsandboxed parent can read the outside canary.
    {
        const baseline = try std.Io.Dir.cwd().readFileAlloc(io, canary_path, allocator, .limited(4096));
        defer allocator.free(baseline);
        try std.testing.expectEqualStrings(synth.body, baseline);
    }
    // Neighbor also readable without sandbox.
    {
        const baseline_ws = try std.Io.Dir.cwd().readFileAlloc(io, neighbor_path, allocator, .limited(4096));
        defer allocator.free(baseline_ws);
        try std.testing.expectEqualStrings("WORKSPACE_NEIGHBOR_OK", baseline_ws);
    }

    // Prepare real product SBPL from compiled profile (not a hand-rolled minimal string).
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();
    // Outside path must not sit under the workspace grant.
    try std.testing.expect(!compiled.isAgentWritable(canary_path));
    try std.testing.expect(compiled.isAgentWritable(neighbor_path));
    // Control path under workspace must not be agent-writable (profile carves .orca).
    try std.testing.expect(!compiled.isAgentWritable(control_write_path));

    const prepared = prepareForChildApply(allocator, &compiled);
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    try std.testing.expect(prepared.sbpl_z != null);
    const sbpl_z = prepared.sbpl_z.?;

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);

        // TEST-DENY: outside canary must not be readable.
        const outside_fd = std.c.open(canary_z.ptr, .{ .ACCMODE = .RDONLY });
        if (outside_fd >= 0) {
            _ = std.c.close(outside_fd);
            std.c._exit(3); // leak — outside grant hole
        }

        // Workspace neighbor must still be readable.
        const ws_fd = std.c.open(neighbor_z.ptr, .{ .ACCMODE = .RDONLY });
        if (ws_fd < 0) std.c._exit(4);
        var buf: [64]u8 = undefined;
        const n = std.c.read(ws_fd, &buf, buf.len);
        _ = std.c.close(ws_fd);
        if (n < 0) std.c._exit(4);
        if (n != "WORKSPACE_NEIGHBOR_OK".len) std.c._exit(4);
        if (!std.mem.eql(u8, buf[0..@intCast(n)], "WORKSPACE_NEIGHBOR_OK")) std.c._exit(4);

        // Workspace write must succeed.
        const wfd = std.c.open(write_probe_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (wfd < 0) std.c._exit(5);
        const wrote = std.c.write(wfd, "wrote", 5);
        _ = std.c.close(wfd);
        if (wrote != 5) std.c._exit(5);

        // F-3: control root write must fail under live Seatbelt (not SBPL string only).
        const cfd = std.c.open(
            control_write_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (cfd >= 0) {
            _ = std.c.close(cfd);
            std.c._exit(6); // control write leak
        }

        std.c._exit(0);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const exited = (status & 0x7f) == 0;
    try std.testing.expect(exited);
    const exit_code: u8 = @intCast((status >> 8) & 0xff);
    // Surface distinct failures for the proof report (do not collapse to a single assert).
    switch (exit_code) {
        0 => {},
        2 => return error.SeatbeltApplyFailedOnHost,
        3 => return error.OutsideCanaryReadableUnderSandbox,
        4 => return error.WorkspaceNeighborUnreadableUnderSandbox,
        5 => return error.WorkspaceWriteFailedUnderSandbox,
        6 => return error.ControlRootWritableUnderSandbox,
        else => return error.UnexpectedSandboxChildExit,
    }
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    // Parent can still read the write probe produced by the sandboxed child.
    const probe = try std.Io.Dir.cwd().readFileAlloc(io, write_probe_path, allocator, .limited(64));
    defer allocator.free(probe);
    try std.testing.expectEqualStrings("wrote", probe);

    // Control file must not have been created by the sandboxed child.
    const ctrl_probe = std.Io.Dir.cwd().access(io, control_write_path, .{});
    try std.testing.expectError(error.FileNotFound, ctrl_probe);
}

test "real network route forcing: proxy port allowed and neighboring loopback port denied" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;
    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var allowed_server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer allowed_server.deinit(io);
    const allowed_port = allowed_server.socket.address.getPort();

    var denied_server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer denied_server.deinit(io);
    const denied_port = denied_server.socket.address.getPort();
    if (allowed_port == denied_port) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();

    const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
        allocator,
        &compiled,
        .supported,
        .{ .network_route_forcing = .{ .proxy_port = allowed_port } },
    );
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl_z = prepared.sbpl_z orelse return error.SeatbeltApplyFailedOnHost;

    const denied_pid = std.c.fork();
    if (denied_pid < 0) return error.SkipZigTest;
    if (denied_pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);
        var port_buf: [8]u8 = undefined;
        const port_text = std.fmt.bufPrintZ(&port_buf, "{d}", .{denied_port}) catch std.c._exit(7);
        childExecNc(port_text.ptr);
    }
    const denied_code = try waitExitCode(denied_pid);
    try std.testing.expect(denied_code != 0);
    try std.testing.expect(denied_code != 2);
    try std.testing.expect(denied_code != 8);

    const allowed_pid = std.c.fork();
    if (allowed_pid < 0) return error.SkipZigTest;
    if (allowed_pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);
        var port_buf: [8]u8 = undefined;
        const port_text = std.fmt.bufPrintZ(&port_buf, "{d}", .{allowed_port}) catch std.c._exit(7);
        childExecNc(port_text.ptr);
    }
    const allowed_code = try waitExitCode(allowed_pid);
    try std.testing.expectEqual(@as(u8, 0), allowed_code);
}

var data_scratch_seq: std.atomic.Value(u64) = .init(1);

/// Plant live R2-1 canaries on the home firmlink surface (content lives on the Data
/// volume). Prefer `$HOME/Library/Caches` — Seatbelt `subpath` filters match the
/// normalized `/Users/…` form, not `/System/Volumes/Data/…` path strings (live probe
/// on macOS 14–26: Data-form subpath grants never open; Users-form grants do).
/// Returns owned scratch path or null when no writable home surface exists.
fn tryHomeFirmlinkScratchBase(allocator: std.mem.Allocator, io: anytype) ?[]u8 {
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    if (home.len < 2 or home[0] != '/') return null;

    const caches = std.fmt.allocPrint(allocator, "{s}/Library/Caches", .{home}) catch return null;
    defer allocator.free(caches);
    std.Io.Dir.cwd().access(io, caches, .{}) catch return null;

    const seq = data_scratch_seq.fetchAdd(1, .monotonic);
    const scratch = std.fmt.allocPrint(allocator, "{s}/orca-sb-data-{d}-{d}", .{
        caches,
        std.c.getpid(),
        seq,
    }) catch return null;
    std.Io.Dir.cwd().createDirPath(io, scratch) catch {
        allocator.free(scratch);
        return null;
    };
    return scratch;
}

/// When `users_path` is under `/Users/…`, return owned `/System/Volumes/Data` + path.
/// Null when not a Users-form path (caller skips Data-form dual open).
fn dataFormPath(allocator: std.mem.Allocator, users_path: []const u8) ?[]u8 {
    if (!profile.isPathWithin(users_path, "/Users") and !std.mem.eql(u8, users_path, "/Users")) {
        return null;
    }
    return std.fmt.allocPrint(allocator, "/System/Volumes/Data{s}", .{users_path}) catch null;
}

// R3-2: live-ish Seatbelt canary for R2-1 home/Data firmlink composition.
//
// Seatbelt path filters evaluate the *normalized* `/Users/…` form. Planting the
// workspace grant as a Data-form string (`/System/Volumes/Data/Users/…`) fails open
// even without a Data deny. Strongest feasible live proof on matrix hosts:
//   1. workspace + sibling on $HOME caches (Data firmlink content; Users-form paths)
//   2. product SBPL still emits Data deny (composition present)
//   3. sibling denied via Users-form open and via explicit Data-form open
//   4. workspace neighbor readable + writable
// Pure/SBPL last-match keepers above still prove Data-form string order for hosts
// whose realpath returns Data-form paths.
// Exit: 0=ok, 2=apply fail, 3=sibling readable, 4=ws read fail, 5=ws write fail,
//       7=Data-form sibling readable.
test "real FS deny: Data-volume sibling secret denied; workspace RW (R2-1)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;

    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));
    try std.testing.expectEqual(SupportStatus.supported, evaluateSupport());

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Prefer home firmlink surface. Skip when $HOME caches unavailable (rare CI).
    const scratch = tryHomeFirmlinkScratchBase(allocator, io) orelse return error.SkipZigTest;
    defer {
        std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
        allocator.free(scratch);
    }

    const ws_rel = try std.fs.path.join(allocator, &.{ scratch, "workspace" });
    defer allocator.free(ws_rel);
    const sibling_rel = try std.fs.path.join(allocator, &.{ scratch, "sibling" });
    defer allocator.free(sibling_rel);

    try std.Io.Dir.cwd().createDirPath(io, ws_rel);
    try std.Io.Dir.cwd().createDirPath(io, sibling_rel);

    const ws_root = try std.Io.Dir.realPathFileAbsoluteAlloc(io, ws_rel, allocator);
    defer allocator.free(ws_root);

    var synth = try canary.generate(allocator);
    defer synth.deinit();

    const secret_path = try std.fs.path.join(allocator, &.{ sibling_rel, "secret.txt" });
    defer allocator.free(secret_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = secret_path, .data = synth.body });
    const secret_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, secret_path, allocator);
    defer allocator.free(secret_real);
    const secret_z = try allocator.dupeZ(u8, secret_real);
    defer allocator.free(secret_z);

    // Dual open: explicit Data-form path to the same vnode (when under /Users).
    const secret_data_owned = dataFormPath(allocator, secret_real);
    defer if (secret_data_owned) |p| allocator.free(p);
    const secret_data_z: ?[:0]u8 = if (secret_data_owned) |p| try allocator.dupeZ(u8, p) else null;
    defer if (secret_data_z) |p| allocator.free(p);

    const neighbor_path = try std.fs.path.join(allocator, &.{ ws_root, "neighbor.txt" });
    defer allocator.free(neighbor_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = neighbor_path, .data = "DATA_WS_NEIGHBOR_OK" });
    const neighbor_z = try allocator.dupeZ(u8, neighbor_path);
    defer allocator.free(neighbor_z);

    const write_probe_path = try std.fs.path.join(allocator, &.{ ws_root, "write_probe.txt" });
    defer allocator.free(write_probe_path);
    const write_probe_z = try allocator.dupeZ(u8, write_probe_path);
    defer allocator.free(write_probe_z);

    // CTRL-BASELINE: unsandboxed parent can read the sibling secret (both forms).
    {
        const baseline = try std.Io.Dir.cwd().readFileAlloc(io, secret_real, allocator, .limited(4096));
        defer allocator.free(baseline);
        try std.testing.expectEqualStrings(synth.body, baseline);
    }
    if (secret_data_owned) |dp| {
        const baseline_d = try std.Io.Dir.cwd().readFileAlloc(io, dp, allocator, .limited(4096));
        defer allocator.free(baseline_d);
        try std.testing.expectEqualStrings(synth.body, baseline_d);
    }

    // No production temp grants — sibling must not ride `/private/tmp` RW.
    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .system_ro_prefixes = profile.defaultSystemRoPrefixes(),
        .include_tmp = false,
    });
    defer compiled.deinit();
    try std.testing.expect(compiled.isAgentWritable(neighbor_path));
    try std.testing.expect(!compiled.isGrantedReadable(secret_real));
    try std.testing.expect(!compiled.isAgentWritable(secret_real));

    const prepared = prepareForChildApply(allocator, &compiled);
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl = prepared.sbpl_z.?;
    // Product SBPL always emits Data deny (R2-1 composition), even when workspace
    // realpath is Users-form (re-allow only appears when a grant sits under Data).
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "(deny file-read* (subpath \"/System/Volumes/Data\"))") != null);

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl.ptr) catch std.c._exit(2);

        // Sibling outside workspace must not be readable (Users-form open).
        const sfd = std.c.open(secret_z.ptr, .{ .ACCMODE = .RDONLY });
        if (sfd >= 0) {
            _ = std.c.close(sfd);
            std.c._exit(3);
        }

        // Explicit Data-form open of the same secret must also fail.
        if (secret_data_z) |dz| {
            const dfd = std.c.open(dz.ptr, .{ .ACCMODE = .RDONLY });
            if (dfd >= 0) {
                _ = std.c.close(dfd);
                std.c._exit(7);
            }
        }

        const nfd = std.c.open(neighbor_z.ptr, .{ .ACCMODE = .RDONLY });
        if (nfd < 0) std.c._exit(4);
        var buf: [64]u8 = undefined;
        const n = std.c.read(nfd, &buf, buf.len);
        _ = std.c.close(nfd);
        if (n != "DATA_WS_NEIGHBOR_OK".len) std.c._exit(4);
        if (!std.mem.eql(u8, buf[0..@intCast(n)], "DATA_WS_NEIGHBOR_OK")) std.c._exit(4);

        const wfd = std.c.open(write_probe_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (wfd < 0) std.c._exit(5);
        const wrote = std.c.write(wfd, "data-ok", 7);
        _ = std.c.close(wfd);
        if (wrote != 7) std.c._exit(5);

        std.c._exit(0);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const exited = (status & 0x7f) == 0;
    try std.testing.expect(exited);
    const exit_code: u8 = @intCast((status >> 8) & 0xff);
    switch (exit_code) {
        0 => {},
        2 => return error.SeatbeltApplyFailedOnHost,
        3 => return error.DataVolumeSiblingReadableUnderSandbox,
        4 => return error.DataVolumeWorkspaceUnreadableUnderSandbox,
        5 => return error.DataVolumeWorkspaceWriteFailedUnderSandbox,
        7 => return error.DataFormSiblingReadableUnderSandbox,
        else => return error.UnexpectedSandboxChildExit,
    }

    const probe = try std.Io.Dir.cwd().readFileAlloc(io, write_probe_path, allocator, .limited(64));
    defer allocator.free(probe);
    try std.testing.expectEqualStrings("data-ok", probe);
}

// Planted workspace symlink to an outside path must not make outside content
// readable under real Seatbelt apply (path policy follows final target).
// Exit: 0=ok, 2=apply fail, 3=outside direct readable, 4=neighbor fail, 9=symlink escape.
test "real FS deny: workspace symlink to outside is not readable" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;

    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));
    try std.testing.expectEqual(SupportStatus.supported, evaluateSupport());

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");
    try ws_tmp.dir.writeFile(io, .{ .sub_path = "neighbor.txt", .data = "NEIGHBOR" });
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    var synth = try canary.generate(allocator);
    defer synth.deinit();
    try out_tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = synth.body });
    const out_root = try out_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(out_root);

    const secret_path = try std.fs.path.join(allocator, &.{ out_root, "secret.txt" });
    defer allocator.free(secret_path);
    const link_path = try std.fs.path.join(allocator, &.{ ws_root, "escape_link" });
    defer allocator.free(link_path);

    std.Io.Dir.cwd().symLink(io, secret_path, link_path, .{}) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const neighbor_path = try std.fs.path.join(allocator, &.{ ws_root, "neighbor.txt" });
    defer allocator.free(neighbor_path);

    // CTRL-BASELINE: unsandboxed parent can read outside via the planted symlink.
    {
        const via_link = try std.Io.Dir.cwd().readFileAlloc(io, link_path, allocator, .limited(4096));
        defer allocator.free(via_link);
        try std.testing.expectEqualStrings(synth.body, via_link);
    }

    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();
    try std.testing.expect(!compiled.isGrantedReadable(secret_path));
    try std.testing.expect(compiled.isGrantedReadable(neighbor_path));

    const prepared = prepareForChildApply(allocator, &compiled);
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl_z = prepared.sbpl_z.?;

    const secret_z = try allocator.dupeZ(u8, secret_path);
    defer allocator.free(secret_z);
    const link_z = try allocator.dupeZ(u8, link_path);
    defer allocator.free(link_z);
    const neighbor_z = try allocator.dupeZ(u8, neighbor_path);
    defer allocator.free(neighbor_z);

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);

        // Outside real path must not be readable.
        const out_fd = std.c.open(secret_z.ptr, .{ .ACCMODE = .RDONLY });
        if (out_fd >= 0) {
            _ = std.c.close(out_fd);
            std.c._exit(3);
        }

        // Via workspace symlink: outside content must still be denied.
        const link_fd = std.c.open(link_z.ptr, .{ .ACCMODE = .RDONLY });
        if (link_fd >= 0) {
            _ = std.c.close(link_fd);
            std.c._exit(9);
        }

        const nfd = std.c.open(neighbor_z.ptr, .{ .ACCMODE = .RDONLY });
        if (nfd < 0) std.c._exit(4);
        var buf: [16]u8 = undefined;
        const n = std.c.read(nfd, &buf, buf.len);
        _ = std.c.close(nfd);
        if (n != "NEIGHBOR".len) std.c._exit(4);
        if (!std.mem.eql(u8, buf[0..@intCast(n)], "NEIGHBOR")) std.c._exit(4);

        std.c._exit(0);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const exited = (status & 0x7f) == 0;
    try std.testing.expect(exited);
    const exit_code: u8 = @intCast((status >> 8) & 0xff);
    switch (exit_code) {
        0 => {},
        2 => return error.SeatbeltApplyFailedOnHost,
        3 => return error.OutsideCanaryReadableUnderSandbox,
        4 => return error.WorkspaceNeighborUnreadableUnderSandbox,
        9 => return error.SymlinkEscapeReadableUnderSandbox,
        else => return error.UnexpectedSandboxProbeExit,
    }
}

test "hardened profile: shell fork+exec works under attach" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;
    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));

    const allocator = std.testing.allocator;
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(std.testing.io, ".orca");
    const ws_root = try ws_tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(ws_root);

    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();

    const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
        allocator,
        &compiled,
        .supported,
        .{ .profile_grade = .hardened },
    );
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl_z = prepared.sbpl_z orelse return error.SeatbeltApplyFailedOnHost;
    try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow process*)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow process-fork)") != null);

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "/bin/echo hardened_ok", null };
        _ = std.c.execve("/bin/sh", @ptrCast(&argv), @ptrCast(std.c.environ));
        std.c._exit(8);
    }
    const code = try waitExitCode(pid);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "strict route-force: outbound proxy allowed; bind/listen denied" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;
    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var allowed_server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer allowed_server.deinit(io);
    const allowed_port = allowed_server.socket.address.getPort();

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();

    const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
        allocator,
        &compiled,
        .supported,
        .{
            .network_route_forcing = .{ .proxy_port = allowed_port },
            .profile_grade = .strict,
        },
    );
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl_z = prepared.sbpl_z orelse return error.SeatbeltApplyFailedOnHost;
    try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow network-inbound)") == null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow network-bind)") == null);

    // Outbound to proxy port still allowed.
    const allow_pid = std.c.fork();
    if (allow_pid < 0) return error.SkipZigTest;
    if (allow_pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);
        var port_buf: [8]u8 = undefined;
        const port_text = std.fmt.bufPrintZ(&port_buf, "{d}", .{allowed_port}) catch std.c._exit(7);
        childExecNc(port_text.ptr);
    }
    const allow_code = try waitExitCode(allow_pid);
    try std.testing.expectEqual(@as(u8, 0), allow_code);

    // Bind/listen denied under strict route-force.
    const bind_pid = std.c.fork();
    if (bind_pid < 0) return error.SkipZigTest;
    if (bind_pid == 0) {
        applyInChild(sbpl_z.ptr) catch std.c._exit(2);
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) std.c._exit(3);
        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
            .zero = [_]u8{0} ** 8,
        };
        const rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
        if (rc == 0) std.c._exit(0); // bind succeeded = fail the canary
        std.c._exit(1); // expected: bind denied
    }
    const bind_code = try waitExitCode(bind_pid);
    try std.testing.expectEqual(@as(u8, 1), bind_code);
}

// M-5: hardened bootstrap FS residual — no literal `/private/var` grant; live open must deny.
// Compatible control proves the same path is readable under the historical residual.
test "hardened profile: open /private/var denied; compatible allows" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;
    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));

    const allocator = std.testing.allocator;
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(std.testing.io, ".orca");
    const ws_root = try ws_tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(ws_root);

    var compiled = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
    });
    defer compiled.deinit();

    // Hardened: open of `/private/var` (literal residual removed) must fail after apply.
    {
        const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
            allocator,
            &compiled,
            .supported,
            .{ .profile_grade = .hardened },
        );
        defer if (prepared.sbpl_z) |p| allocator.free(p);
        try std.testing.expectEqual(.prepared, prepared.status);
        const sbpl_z = prepared.sbpl_z orelse return error.SeatbeltApplyFailedOnHost;
        try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow file-read* (literal \"/private/var\"))") == null);

        const pid = std.c.fork();
        if (pid < 0) return error.SkipZigTest;
        if (pid == 0) {
            applyInChild(sbpl_z.ptr) catch std.c._exit(2);
            const fd = std.c.open("/private/var", .{ .ACCMODE = .RDONLY });
            if (fd >= 0) {
                _ = std.c.close(fd);
                std.c._exit(0); // open succeeded = residual still broad
            }
            std.c._exit(1); // expected deny
        }
        const code = try waitExitCode(pid);
        try std.testing.expectEqual(@as(u8, 1), code);
    }

    // Compatible control: same open succeeds under historical residual.
    {
        const prepared = macos_seatbelt.prepareForChildApplyWithOptions(
            allocator,
            &compiled,
            .supported,
            .{ .profile_grade = .compatible },
        );
        defer if (prepared.sbpl_z) |p| allocator.free(p);
        try std.testing.expectEqual(.prepared, prepared.status);
        const sbpl_z = prepared.sbpl_z orelse return error.SeatbeltApplyFailedOnHost;
        try std.testing.expect(std.mem.indexOf(u8, sbpl_z, "(allow file-read* (literal \"/private/var\"))") != null);

        const pid = std.c.fork();
        if (pid < 0) return error.SkipZigTest;
        if (pid == 0) {
            applyInChild(sbpl_z.ptr) catch std.c._exit(2);
            const fd = std.c.open("/private/var", .{ .ACCMODE = .RDONLY });
            if (fd >= 0) {
                _ = std.c.close(fd);
                std.c._exit(0);
            }
            std.c._exit(1);
        }
        const code = try waitExitCode(pid);
        try std.testing.expectEqual(@as(u8, 0), code);
    }
}


// Phase 1d / P1-5: workspace secret-form deny under protect_workspace_secrets.
// Edge cases exercised under live Seatbelt:
//   - `.env` canary content never returned (open fails; no partial read)
//   - nested `.env.local` denied
//   - `.env.example.local` denied (not an exact safe template)
//   - exact templates `.env.example` / `.env.sample` / `.env.template` readable
//   - ordinary workspace file remains RW
//   - write create of new `.env` denied
//   - protect-off control SBPL still allows `.env` read (negative control)
// Exit: 0=ok, 2=apply fail, 3=.env readable, 4=template fail, 5=ordinary fail,
//       6=.env.local readable, 7=.env.example.local readable, 8=write to .env ok (leak),
//       10=ordinary write fail, 11=canary body leaked via any open buffer.
test "real FS deny: workspace .env secret forms denied under protect; templates and ordinary remain" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;

    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));
    try std.testing.expectEqual(SupportStatus.supported, evaluateSupport());

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");
    try ws_tmp.dir.createDirPath(io, "nested");

    var synth = try canary.generate(allocator);
    defer synth.deinit();

    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = synth.body });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = "nested/.env.local", .data = synth.body });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env.example.local", .data = synth.body });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env.example", .data = "template-ok" });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env.sample", .data = "sample-ok" });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env.template", .data = "template-file-ok" });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "ordinary-ok" });

    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    const env_path = try std.fs.path.join(allocator, &.{ ws_root, ".env" });
    defer allocator.free(env_path);
    const env_local_path = try std.fs.path.join(allocator, &.{ ws_root, "nested", ".env.local" });
    defer allocator.free(env_local_path);
    const env_example_local_path = try std.fs.path.join(allocator, &.{ ws_root, ".env.example.local" });
    defer allocator.free(env_example_local_path);
    const env_example_path = try std.fs.path.join(allocator, &.{ ws_root, ".env.example" });
    defer allocator.free(env_example_path);
    const env_sample_path = try std.fs.path.join(allocator, &.{ ws_root, ".env.sample" });
    defer allocator.free(env_sample_path);
    const env_template_path = try std.fs.path.join(allocator, &.{ ws_root, ".env.template" });
    defer allocator.free(env_template_path);
    const readme_path = try std.fs.path.join(allocator, &.{ ws_root, "readme.txt" });
    defer allocator.free(readme_path);
    const write_env_path = try std.fs.path.join(allocator, &.{ ws_root, ".env.created_by_probe" });
    defer allocator.free(write_env_path);
    const write_ordinary_path = try std.fs.path.join(allocator, &.{ ws_root, "write_probe.txt" });
    defer allocator.free(write_ordinary_path);

    // CTRL-BASELINE: unsandboxed parent can still read the canary.
    {
        const baseline = try std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, .limited(4096));
        defer allocator.free(baseline);
        try std.testing.expectEqualStrings(synth.body, baseline);
        try std.testing.expect(canary.bodyLeaked(synth, baseline));
    }

    // Negative control: protect-off product SBPL must still allow workspace `.env` open.
    {
        var unprotected = try profile.compileProfile(allocator, .{
            .workspace_root = ws_root,
            .include_tmp = false,
            .protect_workspace_secrets = false,
        });
        defer unprotected.deinit();
        const prepared_off = prepareForChildApply(allocator, &unprotected);
        defer if (prepared_off.sbpl_z) |p| allocator.free(p);
        try std.testing.expectEqual(.prepared, prepared_off.status);
        const sbpl_off = prepared_off.sbpl_z.?;

        const env_z_off = try allocator.dupeZ(u8, env_path);
        defer allocator.free(env_z_off);

        const pid_off = std.c.fork();
        if (pid_off < 0) return error.SkipZigTest;
        if (pid_off == 0) {
            applyInChild(sbpl_off.ptr) catch std.c._exit(2);
            const fd = std.c.open(env_z_off.ptr, .{ .ACCMODE = .RDONLY });
            if (fd < 0) std.c._exit(3);
            var buf: [256]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            _ = std.c.close(fd);
            if (n <= 0) std.c._exit(3);
            if (std.mem.indexOf(u8, buf[0..@intCast(n)], synth.body) == null) std.c._exit(3);
            std.c._exit(0);
        }
        const code_off = try waitExitCode(pid_off);
        switch (code_off) {
            0 => {},
            2 => return error.SeatbeltApplyFailedOnHost,
            3 => return error.ProtectOffControlCouldNotReadEnv,
            else => return error.UnexpectedSandboxChildExit,
        }
    }

    var protected = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
        .protect_workspace_secrets = true,
    });
    defer protected.deinit();
    try std.testing.expect(protected.protect_workspace_secrets);

    const prepared = prepareForChildApply(allocator, &protected);
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl = prepared.sbpl_z.?;
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "workspace env secret carve-out") != null);

    const env_z = try allocator.dupeZ(u8, env_path);
    defer allocator.free(env_z);
    const env_local_z = try allocator.dupeZ(u8, env_local_path);
    defer allocator.free(env_local_z);
    const env_example_local_z = try allocator.dupeZ(u8, env_example_local_path);
    defer allocator.free(env_example_local_z);
    const env_example_z = try allocator.dupeZ(u8, env_example_path);
    defer allocator.free(env_example_z);
    const env_sample_z = try allocator.dupeZ(u8, env_sample_path);
    defer allocator.free(env_sample_z);
    const env_template_z = try allocator.dupeZ(u8, env_template_path);
    defer allocator.free(env_template_z);
    const readme_z = try allocator.dupeZ(u8, readme_path);
    defer allocator.free(readme_z);
    const write_env_z = try allocator.dupeZ(u8, write_env_path);
    defer allocator.free(write_env_z);
    const write_ordinary_z = try allocator.dupeZ(u8, write_ordinary_path);
    defer allocator.free(write_ordinary_z);

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl.ptr) catch std.c._exit(2);

        // Denied secret forms must not open (and must never return canary bytes).
        const env_fd = std.c.open(env_z.ptr, .{ .ACCMODE = .RDONLY });
        if (env_fd >= 0) {
            var leak_buf: [256]u8 = undefined;
            const n = std.c.read(env_fd, &leak_buf, leak_buf.len);
            _ = std.c.close(env_fd);
            if (n > 0 and std.mem.indexOf(u8, leak_buf[0..@intCast(n)], synth.body) != null) {
                std.c._exit(11);
            }
            std.c._exit(3);
        }

        const local_fd = std.c.open(env_local_z.ptr, .{ .ACCMODE = .RDONLY });
        if (local_fd >= 0) {
            var leak_buf: [256]u8 = undefined;
            const n = std.c.read(local_fd, &leak_buf, leak_buf.len);
            _ = std.c.close(local_fd);
            if (n > 0 and std.mem.indexOf(u8, leak_buf[0..@intCast(n)], synth.body) != null) {
                std.c._exit(11);
            }
            std.c._exit(6);
        }

        const ex_local_fd = std.c.open(env_example_local_z.ptr, .{ .ACCMODE = .RDONLY });
        if (ex_local_fd >= 0) {
            var leak_buf: [256]u8 = undefined;
            const n = std.c.read(ex_local_fd, &leak_buf, leak_buf.len);
            _ = std.c.close(ex_local_fd);
            if (n > 0 and std.mem.indexOf(u8, leak_buf[0..@intCast(n)], synth.body) != null) {
                std.c._exit(11);
            }
            std.c._exit(7);
        }

        // Exact safe templates remain readable.
        if (!childReadEquals(env_example_z.ptr, "template-ok")) std.c._exit(4);
        if (!childReadEquals(env_sample_z.ptr, "sample-ok")) std.c._exit(4);
        if (!childReadEquals(env_template_z.ptr, "template-file-ok")) std.c._exit(4);

        // Ordinary workspace file remains readable.
        if (!childReadEquals(readme_z.ptr, "ordinary-ok")) std.c._exit(5);

        // Ordinary write remains allowed.
        const wfd = std.c.open(
            write_ordinary_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (wfd < 0) std.c._exit(10);
        const wrote = std.c.write(wfd, "wrote-ok", 8);
        _ = std.c.close(wfd);
        if (wrote != 8) std.c._exit(10);

        // Creating a new secret-form file under the workspace must fail.
        const sfd = std.c.open(
            write_env_z.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o600),
        );
        if (sfd >= 0) {
            _ = std.c.close(sfd);
            std.c._exit(8);
        }

        std.c._exit(0);
    }

    const exit_code = try waitExitCode(pid);
    switch (exit_code) {
        0 => {},
        2 => return error.SeatbeltApplyFailedOnHost,
        3 => return error.WorkspaceEnvReadableUnderProtect,
        4 => return error.WorkspaceEnvTemplateUnreadableUnderProtect,
        5 => return error.OrdinaryWorkspaceFileUnreadableUnderProtect,
        6 => return error.NestedEnvLocalReadableUnderProtect,
        7 => return error.EnvExampleLocalReadableUnderProtect,
        8 => return error.WorkspaceEnvWriteAllowedUnderProtect,
        10 => return error.OrdinaryWorkspaceWriteFailedUnderProtect,
        11 => return error.CanaryBodyLeakedUnderProtect,
        else => return error.UnexpectedSandboxChildExit,
    }

    const probe = try std.Io.Dir.cwd().readFileAlloc(io, write_ordinary_path, allocator, .limited(64));
    defer allocator.free(probe);
    try std.testing.expectEqualStrings("wrote-ok", probe);

    // Parent still holds the real canary; sandboxed child never returned it.
    const still = try std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, .limited(4096));
    defer allocator.free(still);
    try std.testing.expect(canary.bodyLeaked(synth, still));
}

fn childReadEquals(path_z: [*:0]const u8, expected: []const u8) bool {
    if (expected.len > 128) return false;
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    var buf: [128]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    _ = std.c.close(fd);
    if (n < 0) return false;
    if (@as(usize, @intCast(n)) != expected.len) return false;
    return std.mem.eql(u8, buf[0..@intCast(n)], expected);
}

// Pre-planted hardlink to a secret-form inode must not return canary content under
// protect-on. Path-regex alone misses non-.env basenames; prepare-time scan emits
// last-match path denies for those aliases. Exit: 0=ok, 2=apply, 3=alias readable,
// 4=canary leak, 5=neighbor fail.
//
// When prepare fails closed (e.g. scan open error), this test fails at prepare —
// never observes canary body. Companion unit tests cover mode-000 ScanOpenFailed.


// Pre-planted hardlink to a secret-form inode must not return canary content under
// protect-on. Path-regex alone misses non-.env basenames; prepare-time scan emits
// last-match path denies for those aliases. Exit: 0=ok, 2=apply, 3=alias readable,
// 4=canary leak, 5=neighbor fail.
//
// When prepare fails closed (e.g. scan open error), this test fails at prepare —
// never observes canary body. Companion unit tests cover mode-000 ScanOpenFailed.
test "real FS deny: hardlink alias of workspace .env denied under protect" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxInitAvailable()) return error.SkipZigTest;

    const ver = try detectProductVersion();
    try std.testing.expect(isMatrixMajor(ver.major));
    try std.testing.expectEqual(SupportStatus.supported, evaluateSupport());

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.createDirPath(io, ".orca");

    var synth = try canary.generate(allocator);
    defer synth.deinit();
    try ws_tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = synth.body });
    try ws_tmp.dir.writeFile(io, .{ .sub_path = "neighbor.txt", .data = "neighbor-ok" });

    // Pre-plant hardlink with a non-secret basename (path-regex alone would miss it).
    ws_tmp.dir.hardLink(".env", ws_tmp.dir, "notes.txt", io, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.SkipZigTest,
    };

    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(ws_root);

    const alias_path = try std.fs.path.join(allocator, &.{ ws_root, "notes.txt" });
    defer allocator.free(alias_path);
    const neighbor_path = try std.fs.path.join(allocator, &.{ ws_root, "neighbor.txt" });
    defer allocator.free(neighbor_path);

    // CTRL-BASELINE: unsandboxed parent can read the alias (same inode as .env).
    {
        const baseline = try std.Io.Dir.cwd().readFileAlloc(io, alias_path, allocator, .limited(4096));
        defer allocator.free(baseline);
        try std.testing.expectEqualStrings(synth.body, baseline);
    }

    var protected = try profile.compileProfile(allocator, .{
        .workspace_root = ws_root,
        .include_tmp = false,
        .protect_workspace_secrets = true,
    });
    defer protected.deinit();

    const prepared = prepareForChildApply(allocator, &protected);
    defer if (prepared.sbpl_z) |p| allocator.free(p);
    try std.testing.expectEqual(.prepared, prepared.status);
    const sbpl = prepared.sbpl_z.?;
    // Prepare scan must emit an explicit deny for the alias path.
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "multi-nlink non-secret basenames") != null);
    try std.testing.expect(std.mem.indexOf(u8, sbpl, "notes.txt") != null);

    const alias_z = try allocator.dupeZ(u8, alias_path);
    defer allocator.free(alias_z);
    const neighbor_z = try allocator.dupeZ(u8, neighbor_path);
    defer allocator.free(neighbor_z);

    const pid = std.c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyInChild(sbpl.ptr) catch std.c._exit(2);

        const afd = std.c.open(alias_z.ptr, .{ .ACCMODE = .RDONLY });
        if (afd >= 0) {
            var buf: [256]u8 = undefined;
            const n = std.c.read(afd, &buf, buf.len);
            _ = std.c.close(afd);
            if (n > 0 and std.mem.indexOf(u8, buf[0..@intCast(n)], synth.body) != null) {
                std.c._exit(4);
            }
            std.c._exit(3);
        }

        if (!childReadEquals(neighbor_z.ptr, "neighbor-ok")) std.c._exit(5);
        std.c._exit(0);
    }

    const exit_code = try waitExitCode(pid);
    switch (exit_code) {
        0 => {},
        2 => return error.SeatbeltApplyFailedOnHost,
        3 => return error.HardlinkAliasReadableUnderProtect,
        4 => return error.CanaryBodyLeakedViaHardlinkAlias,
        5 => return error.OrdinaryNeighborUnreadableUnderProtect,
        else => return error.UnexpectedSandboxChildExit,
    }
}
