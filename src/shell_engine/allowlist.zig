//! Minimal allowlist matching for the Zig shell engine.
//! Exact-command and prefix entries; full Rust allowlist semantics deferred.

const std = @import("std");

pub const Entry = struct {
    pattern: []const u8,
    prefix: bool = false,
};

pub const Layered = struct {
    entries: []const Entry = &.{},

    pub fn allows(self: Layered, command: []const u8) bool {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        for (self.entries) |entry| {
            if (entry.prefix) {
                if (std.mem.startsWith(u8, trimmed, entry.pattern)) return true;
            } else if (std.mem.eql(u8, trimmed, entry.pattern)) {
                return true;
            }
        }
        return false;
    }
};

test "allowlist exact and prefix" {
    const layered: Layered = .{
        .entries = &.{
            .{ .pattern = "git status" },
            .{ .pattern = "npm run ", .prefix = true },
        },
    };
    try std.testing.expect(layered.allows("git status"));
    try std.testing.expect(layered.allows("npm run test"));
    try std.testing.expect(!layered.allows("git reset --hard"));
}

// s-engine: preserve policy permit Layered + Entry.prefix (permanent path is separate).
// Permanent pack-exception store lives in allowlist_store.zig and must not replace this API.
test "s-engine: policy Layered Entry.prefix preserved for permit path" {
    // Exact entry: full command only.
    const exact: Layered = .{
        .entries = &.{
            .{ .pattern = "git reset --hard HEAD", .prefix = false },
        },
    };
    try std.testing.expect(exact.allows("git reset --hard HEAD"));
    try std.testing.expect(exact.allows("  git reset --hard HEAD  "));
    try std.testing.expect(!exact.allows("git reset --hard HEAD~1"));
    try std.testing.expect(!exact.allows("git reset --hard HEAD; rm -rf /"));

    // Prefix entry (trailing-glob style used by policy commands.allow): startsWith.
    const prefix: Layered = .{
        .entries = &.{
            .{ .pattern = "npm run ", .prefix = true },
        },
    };
    try std.testing.expect(prefix.allows("npm run test"));
    try std.testing.expect(prefix.allows("npm run build"));
    try std.testing.expect(!prefix.allows("npm run")); // no trailing space match on shorter
    try std.testing.expect(!prefix.allows("npm install"));

    // Entry.prefix field remains part of the public policy matcher surface.
    const e = Entry{ .pattern = "cargo ", .prefix = true };
    try std.testing.expect(e.prefix);
    const layered: Layered = .{ .entries = &.{e} };
    try std.testing.expect(layered.allows("cargo test"));
    try std.testing.expect(!layered.allows("cargo"));
}
