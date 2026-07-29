//! Irreversible Linux capability lockdown for the single-threaded workspace
//! bootstrap and its post-fork FUSE daemon. Every mutation and postcondition is
//! fail-closed; callers must terminate the process on any returned error.

const std = @import("std");
const builtin = @import("builtin");

/// Linux capability ABI v3 has two 32-bit words. Reject kernels that expose a
/// wider range rather than silently leaving a future capability untouched.
pub const max_supported_capability: u32 = 63;

const secure_no_root: u32 = 1 << 0;
const secure_no_root_locked: u32 = 1 << 1;
const secure_no_setuid_fixup: u32 = 1 << 2;
const secure_no_setuid_fixup_locked: u32 = 1 << 3;
const secure_keep_caps: u32 = 1 << 4;
const secure_keep_caps_locked: u32 = 1 << 5;
const secure_no_ambient_raise: u32 = 1 << 6;
const secure_no_ambient_raise_locked: u32 = 1 << 7;

/// NOROOT, NO_SETUID_FIXUP, and NO_CAP_AMBIENT_RAISE are enabled and locked.
/// KEEP_CAPS is disabled (bit 4 clear) and locked (bit 5 set).
pub const required_secure_bits: u32 =
    secure_no_root |
    secure_no_root_locked |
    secure_no_setuid_fixup |
    secure_no_setuid_fixup_locked |
    secure_keep_caps_locked |
    secure_no_ambient_raise |
    secure_no_ambient_raise_locked;

pub const LockdownError = error{
    Unsupported,
    NoNewPrivilegesFailed,
    AmbientClearFailed,
    SecureBitsFailed,
    CapabilityRangeFailed,
    CapabilityRangeTooLarge,
    BoundingDropFailed,
    CapabilitySetFailed,
    NoNewPrivilegesVerificationFailed,
    AmbientVerificationFailed,
    SecureBitsVerificationFailed,
    BoundingVerificationFailed,
    CapabilitySetVerificationFailed,
};

const CapabilityHeader = extern struct {
    version: u32,
    pid: i32,
};

const CapabilityData = extern struct {
    effective: u32,
    permitted: u32,
    inheritable: u32,
};

/// Lock down the current Linux task. The bootstrap and FUSE daemon must call
/// this while single-threaded; Linux credentials and capabilities are
/// per-thread even though they are inherited across fork/exec.
pub fn lockdownCurrentProcess() LockdownError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var ops: LinuxOps = .{};
    return lockdownWithOps(&ops);
}

/// Injectable state machine used by the production Linux adapter and portable
/// tests. The ops contract is intentionally concrete: one operation per
/// irreversible step or independently verified postcondition.
pub fn lockdownWithOps(ops: anytype) LockdownError!void {
    ops.setNoNewPrivileges() catch return error.NoNewPrivilegesFailed;
    ops.clearAmbientCapabilities() catch return error.AmbientClearFailed;
    ops.setSecureBits(required_secure_bits) catch return error.SecureBitsFailed;

    const last_capability = ops.getLastCapability() catch return error.CapabilityRangeFailed;
    if (last_capability > max_supported_capability) return error.CapabilityRangeTooLarge;

    var capability: u32 = 0;
    while (capability <= last_capability) : (capability += 1) {
        ops.dropBoundingCapability(capability) catch return error.BoundingDropFailed;
    }

    ops.zeroCapabilitySets() catch return error.CapabilitySetFailed;

    const no_new_privileges = ops.hasNoNewPrivileges() catch
        return error.NoNewPrivilegesVerificationFailed;
    if (!no_new_privileges) return error.NoNewPrivilegesVerificationFailed;

    capability = 0;
    while (capability <= last_capability) : (capability += 1) {
        const ambient_set = ops.isAmbientCapabilitySet(capability) catch
            return error.AmbientVerificationFailed;
        if (ambient_set) return error.AmbientVerificationFailed;
    }

    const secure_bits = ops.getSecureBits() catch return error.SecureBitsVerificationFailed;
    const keep_caps = ops.getKeepCaps() catch return error.SecureBitsVerificationFailed;
    if (!secureBitsAreLocked(secure_bits) or keep_caps) return error.SecureBitsVerificationFailed;

    capability = 0;
    while (capability <= last_capability) : (capability += 1) {
        const bounding_set = ops.isBoundingCapabilitySet(capability) catch
            return error.BoundingVerificationFailed;
        if (bounding_set) return error.BoundingVerificationFailed;
    }

    const capability_sets_zero = ops.areCapabilitySetsZero() catch
        return error.CapabilitySetVerificationFailed;
    if (!capability_sets_zero) return error.CapabilitySetVerificationFailed;
}

fn secureBitsAreLocked(bits: u32) bool {
    return bits & required_secure_bits == required_secure_bits and
        bits & secure_keep_caps == 0;
}

const LinuxOps = struct {
    const OperationError = error{OperationFailed};
    const capability_version_3: u32 = 0x20080522;

    fn setNoNewPrivileges(_: *LinuxOps) OperationError!void {
        _ = try prctl(.SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    }

    fn clearAmbientCapabilities(_: *LinuxOps) OperationError!void {
        const linux = std.os.linux;
        _ = try prctl(.CAP_AMBIENT, linux.PR.CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
    }

    fn setSecureBits(_: *LinuxOps, bits: u32) OperationError!void {
        _ = try prctl(.SET_SECUREBITS, bits, 0, 0, 0);
    }

    fn getLastCapability(_: *LinuxOps) OperationError!u32 {
        const linux = std.os.linux;
        var capability: u32 = 0;
        while (capability <= max_supported_capability + 1) : (capability += 1) {
            const rc = linux.prctl(@intFromEnum(linux.PR.CAPBSET_READ), capability, 0, 0, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc > 1) return error.OperationFailed;
                    if (capability > max_supported_capability) return capability;
                },
                .INVAL => {
                    if (capability == 0) return error.OperationFailed;
                    return capability - 1;
                },
                else => return error.OperationFailed,
            }
        }
        return max_supported_capability + 1;
    }

    fn dropBoundingCapability(_: *LinuxOps, capability: u32) OperationError!void {
        _ = try prctl(.CAPBSET_DROP, capability, 0, 0, 0);
    }

    fn zeroCapabilitySets(_: *LinuxOps) OperationError!void {
        const linux = std.os.linux;
        var header: CapabilityHeader = .{ .version = capability_version_3, .pid = 0 };
        var data = [_]CapabilityData{
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        };
        const rc = linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&data[0]));
        if (linux.errno(rc) != .SUCCESS) return error.OperationFailed;
    }

    fn hasNoNewPrivileges(_: *LinuxOps) OperationError!bool {
        const rc = try prctl(.GET_NO_NEW_PRIVS, 0, 0, 0, 0);
        if (rc > 1) return error.OperationFailed;
        return rc == 1;
    }

    fn isAmbientCapabilitySet(_: *LinuxOps, capability: u32) OperationError!bool {
        const linux = std.os.linux;
        const rc = try prctl(.CAP_AMBIENT, linux.PR.CAP_AMBIENT_IS_SET, capability, 0, 0);
        if (rc > 1) return error.OperationFailed;
        return rc == 1;
    }

    fn getSecureBits(_: *LinuxOps) OperationError!u32 {
        const rc = try prctl(.GET_SECUREBITS, 0, 0, 0, 0);
        if (rc > std.math.maxInt(u32)) return error.OperationFailed;
        return @intCast(rc);
    }

    fn getKeepCaps(_: *LinuxOps) OperationError!bool {
        const rc = try prctl(.GET_KEEPCAPS, 0, 0, 0, 0);
        if (rc > 1) return error.OperationFailed;
        return rc == 1;
    }

    fn isBoundingCapabilitySet(_: *LinuxOps, capability: u32) OperationError!bool {
        const rc = try prctl(.CAPBSET_READ, capability, 0, 0, 0);
        if (rc > 1) return error.OperationFailed;
        return rc == 1;
    }

    fn areCapabilitySetsZero(_: *LinuxOps) OperationError!bool {
        const linux = std.os.linux;
        var header: CapabilityHeader = .{ .version = capability_version_3, .pid = 0 };
        var data: [2]CapabilityData = undefined;
        const rc = linux.syscall2(.capget, @intFromPtr(&header), @intFromPtr(&data[0]));
        if (linux.errno(rc) != .SUCCESS) return error.OperationFailed;
        for (data) |word| {
            if (word.effective != 0 or word.permitted != 0 or word.inheritable != 0) return false;
        }
        return true;
    }

    fn prctl(
        operation: std.os.linux.PR,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
    ) OperationError!usize {
        const linux = std.os.linux;
        const rc = linux.prctl(@intFromEnum(operation), arg2, arg3, arg4, arg5);
        if (linux.errno(rc) != .SUCCESS) return error.OperationFailed;
        return rc;
    }
};

test "lockdown applies and verifies every capability control in exact order" {
    var ops: MockOps = .{ .last_capability = 2 };
    try lockdownWithOps(&ops);

    const expected = [_]Event{
        .set_no_new_privileges,
        .clear_ambient,
        .{ .set_secure_bits = required_secure_bits },
        .get_last_capability,
        .{ .drop_bounding = 0 },
        .{ .drop_bounding = 1 },
        .{ .drop_bounding = 2 },
        .zero_capability_sets,
        .verify_no_new_privileges,
        .{ .verify_ambient = 0 },
        .{ .verify_ambient = 1 },
        .{ .verify_ambient = 2 },
        .get_secure_bits,
        .get_keep_caps,
        .{ .verify_bounding = 0 },
        .{ .verify_bounding = 1 },
        .{ .verify_bounding = 2 },
        .verify_capability_sets,
    };
    try std.testing.expectEqualSlices(Event, &expected, ops.events[0..ops.event_count]);
}

test "lockdown stops after every injected operation failure" {
    var successful: MockOps = .{ .last_capability = 2 };
    try lockdownWithOps(&successful);
    const expected = successful.events[0..successful.event_count];

    var fail_at: usize = 0;
    while (fail_at < expected.len) : (fail_at += 1) {
        var ops: MockOps = .{ .last_capability = 2, .fail_at = fail_at };
        if (lockdownWithOps(&ops)) {
            return error.ExpectedLockdownFailure;
        } else |_| {}
        try std.testing.expectEqual(fail_at + 1, ops.event_count);
        try std.testing.expectEqualSlices(Event, expected[0 .. fail_at + 1], ops.events[0..ops.event_count]);
    }
}

test "lockdown rejects kernel capability range beyond bounded masks" {
    var ops: MockOps = .{ .last_capability = max_supported_capability + 1 };
    try std.testing.expectError(error.CapabilityRangeTooLarge, lockdownWithOps(&ops));
    try std.testing.expectEqual(@as(usize, 4), ops.event_count);
}

test "lockdown fails closed when postconditions do not hold" {
    {
        var ops: MockOps = .{ .no_new_privileges = false };
        try std.testing.expectError(error.NoNewPrivilegesVerificationFailed, lockdownWithOps(&ops));
    }
    {
        var ops: MockOps = .{ .ambient_capability_set = 1 };
        try std.testing.expectError(error.AmbientVerificationFailed, lockdownWithOps(&ops));
    }
    {
        var ops: MockOps = .{ .secure_bits = required_secure_bits & ~secure_no_root };
        try std.testing.expectError(error.SecureBitsVerificationFailed, lockdownWithOps(&ops));
    }
    {
        var ops: MockOps = .{ .keep_caps = true };
        try std.testing.expectError(error.SecureBitsVerificationFailed, lockdownWithOps(&ops));
    }
    {
        var ops: MockOps = .{ .bounding_capability_set = 1 };
        try std.testing.expectError(error.BoundingVerificationFailed, lockdownWithOps(&ops));
    }
    {
        var ops: MockOps = .{ .capability_sets_zero = false };
        try std.testing.expectError(error.CapabilitySetVerificationFailed, lockdownWithOps(&ops));
    }
}

test "non Linux production entry point is unsupported" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, lockdownCurrentProcess());
}

test "capability syscall structs match Linux UAPI layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CapabilityHeader));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CapabilityHeader));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CapabilityHeader, "pid"));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(CapabilityData));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CapabilityData));
}

const Event = union(enum) {
    set_no_new_privileges,
    clear_ambient,
    set_secure_bits: u32,
    get_last_capability,
    drop_bounding: u32,
    zero_capability_sets,
    verify_no_new_privileges,
    verify_ambient: u32,
    get_secure_bits,
    get_keep_caps,
    verify_bounding: u32,
    verify_capability_sets,
};

const MockOps = struct {
    events: [256]Event = undefined,
    event_count: usize = 0,
    fail_at: ?usize = null,
    last_capability: u32 = 2,
    no_new_privileges: bool = true,
    ambient_capability_set: ?u32 = null,
    secure_bits: u32 = required_secure_bits,
    keep_caps: bool = false,
    bounding_capability_set: ?u32 = null,
    capability_sets_zero: bool = true,

    fn record(self: *MockOps, event: Event) error{InjectedFailure}!void {
        const index = self.event_count;
        self.events[index] = event;
        self.event_count += 1;
        if (self.fail_at == index) return error.InjectedFailure;
    }

    fn setNoNewPrivileges(self: *MockOps) !void {
        try self.record(.set_no_new_privileges);
    }

    fn clearAmbientCapabilities(self: *MockOps) !void {
        try self.record(.clear_ambient);
    }

    fn setSecureBits(self: *MockOps, bits: u32) !void {
        try self.record(.{ .set_secure_bits = bits });
    }

    fn getLastCapability(self: *MockOps) !u32 {
        try self.record(.get_last_capability);
        return self.last_capability;
    }

    fn dropBoundingCapability(self: *MockOps, capability: u32) !void {
        try self.record(.{ .drop_bounding = capability });
    }

    fn zeroCapabilitySets(self: *MockOps) !void {
        try self.record(.zero_capability_sets);
    }

    fn hasNoNewPrivileges(self: *MockOps) !bool {
        try self.record(.verify_no_new_privileges);
        return self.no_new_privileges;
    }

    fn isAmbientCapabilitySet(self: *MockOps, capability: u32) !bool {
        try self.record(.{ .verify_ambient = capability });
        return self.ambient_capability_set == capability;
    }

    fn getSecureBits(self: *MockOps) !u32 {
        try self.record(.get_secure_bits);
        return self.secure_bits;
    }

    fn getKeepCaps(self: *MockOps) !bool {
        try self.record(.get_keep_caps);
        return self.keep_caps;
    }

    fn isBoundingCapabilitySet(self: *MockOps, capability: u32) !bool {
        try self.record(.{ .verify_bounding = capability });
        return self.bounding_capability_set == capability;
    }

    fn areCapabilitySetsZero(self: *MockOps) !bool {
        try self.record(.verify_capability_sets);
        return self.capability_sets_zero;
    }
};
