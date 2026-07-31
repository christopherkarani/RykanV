//! Known host session path table (no $HOME crawl).
//! Paths verified against real installs / public layouts on 2026-07-30.
const std = @import("std");
const types = @import("types.zig");

pub const HostPathSpec = struct {
    host: types.Host,
    /// Relative segments under HOME (joined at runtime). Empty first segment means absolute under home.
    /// Multiple roots per host are listed separately.
    home_relative: []const []const u8,
    /// Optional XDG_DATA_HOME-relative roots (OpenCode).
    xdg_data_relative: []const []const u8 = &.{},
    note: []const u8,
};

/// Authoritative v1 path map. Discovery only reads these roots (bounded depth).
pub const host_path_table = [_]HostPathSpec{
    .{
        .host = .claude,
        // Claude Code: ~/.claude/projects/<slug>/*.jsonl
        .home_relative = &.{"/.claude/projects"},
        .note = "Claude Code project transcripts (*.jsonl)",
    },
    .{
        .host = .codex,
        // Codex CLI: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
        .home_relative = &.{"/.codex/sessions"},
        .note = "Codex rollout JSONL under date partitions",
    },
    .{
        .host = .pi,
        // Pi: ~/.pi/agent/sessions/<project>/<session>/.../session.jsonl
        .home_relative = &.{"/.pi/agent/sessions"},
        .note = "Pi agent session.jsonl trees",
    },
    .{
        .host = .opencode,
        // OpenCode: ~/.local/share/opencode/opencode.db (SQLite, read-only via sqlite3 CLI)
        .home_relative = &.{},
        .xdg_data_relative = &.{"/opencode"},
        .note = "OpenCode SQLite store (opencode.db, read-only)",
    },
    .{
        .host = .grok,
        // Grok Build: ~/.grok/sessions/<url-encoded-cwd>/<session-id>/chat_history.jsonl|events.jsonl
        .home_relative = &.{"/.grok/sessions"},
        .note = "Grok Build session chat_history.jsonl",
    },
    .{
        .host = .ryk,
        // ryk/ryk: ~/.ryk/sessions + dashboard registry; optional ~/.ryk dual-read
        .home_relative = &.{ "/.ryk/sessions", "/.ryk/dashboard", "/.ryk/sessions", "/.ryk/dashboard" },
        .note = "ryk bridge: .ryk (+ .ryk if present) sessions + dashboard",
    },
};

pub fn resolveHomeRoot(allocator: std.mem.Allocator, home: []const u8, rel: []const u8) ![]u8 {
    // rel starts with /
    if (rel.len > 0 and rel[0] == '/') {
        return std.fs.path.join(allocator, &.{ home, rel[1..] });
    }
    return std.fs.path.join(allocator, &.{ home, rel });
}

pub fn resolveXdgDataRoot(allocator: std.mem.Allocator, home: []const u8, xdg_data: ?[]const u8, rel: []const u8) ![]u8 {
    const base = if (xdg_data) |x| x else blk: {
        break :blk try std.fs.path.join(allocator, &.{ home, ".local/share" });
    };
    defer if (xdg_data == null) allocator.free(base);
    if (rel.len > 0 and rel[0] == '/') {
        return std.fs.path.join(allocator, &.{ base, rel[1..] });
    }
    return std.fs.path.join(allocator, &.{ base, rel });
}

test "path table covers all v1 hosts without home crawl" {
    var seen: [6]bool = .{false} ** 6;
    for (host_path_table) |spec| {
        seen[@intFromEnum(spec.host)] = true;
        // No recursive ** glob — only fixed segments.
        for (spec.home_relative) |rel| {
            try std.testing.expect(std.mem.indexOf(u8, rel, "**") == null);
        }
    }
    for (seen) |s| try std.testing.expect(s);
}
