const std = @import("std");

pub const SchemaKind = enum {
    policy,
    event,
    mcp_manifest,
};

pub const SchemaDescriptor = struct {
    kind: SchemaKind,
    id: []const u8,
    version: u16,
    path: []const u8,
    status: []const u8,
    contents: []const u8,
};

const schema_documents = @import("core_schema_documents");

const policy_schema_contents = schema_documents.policy_v1;
const event_schema_contents = schema_documents.event_v1;
const mcp_manifest_schema_contents = schema_documents.mcp_manifest_v1;

pub const registry = [_]SchemaDescriptor{
    .{
        .kind = .policy,
        .id = "policy-v1",
        .version = 1,
        .path = "schemas/policy-v1.json",
        .status = "stable-v1",
        .contents = policy_schema_contents,
    },
    .{
        .kind = .event,
        .id = "event-v1",
        .version = 1,
        .path = "schemas/event-v1.json",
        .status = "stable-v1",
        .contents = event_schema_contents,
    },
    .{
        .kind = .mcp_manifest,
        .id = "mcp-manifest-v1",
        .version = 1,
        .path = "schemas/mcp-manifest-v1.json",
        .status = "stable-v1",
        .contents = mcp_manifest_schema_contents,
    },
};

pub fn lookup(kind: SchemaKind) ?SchemaDescriptor {
    for (registry) |descriptor| {
        if (descriptor.kind == kind) return descriptor;
    }
    return null;
}

pub fn lookupId(id: []const u8) ?SchemaDescriptor {
    for (registry) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
    }
    return null;
}

test "schema registry exposes stable Core descriptors only" {
    try std.testing.expect(lookup(.policy) != null);
    try std.testing.expect(lookup(.event) != null);
    try std.testing.expect(lookupId("mcp-manifest-v1") != null);
    try std.testing.expect(lookupId("missing") == null);
}

test "schema registry contents are full JSON schemas" {
    const policy = lookup(.policy) orelse return error.TestUnexpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, policy.contents, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("$schema") != null);
    try std.testing.expect(object.get("type") != null);
    try std.testing.expect(object.get("properties") != null);
}
