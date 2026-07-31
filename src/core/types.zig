const std = @import("std");
const errors = @import("errors.zig");
const limits = @import("limits.zig");

pub const Mode = enum {
    observe,
    ask,
    strict,
    ci,

    pub fn toString(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const ActorKind = enum {
    user,
    agent,
    process,
    mcp_client,
    mcp_server,
    ryk,
    unknown,
};

pub const Actor = struct {
    kind: ActorKind,
    id: ?[]const u8 = null,
    display: ?[]const u8 = null,
};

pub const TargetKind = enum {
    env_var,
    file_path,
    command,
    network_endpoint,
    mcp_tool,
    mcp_resource,
    mcp_prompt,
    mcp_sampling,
    approval,
    staging_area,
    session,
    extension,
    extension_target,
    unknown,
};

pub const Target = struct {
    kind: TargetKind,
    value: []const u8,
};

pub const PathKind = enum {
    absolute,
    relative,
};

pub const Path = struct {
    raw: []const u8,
    kind: PathKind,

    pub fn init(raw: []const u8) errors.OrcaError!Path {
        if (raw.len == 0 or raw.len > limits.max_path_len) return errors.OrcaError.InvalidPath;
        if (!std.unicode.utf8ValidateSlice(raw)) return errors.OrcaError.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, raw, 0) != null) return errors.OrcaError.InvalidPath;
        return .{
            .raw = raw,
            .kind = if (std.fs.path.isAbsolute(raw)) .absolute else .relative,
        };
    }
};

pub const EnvAction = struct {
    name: []const u8,
};

pub const FileAction = struct {
    path: Path,
};

pub const CommandAction = struct {
    argv: []const []const u8,
};

pub const NetworkAction = struct {
    host: []const u8,
    port: ?u16 = null,
    scheme: ?[]const u8 = null,
    method: ?[]const u8 = null,
};

pub const MCPToolAction = struct {
    server: ?[]const u8 = null,
    tool_name: []const u8,
};

pub const MCPResourceAction = struct {
    server: ?[]const u8 = null,
    uri: []const u8,
};

pub const MCPPromptAction = struct {
    server: ?[]const u8 = null,
    prompt_name: []const u8,
};

pub const MCPSamplingAction = struct {
    server: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const ApprovalAction = struct {
    target: Target,
    requested_scope: []const u8,
};

pub const StagingAction = struct {
    path: Path,
};

pub const Action = union(enum) {
    env_read: EnvAction,
    file_read: FileAction,
    file_write: FileAction,
    command_exec: CommandAction,
    network_connect: NetworkAction,
    mcp_tool_call: MCPToolAction,
    mcp_resource_read: MCPResourceAction,
    mcp_prompt_get: MCPPromptAction,
    mcp_sampling_request: MCPSamplingAction,
    approval_decision: ApprovalAction,
    staging_decision: StagingAction,

    pub fn targetKind(self: Action) TargetKind {
        return switch (self) {
            .env_read => .env_var,
            .file_read, .file_write => .file_path,
            .command_exec => .command,
            .network_connect => .network_endpoint,
            .mcp_tool_call => .mcp_tool,
            .mcp_resource_read => .mcp_resource,
            .mcp_prompt_get => .mcp_prompt,
            .mcp_sampling_request => .mcp_sampling,
            .approval_decision => .approval,
            .staging_decision => .staging_area,
        };
    }
};

test "path wrapper validates utf8 and classifies path kind" {
    const relative = try Path.init("src/root.zig");
    try std.testing.expectEqual(PathKind.relative, relative.kind);

    const absolute = try Path.init("/tmp/ryk");
    try std.testing.expectEqual(PathKind.absolute, absolute.kind);

    try std.testing.expectError(error.InvalidPath, Path.init(""));
    try std.testing.expectError(error.InvalidPath, Path.init("bad\x00path"));
    try std.testing.expectError(error.InvalidUtf8, Path.init(&.{0xff}));
}

test "action union covers enforcement surfaces" {
    const path = try Path.init("README.md");
    const action: Action = .{ .file_read = .{ .path = path } };
    try std.testing.expectEqual(TargetKind.file_path, action.targetKind());

    const tool: Action = .{ .mcp_tool_call = .{ .tool_name = "read_file" } };
    try std.testing.expectEqual(TargetKind.mcp_tool, tool.targetKind());
}
