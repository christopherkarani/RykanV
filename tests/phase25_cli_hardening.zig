const std = @import("std");
const ryk = @import("ryk");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "phase25 release scripts package runtime assets referenced by CLI docs" {
    const sh = try readFile(std.testing.allocator, "scripts/build-release.sh");
    defer std.testing.allocator.free(sh);
    const ps1 = try readFile(std.testing.allocator, "scripts/build-release.ps1");
    defer std.testing.allocator.free(ps1);

    const required = [_][]const u8{ "docs", "policies", "schemas", "fixtures", "examples", "packages", "packaging", "scripts" };
    for (required) |name| {
        try std.testing.expect(std.mem.indexOf(u8, sh, name) != null);
        try std.testing.expect(std.mem.indexOf(u8, ps1, name) != null);
    }
}

test "phase25 release scripts exclude transient Python cache artifacts" {
    const sh = try readFile(std.testing.allocator, "scripts/build-release.sh");
    defer std.testing.allocator.free(sh);
    const ps1 = try readFile(std.testing.allocator, "scripts/build-release.ps1");
    defer std.testing.allocator.free(ps1);

    for ([_][]const u8{ "__pycache__", ".pytest_cache", ".pyc", ".pyo" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, sh, marker) != null);
        try std.testing.expect(std.mem.indexOf(u8, ps1, marker) != null);
    }
}

test "phase25 Windows package templates match nested zip layout" {
    const version_file = try readFile(std.testing.allocator, "VERSION");
    defer std.testing.allocator.free(version_file);
    const version = std.mem.trim(u8, version_file, " \t\r\n");
    const scoop = try readFile(std.testing.allocator, "packaging/scoop/ryk.json");
    defer std.testing.allocator.free(scoop);
    const winget = try readFile(std.testing.allocator, "packaging/winget/ryk.yaml");
    defer std.testing.allocator.free(winget);

    const scoop_path = try std.fmt.allocPrint(std.testing.allocator, "ryk-v{s}-windows-amd64\\\\bin\\\\ryk.exe", .{version});
    defer std.testing.allocator.free(scoop_path);
    const winget_path = try std.fmt.allocPrint(std.testing.allocator, "ryk-v{s}-windows-amd64\\bin\\ryk.exe", .{version});
    defer std.testing.allocator.free(winget_path);
    try std.testing.expect(std.mem.indexOf(u8, scoop, scoop_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, winget, winget_path) != null);
}

test "phase25 npm package is honest while checksum placeholders remain" {
    const package_json = try readFile(std.testing.allocator, "packaging/npm/package.json");
    defer std.testing.allocator.free(package_json);
    const wrapper = try readFile(std.testing.allocator, "packaging/npm/bin/ryk.js");
    defer std.testing.allocator.free(wrapper);
    const readme = try readFile(std.testing.allocator, "packaging/npm/README.md");
    defer std.testing.allocator.free(readme);

    try std.testing.expect(std.mem.indexOf(u8, package_json, "npm launcher for the Zig-built ryk binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper, "missing release checksums") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "fails closed") != null);
}

test "phase25 MCP docs distinguish proxy stdin and list observation" {
    const mcp_doc = try readFile(std.testing.allocator, "docs/mcp.md");
    defer std.testing.allocator.free(mcp_doc);

    try std.testing.expect(std.mem.indexOf(u8, mcp_doc, "waits for JSON-RPC on stdin") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_doc, "policy-gates") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_doc, "observes and audits `tools/list`, `resources/list`, and `prompts/list`") != null);
}

test "phase25 Core facade is the shared CLI policy audit replay and redaction surface" {
    try std.testing.expect(@hasDecl(orca, "core_api"));

    var selected = try ryk.core_api.parsePolicyFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: ci
        \\commands:
        \\  ask:
        \\    - "npm install *"
    , "phase25-core-api.yaml");
    defer selected.deinit();

    var evaluation = try ryk.core_api.evaluateAction(
        std.testing.allocator,
        selected,
        .{ .command_exec = .{ .argv = &.{ "npm", "install", "left-pad" } } },
        .{},
    );
    defer evaluation.deinit(std.testing.allocator);

    try std.testing.expectEqual(ryk.core_api.DecisionResult.deny, evaluation.decision.result);
    const redacted = ryk.core_api.redactString("OPENAI_API_KEY=sk-fakeSyntheticOpenAIKey1234567890");
    try std.testing.expect(std.mem.indexOf(u8, redacted, "sk-fakeSynthetic") == null);
}
