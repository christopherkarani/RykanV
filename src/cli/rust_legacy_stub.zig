//! Stubs for former Rust ExecuteCli surfaces removed in the Zig-only conversion.
const std = @import("std");

pub fn unavailable(command: []const u8, stderr: anytype) !u8 {
    try stderr.print(
        "ryk {s}: this command previously required the Rust daemon and is not yet ported to pure Zig.\nSee docs/threat-model.md and CHANGELOG for the Zig shell-engine cutover.\n",
        .{command},
    );
    return 1;
}
