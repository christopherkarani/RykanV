//! Canonical shell-tool name classification for hook surfaces.
//! Single table so agent_hook and hook cannot drift.

const std = @import("std");

/// Tool names that always route through the shell evaluator (Zig shell_engine by default).
pub const shell_tool_names = [_][]const u8{
    "bash",
    "shell",
    "sh",
    "zsh",
    "exec", // OpenClaw shell tool
    "terminal",
    "run_shell_command",
    "run-shell-command",
    "run_terminal_cmd", // Grok Build tool id (xai-org/grok-build)
    "run_terminal_command", // Grok Build Claude-alias expansion name
    "powershell",
    "pwsh",
    "launch-process",
};

pub fn isShellTool(tool_name: []const u8) bool {
    for (shell_tool_names) |st| {
        if (std.ascii.eqlIgnoreCase(tool_name, st)) return true;
    }
    return false;
}

test "isShellTool covers OpenClaw exec and common hosts" {
    try std.testing.expect(isShellTool("bash"));
    try std.testing.expect(isShellTool("Bash"));
    try std.testing.expect(isShellTool("Shell"));
    try std.testing.expect(isShellTool("shell"));
    try std.testing.expect(isShellTool("sh"));
    try std.testing.expect(isShellTool("zsh"));
    try std.testing.expect(isShellTool("exec"));
    try std.testing.expect(isShellTool("run_terminal_cmd"));
    try std.testing.expect(isShellTool("run_terminal_command"));
    try std.testing.expect(isShellTool("run-shell-command"));
    try std.testing.expect(!isShellTool("Write"));
    try std.testing.expect(!isShellTool("Read"));
    try std.testing.expect(!isShellTool(""));
}
