const std = @import("std");

const env_util = @import("../env_util.zig");
const audit = @import("orca_core").audit;
const core = @import("orca_core").core;
const policy = @import("orca_core").policy;
const credentials = @import("credentials.zig");

pub const implemented = true;

pub const Request = struct {
    no_secrets: bool = false,
    secretless: bool = false,
    inherit_env: bool = false,
};

pub const RedactionRecord = core.process.EnvRedactionRecord;

pub const FilteredEnv = struct {
    allocator: std.mem.Allocator,
    env_map: std.process.Environ.Map,
    use_custom_env: bool,
    redactions: []RedactionRecord,
    /// Count of secret-like values rewritten to non-resolving `orca-secret://` refs under `--secretless`.
    secretless_replacements: usize = 0,

    pub fn deinit(self: *FilteredEnv) void {
        for (self.redactions) |record| {
            self.allocator.free(record.name);
            for (record.labels) |label| self.allocator.free(label);
            self.allocator.free(record.labels);
        }
        self.allocator.free(self.redactions);
        self.env_map.deinit();
        self.* = undefined;
    }
};

/// Loud readiness note when `--secretless` rewrote secret-like env vars to
/// non-resolving local-dummy refs (avoids silent provider 401s on day-1 launches).
pub fn writeSecretlessReadinessNote(stderr: anytype, secretless_replacements: usize) !void {
    if (secretless_replacements == 0) return;
    try stderr.print(
        "ryk run: --secretless rewrote {d} secret-like env var(s) to non-resolving orca-secret://local-dummy/... references. Agents that need raw model API keys from the environment (e.g. OPENAI_API_KEY, ANTHROPIC_API_KEY) will not authenticate. Omit --secretless for day-1 agent launches; see docs/credentials.md (Secretless Mode).\n",
        .{secretless_replacements},
    );
}

pub fn filterCurrent(
    allocator: std.mem.Allocator,
    selected_policy: *const policy.schema.Policy,
    effective_mode: policy.schema.Mode,
    request: Request,
) !FilteredEnv {
    var current = try env_util.createProcessMap(allocator);
    defer current.deinit();
    return filterMap(allocator, &current, selected_policy, effective_mode, request);
}

pub fn filterMap(
    allocator: std.mem.Allocator,
    current: *const std.process.Environ.Map,
    selected_policy: *const policy.schema.Policy,
    effective_mode: policy.schema.Mode,
    request: Request,
) !FilteredEnv {
    if (request.inherit_env and !selected_policy.env.inherit) return error.InheritEnvDenied;

    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    var redactions: std.ArrayList(RedactionRecord) = .empty;
    errdefer {
        for (redactions.items) |record| {
            allocator.free(record.name);
            for (record.labels) |label| allocator.free(label);
            allocator.free(record.labels);
        }
        redactions.deinit(allocator);
    }

    const inherit_source = selected_policy.env.inherit or request.inherit_env;
    const minimal = !inherit_source or isEnforcingNoSecretsMode(effective_mode);
    const force_no_secrets = request.no_secrets or (isEnforcingNoSecretsMode(effective_mode) and !request.secretless);
    // Secretless always emits local-dummy refs today. These are non-resolving: child processes
    // that treat env values as raw provider credentials will not authenticate.
    const broker = credentials.localDummyBroker();
    var secretless_replacements: usize = 0;

    var it = current.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const name_secret = audit.redact_bridge.isSecretEnvName(name);
        const value_match = audit.redact_bridge.classifySecretValue(value);
        if (name_secret) {
            try appendRedaction(allocator, &redactions, name, name, value, "environment variable name matches secret pattern");
        } else if (value_match) |match| {
            try appendValueRedaction(allocator, &redactions, name, match, "environment variable value matches secret pattern");
        }

        const secret_like = name_secret or value_match != null;
        if (try shouldInclude(allocator, selected_policy, effective_mode, minimal, force_no_secrets, name, name_secret, value_match != null)) {
            if (request.secretless and secret_like) {
                const ref = try broker.envReference(allocator, name, value);
                defer ref.deinit(allocator);
                try env_map.put(name, ref.value);
                secretless_replacements += 1;
            } else {
                try env_map.put(name, value);
            }
        }
    }

    return .{
        .allocator = allocator,
        .env_map = env_map,
        .use_custom_env = true,
        .redactions = try redactions.toOwnedSlice(allocator),
        .secretless_replacements = secretless_replacements,
    };
}

fn shouldInclude(
    allocator: std.mem.Allocator,
    selected_policy: *const policy.schema.Policy,
    effective_mode: policy.schema.Mode,
    minimal: bool,
    force_no_secrets: bool,
    name: []const u8,
    name_secret: bool,
    value_secret: bool,
) !bool {
    if (force_no_secrets and (name_secret or value_secret)) return false;

    var evaluation = try policy.evaluate.action(selected_policy, .{ .env_read = .{ .name = name } }, .{ .mode = effective_mode }, allocator);
    defer evaluation.deinit(allocator);

    if (effective_mode == .observe and selected_policy.env.inherit and !force_no_secrets) {
        return true;
    }
    if (evaluation.decision.result == .deny) return false;
    if (minimal) {
        return explicitlyAllowed(selected_policy.env.allow, name);
    }
    return true;
}

fn explicitlyAllowed(allow: []const []const u8, name: []const u8) bool {
    for (allow) |pattern| {
        if (policy.matchers.matchesPattern(pattern, name)) return true;
    }
    return false;
}

fn isEnforcingNoSecretsMode(mode: policy.schema.Mode) bool {
    return mode == .strict or mode == .ci or mode == .redteam;
}

fn appendRedaction(
    allocator: std.mem.Allocator,
    redactions: *std.ArrayList(RedactionRecord),
    name: []const u8,
    label_name: []const u8,
    value: []const u8,
    reason: []const u8,
) !void {
    var label_buf: [256]u8 = undefined;
    const label = try audit.redact_bridge.formatEnvReplacement(&label_buf, label_name, value);
    const labels = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(labels);
    labels[0] = try allocator.dupe(u8, label);
    errdefer allocator.free(labels[0]);
    try redactions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .labels = labels,
        .reason = reason,
    });
}

fn appendValueRedaction(
    allocator: std.mem.Allocator,
    redactions: *std.ArrayList(RedactionRecord),
    name: []const u8,
    match: audit.redact_bridge.RedactionMatch,
    reason: []const u8,
) !void {
    var label_buf: [256]u8 = undefined;
    const label = if (std.mem.startsWith(u8, match.label, "secret:"))
        try std.fmt.bufPrint(&label_buf, "[REDACTED:{s}:sha256:{s}]", .{ match.label, &match.fingerprint })
    else
        try std.fmt.bufPrint(&label_buf, "[REDACTED:env:{s}:sha256:{s}]", .{ match.label, &match.fingerprint });
    const labels = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(labels);
    labels[0] = try allocator.dupe(u8, label);
    errdefer allocator.free(labels[0]);
    try redactions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .labels = labels,
        .reason = reason,
    });
}

test "strict env filtering keeps allowlist and strips synthetic secret names" {
    var selected = try policy.load.parseFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: strict
        \\env:
        \\  inherit: false
        \\  allow:
        \\    - PATH
        \\    - SAFE_FAKE
        \\  deny_patterns:
        \\    - "*TOKEN*"
    , "test.yaml");
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("PATH", "/usr/bin");
    try current.put("SAFE_FAKE", "ok");
    try current.put("FAKE_GITHUB_TOKEN", "fake_secret_value");
    try current.put("OTHER", "value");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .strict, .{});
    defer filtered.deinit();

    try std.testing.expectEqualStrings("/usr/bin", filtered.env_map.get("PATH").?);
    try std.testing.expectEqualStrings("ok", filtered.env_map.get("SAFE_FAKE").?);
    try std.testing.expect(filtered.env_map.get("FAKE_GITHUB_TOKEN") == null);
    try std.testing.expect(filtered.env_map.get("OTHER") == null);
    try std.testing.expectEqual(@as(usize, 1), filtered.redactions.len);
    try std.testing.expect(std.mem.indexOf(u8, filtered.redactions[0].labels[0], "fake_secret_value") == null);
}

test "env deny pattern beats allow during filtering" {
    var selected = try policy.load.parseFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: strict
        \\env:
        \\  inherit: false
        \\  allow:
        \\    - FAKE_ALLOWED
        \\  deny_patterns:
        \\    - "FAKE_*"
    , "test.yaml");
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("FAKE_ALLOWED", "ok");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .strict, .{});
    defer filtered.deinit();

    try std.testing.expect(filtered.env_map.get("FAKE_ALLOWED") == null);
}

test "inherit-env fails closed when policy disallows inheritance" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .strict);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("PATH", "/usr/bin");

    try std.testing.expectError(error.InheritEnvDenied, filterMap(std.testing.allocator, &current, &selected, .strict, .{ .inherit_env = true }));
}

test "observe mode inherits but records redactions for audit" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .observe);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("FAKE_GITHUB_TOKEN", "fake_secret_value");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .observe, .{});
    defer filtered.deinit();

    try std.testing.expectEqualStrings("fake_secret_value", filtered.env_map.get("FAKE_GITHUB_TOKEN").?);
    try std.testing.expectEqual(@as(usize, 1), filtered.redactions.len);
    try std.testing.expect(std.mem.indexOf(u8, filtered.redactions[0].labels[0], "fake_secret_value") == null);
}

test "no-secrets strips secret-like values even when inheriting" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .observe);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("NORMAL_VALUE", "fake_secret_value");
    try current.put("SAFE_VALUE", "ok");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .observe, .{ .no_secrets = true });
    defer filtered.deinit();

    try std.testing.expect(filtered.env_map.get("NORMAL_VALUE") == null);
    try std.testing.expectEqualStrings("ok", filtered.env_map.get("SAFE_VALUE").?);
}

test "secretless replaces inherited secret-like env with local broker references" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .observe);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("GITHUB_TOKEN", "ghp_fakeSyntheticTokenValue1234567890");
    try current.put("SAFE_VALUE", "ok");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .observe, .{ .secretless = true });
    defer filtered.deinit();

    const token_value = filtered.env_map.get("GITHUB_TOKEN").?;
    try std.testing.expect(std.mem.startsWith(u8, token_value, "orca-secret://local-dummy/env/GITHUB_TOKEN/"));
    try std.testing.expect(std.mem.indexOf(u8, token_value, "ghp_fakeSyntheticTokenValue") == null);
    try std.testing.expectEqualStrings("ok", filtered.env_map.get("SAFE_VALUE").?);
    try std.testing.expectEqual(@as(usize, 1), filtered.redactions.len);
    try std.testing.expectEqual(@as(usize, 1), filtered.secretless_replacements);
    try std.testing.expect(std.mem.indexOf(u8, filtered.redactions[0].labels[0], "ghp_fakeSyntheticTokenValue") == null);
}

test "writeSecretlessReadinessNote is silent when count is zero" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSecretlessReadinessNote(&w, 0);
    try std.testing.expectEqualStrings("", w.buffered());
}

test "writeSecretlessReadinessNote mentions count when non-zero" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSecretlessReadinessNote(&w, 3);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--secretless rewrote") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "non-resolving") != null);
}

test "secretless rewrites model API key env names to non-resolving local-dummy refs" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .observe);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("OPENAI_API_KEY", "sk-fakeSyntheticOpenAIKey1234567890");
    try current.put("ANTHROPIC_API_KEY", "sk-ant-fakeSyntheticAnthropicKey1234567890");
    try current.put("PATH", "/usr/bin");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .observe, .{ .secretless = true });
    defer filtered.deinit();

    const openai = filtered.env_map.get("OPENAI_API_KEY").?;
    const anthropic = filtered.env_map.get("ANTHROPIC_API_KEY").?;
    try std.testing.expect(std.mem.startsWith(u8, openai, "orca-secret://local-dummy/env/OPENAI_API_KEY/"));
    try std.testing.expect(std.mem.startsWith(u8, anthropic, "orca-secret://local-dummy/env/ANTHROPIC_API_KEY/"));
    try std.testing.expect(std.mem.indexOf(u8, openai, "sk-fakeSynthetic") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "sk-ant-fakeSynthetic") == null);
    try std.testing.expectEqualStrings("/usr/bin", filtered.env_map.get("PATH").?);
    try std.testing.expectEqual(@as(usize, 2), filtered.secretless_replacements);
}

test "observe mode override still honors env inherit false" {
    var selected = try policy.load.loadPreset(std.testing.allocator, .strict);
    defer selected.deinit();

    var current = std.process.Environ.Map.init(std.testing.allocator);
    defer current.deinit();
    try current.put("PATH", "/usr/bin");
    try current.put("UNIQUE_SAFE_PHASE08", "visible");

    var filtered = try filterMap(std.testing.allocator, &current, &selected, .observe, .{});
    defer filtered.deinit();

    try std.testing.expectEqualStrings("/usr/bin", filtered.env_map.get("PATH").?);
    try std.testing.expect(filtered.env_map.get("UNIQUE_SAFE_PHASE08") == null);
}
