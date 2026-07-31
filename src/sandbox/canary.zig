//! Runtime synthetic canaries for differential enforcement tests.
//! Never store live canary bodies in tracked fixtures or evidence.

const std = @import("std");
const util = @import("ryk_core").core.util;

pub const prefix = "RYK_CANARY_v1_";

pub const Canary = struct {
    /// Full body placed on disk for CTRL-BASELINE / TEST-DENY.
    body: []u8,
    /// Short fingerprint safe to store in evidence (hex of SHA-256).
    fingerprint_hex: [64]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Canary) void {
        @memset(self.body, 0);
        self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn fingerprint(self: *const Canary) []const u8 {
        return self.fingerprint_hex[0..];
    }
};

var canary_seq: std.atomic.Value(u64) = .init(1);

/// Generate a unique canary. Caller must deinit.
/// Uses CSPRNG via `std.Io.random` mixed with a process sequence so canaries
/// are never fixed fixtures and never stored in tracked sources.
pub fn generate(allocator: std.mem.Allocator) !Canary {
    var rnd_buf: [16]u8 = undefined;
    fillEntropy(&rnd_buf);

    var hex: [32]u8 = undefined;
    _ = try util.hexLower(&rnd_buf, &hex);

    const body = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..] });
    errdefer allocator.free(body);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    var fingerprint_hex: [64]u8 = undefined;
    _ = try util.hexLower(&digest, &fingerprint_hex);

    return .{
        .body = body,
        .fingerprint_hex = fingerprint_hex,
        .allocator = allocator,
    };
}

fn fillEntropy(buf: []u8) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    io.random(buf);
    // Mix sequence so consecutive calls differ even if random is weak in tests.
    const seq = canary_seq.fetchAdd(1, .monotonic);
    if (buf.len >= 8) {
        const existing = std.mem.readInt(u64, buf[0..8], .little);
        std.mem.writeInt(u64, buf[0..8], existing ^ seq, .little);
    }
}

/// True if haystack contains the raw canary body (leak detection).
pub fn bodyLeaked(canary: Canary, haystack: []const u8) bool {
    return std.mem.indexOf(u8, haystack, canary.body) != null;
}

test "canary has stable prefix and unique bodies" {
    var a = try generate(std.testing.allocator);
    defer a.deinit();
    var b = try generate(std.testing.allocator);
    defer b.deinit();
    try std.testing.expect(std.mem.startsWith(u8, a.body, prefix));
    try std.testing.expect(!std.mem.eql(u8, a.body, b.body));
    try std.testing.expect(!std.mem.eql(u8, a.fingerprint(), b.fingerprint()));
}

test "canary leak scan detects body and not fingerprint alone" {
    var c = try generate(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(bodyLeaked(c, c.body));
    const wrapped = try std.fmt.allocPrint(std.testing.allocator, "out:{s}:end", .{c.body});
    defer std.testing.allocator.free(wrapped);
    try std.testing.expect(bodyLeaked(c, wrapped));
    // fingerprint alone is not the body
    try std.testing.expect(!bodyLeaked(c, c.fingerprint()));
}
