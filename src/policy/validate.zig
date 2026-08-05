const std = @import("std");

const audit_redact = @import("../audit/redact_bridge.zig");
const core = @import("../core/public.zig");
const effects = @import("effects/mod.zig");
const schema = @import("schema.zig");

pub fn policy(value: *const schema.Policy) !void {
    if (value.version_value != schema.version) return error.UnsupportedPolicyVersion;
    try validateString("workspace.root", value.workspace.root, core.limits.max_path_len);
    try validateEnv(value.env);
    try validateRuleSet("files.read", value.files.read, core.limits.max_path_len);
    try validateRuleSet("files.write", value.files.write, core.limits.max_path_len);
    try validateRuleSet("commands", value.commands, core.limits.max_command_len);
    try validateNetwork(value.network);
    try validateCredentials(value.credentials);
    try validateServices(value.services, value.credentials);
    try validateRuleSet("mcp", value.mcp, core.limits.max_event_field_len);
    try validateEffects(value.effects);
    // Audit records are persisted and may be exported. Disabling secret
    // redaction is therefore not a supported policy state.
    if (!value.audit.redact_secrets) return error.InvalidPolicy;
}

fn validateEffects(effects_policy: schema.EffectsPolicy) !void {
    if (!effects_policy.configured) {
        if (effects_policy.allow.len != 0 or effects_policy.deny.len != 0 or effects_policy.ask.len != 0 or effects_policy.default != null)
            return error.InvalidPolicy;
        // Classifier only valid under an active effects: section.
        if (effects_policy.classifier != .off) return error.InvalidPolicy;
        return;
    }
    for (effects_policy.allow) |pattern| try validateEffectPattern("effects.allow", pattern);
    for (effects_policy.deny) |pattern| try validateEffectPattern("effects.deny", pattern);
    for (effects_policy.ask) |pattern| try validateEffectPattern("effects.ask", pattern);
}

fn validateEffectPattern(label: []const u8, pattern: []const u8) !void {
    try validatePatternString(label, pattern, core.limits.max_event_field_len);
    if (!effects.isValidEffectPattern(pattern)) return error.InvalidPolicy;
}

fn validateEnv(env: schema.EnvPolicy) !void {
    for (env.allow) |name| try validatePatternString("env.allow", name, core.limits.max_env_name_len);
    for (env.deny_patterns) |pattern| try validatePatternString("env.deny_patterns", pattern, core.limits.max_env_name_len);
    for (env.ask) |pattern| try validatePatternString("env.ask", pattern, core.limits.max_env_name_len);
}

fn validateRuleSet(label: []const u8, rules: schema.RuleSet, max_len: usize) !void {
    for (rules.allow) |rule| try validatePatternString(label, rule, max_len);
    for (rules.deny) |rule| try validatePatternString(label, rule, max_len);
    for (rules.ask) |rule| try validatePatternString(label, rule, max_len);
}

fn validateNetwork(network: schema.NetworkPolicy) !void {
    for (network.allow) |rule| try validatePatternString("network.allow", rule, core.limits.max_url_len);
    for (network.deny) |rule| try validatePatternString("network.deny", rule, core.limits.max_url_len);
    for (network.ask) |rule| try validatePatternString("network.ask", rule, core.limits.max_url_len);
}

fn validateCredentials(credentials: schema.CredentialsPolicy) !void {
    if (credentials.default_broker) |default_broker| {
        try validateCredentialReference(default_broker);
        if (credentials.brokers.len > 0 and !hasBroker(credentials, default_broker)) return error.InvalidPolicy;
    }
    for (credentials.brokers, 0..) |broker, index| {
        try validateCredentialReference(broker.name);
        for (credentials.brokers[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, broker.name)) return error.InvalidPolicy;
        }
        if (broker.account) |account| try validateSafePolicyValue("credentials.brokers.account", account, core.limits.max_event_field_len);
        if (broker.path) |path| {
            try validateSafePolicyValue("credentials.brokers.path", path, core.limits.max_path_len);
            if (broker.kind == .env_file_dev) try validateDevEnvFilePath(path);
        } else if (broker.kind == .env_file_dev) {
            return error.InvalidPolicy;
        }
    }
    for (credentials.refs, 0..) |credential_ref, index| {
        try validateCredentialReference(credential_ref.name);
        for (credentials.refs[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, credential_ref.name)) return error.InvalidPolicy;
        }
        if (credential_ref.broker) |broker_name| {
            try validateCredentialReference(broker_name);
            if (credentials.brokers.len > 0 and !hasBroker(credentials, broker_name)) return error.InvalidPolicy;
        } else if (credentials.default_broker == null and credentials.brokers.len > 0) {
            return error.InvalidPolicy;
        }
        try validateSafePolicyValue("credentials.refs.ref", credential_ref.ref, core.limits.max_event_field_len);
    }
    for (credentials.grants, 0..) |grant, index| {
        try validateCredentialReference(grant.name);
        try validatePortableEnvName(grant.env_var);
        for (credentials.grants[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, grant.name)) return error.InvalidPolicy;
            if (std.ascii.eqlIgnoreCase(previous.env_var, grant.env_var)) return error.InvalidPolicy;
        }

        const required_host = switch (grant.provider) {
            .anthropic => "api.anthropic.com",
            .openai => "api.openai.com",
        };
        if (grant.allowed_hosts.len == 0) return error.InvalidPolicy;
        for (grant.allowed_hosts, 0..) |host, host_index| {
            try validateString("credentials.grants.allowed_hosts", host, core.limits.max_url_len);
            if (!std.mem.eql(u8, host, required_host)) return error.InvalidPolicy;
            for (grant.allowed_hosts[0..host_index]) |previous| {
                if (std.ascii.eqlIgnoreCase(previous, host)) return error.InvalidPolicy;
            }
        }

        switch (grant.source) {
            .host_env => if (grant.credential_ref != null) return error.InvalidPolicy,
            .broker => {
                const credential_ref = grant.credential_ref orelse return error.InvalidPolicy;
                try validateCredentialReference(credential_ref);
                if (!hasCredentialRef(credentials, credential_ref)) return error.InvalidPolicy;
            },
        }
    }
}

fn validateServices(services: []const schema.ServicePolicy, credentials: schema.CredentialsPolicy) !void {
    for (services, 0..) |service, index| {
        try validatePatternString("services.name", service.name, core.limits.max_event_field_len);
        for (services[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, service.name)) return error.InvalidPolicy;
        }
        if (service.hosts.len == 0) return error.InvalidPolicy;
        for (service.hosts) |host| try validatePatternString("services.hosts", host, core.limits.max_url_len);
        for (service.methods) |method| {
            try validatePatternString("services.methods", method, 16);
            for (method) |char| {
                if (!(std.ascii.isUpper(char) or char == '*')) return error.InvalidPolicy;
            }
        }
        for (service.paths.allow) |path| try validatePatternString("services.paths.allow", path, core.limits.max_url_len);
        for (service.paths.deny) |path| try validatePatternString("services.paths.deny", path, core.limits.max_url_len);
        if (service.credentials.use) |credential| {
            try validateCredentialReference(credential);
            if (credentials.refs.len > 0 and !hasCredentialRef(credentials, credential)) return error.InvalidPolicy;
        }
    }
}

fn hasBroker(credentials: schema.CredentialsPolicy, name: []const u8) bool {
    for (credentials.brokers) |broker| {
        if (std.ascii.eqlIgnoreCase(broker.name, name)) return true;
    }
    return false;
}

fn hasCredentialRef(credentials: schema.CredentialsPolicy, name: []const u8) bool {
    for (credentials.refs) |credential_ref| {
        if (std.ascii.eqlIgnoreCase(credential_ref.name, name)) return true;
    }
    return false;
}

fn validateCredentialReference(value: []const u8) !void {
    try validateString("services.credentials.use", value, core.limits.max_event_field_len);
    if (audit_redact.classifyString(value) != null) return error.InvalidPolicy;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        switch (char) {
            '_', '-', '.', ':', '@' => continue,
            else => return error.InvalidPolicy,
        }
    }
}

fn validatePortableEnvName(value: []const u8) !void {
    try validateString("credentials.grants.env_var", value, core.limits.max_env_name_len);
    if (!(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return error.InvalidPolicy;
    for (value[1..]) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_')) return error.InvalidPolicy;
    }
}

fn validateSafePolicyValue(label: []const u8, value: []const u8, max_len: usize) !void {
    try validatePatternString(label, value, max_len);
    if (audit_redact.classifyString(value) != null) return error.InvalidPolicy;
}

fn validateDevEnvFilePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return error.InvalidPolicy;
    if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidPolicy;
    if (!(std.mem.startsWith(u8, path, ".orca/") or std.mem.startsWith(u8, path, ".orca\\"))) return error.InvalidPolicy;
    if (std.mem.indexOf(u8, path, "dev") == null or !std.mem.endsWith(u8, path, ".env")) return error.InvalidPolicy;
}

fn validateString(_: []const u8, value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return error.InvalidPolicy;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidPolicy;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPolicy;
}

fn validatePatternString(label: []const u8, value: []const u8, max_len: usize) !void {
    try validateString(label, value, max_len);
    for (value) |char| {
        if (char < 0x20) return error.InvalidPolicy;
    }
}

test "built-in presets validate" {
    const load = @import("load.zig");

    var observe = try load.loadPreset(std.testing.allocator, .observe);
    defer observe.deinit();
    try policy(&observe);

    var ask = try load.loadPreset(std.testing.allocator, .ask);
    defer ask.deinit();
    try policy(&ask);

    var strict = try load.loadPreset(std.testing.allocator, .strict);
    defer strict.deinit();
    try policy(&strict);

    var ci = try load.loadPreset(std.testing.allocator, .ci);
    defer ci.deinit();
    try policy(&ci);

    for (@import("presets.zig").agent_preset_infos) |info| {
        var agent_preset = try load.loadAgentPreset(std.testing.allocator, info.preset);
        defer agent_preset.deinit();
        try policy(&agent_preset);
    }
}

test "policy rejects disabling persisted secret redaction" {
    const load = @import("load.zig");
    var loaded = try load.loadPreset(std.testing.allocator, .observe);
    defer loaded.deinit();
    loaded.audit.redact_secrets = false;
    try std.testing.expectError(error.InvalidPolicy, policy(&loaded));
}

test "policy patterns with unsafe control characters are rejected" {
    const load = @import("load.zig");
    const bad = "version: 1\nmode: strict\nfiles:\n  read:\n    deny:\n      - \"./bad\x1bpath\"\n";
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, bad, "bad.yaml"));
}

test "service credential use rejects secret-like values" {
    const load = @import("load.zig");
    const bad =
        \\version: 1
        \\mode: strict
        \\services:
        \\  github:
        \\    hosts:
        \\      - "api.github.com"
        \\    credentials:
        \\      use: "ghp_fakeSyntheticTokenValue1234567890"
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, bad, "bad-credential.yaml"));
}

test "duplicate service names are rejected" {
    const load = @import("load.zig");
    const bad =
        \\version: 1
        \\mode: strict
        \\services:
        \\  github:
        \\    hosts:
        \\      - "api.github.com"
        \\  GitHub:
        \\    hosts:
        \\      - "uploads.github.com"
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, bad, "duplicate-services.yaml"));
}

test "credential config rejects unsafe refs and env-file paths" {
    const load = @import("load.zig");
    const missing_ref =
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  refs:
        \\    github_pat:
        \\      ref: "GITHUB_PAT"
        \\services:
        \\  github:
        \\    hosts:
        \\      - "api.github.com"
        \\    credentials:
        \\      use: missing_ref
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, missing_ref, "missing-ref.yaml"));

    const unsafe_path =
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  brokers:
        \\    env_dev:
        \\      type: env-file-dev
        \\      path: /tmp/secrets.env
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, unsafe_path, "unsafe-env-path.yaml"));

    const raw_secret =
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  refs:
        \\    github_pat:
        \\      ref: "ghp_fakeSyntheticTokenValue1234567890"
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, raw_secret, "raw-secret-ref.yaml"));
}

test "duplicate credential brokers and refs are rejected" {
    const load = @import("load.zig");
    const duplicate_brokers =
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  brokers:
        \\    env_dev:
        \\      type: env-file-dev
        \\      path: .orca/dev-secrets.env
        \\    ENV_DEV:
        \\      type: local-dummy
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, duplicate_brokers, "duplicate-brokers.yaml"));

    const duplicate_refs =
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  refs:
        \\    github_pat:
        \\      ref: "GITHUB_PAT"
        \\    GITHUB_PAT:
        \\      ref: "OTHER_PAT"
    ;
    try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, duplicate_refs, "duplicate-refs.yaml"));
}

test "credential grants reject duplicates invalid hosts and nonportable env names" {
    const load = @import("load.zig");
    const bad_policies = [_][]const u8{
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: host_env
        \\      allowed_hosts:
        \\        - api.anthropic.com
        \\    Anthropic:
        \\      env_var: OTHER_ANTHROPIC_KEY
        \\      provider: anthropic
        \\      source: host_env
        \\      allowed_hosts:
        \\        - api.anthropic.com
        ,
        \\{"version":1,"mode":"strict","credentials":{"grants":{"anthropic":{"env_var":"MODEL_API_KEY","provider":"anthropic","source":"host_env","allowed_hosts":["api.anthropic.com"]},"openai":{"env_var":"MODEL_API_KEY","provider":"openai","source":"host_env","allowed_hosts":["api.openai.com"]}}}}
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: host_env
        \\      allowed_hosts:
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: host_env
        \\      allowed_hosts:
        \\        - api.openai.com
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    openai:
        \\      env_var: OPENAI_API_KEY
        \\      provider: openai
        \\      source: host_env
        \\      allowed_hosts:
        \\        - "*.openai.com"
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    openai:
        \\      env_var: 9OPENAI_API_KEY
        \\      provider: openai
        \\      source: host_env
        \\      allowed_hosts:
        \\        - api.openai.com
        ,
    };
    for (bad_policies, 0..) |bad, index| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "bad-grant-{d}.yaml", .{index});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, bad, source));
    }
}

test "credential grant sources enforce credential reference contracts" {
    const load = @import("load.zig");
    const bad_policies = [_][]const u8{
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: broker
        \\      allowed_hosts:
        \\        - api.anthropic.com
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: broker
        \\      credential_ref: missing
        \\      allowed_hosts:
        \\        - api.anthropic.com
        ,
        \\version: 1
        \\mode: strict
        \\credentials:
        \\  refs:
        \\    anthropic_key:
        \\      ref: ANTHROPIC_API_KEY
        \\  grants:
        \\    anthropic:
        \\      env_var: ANTHROPIC_API_KEY
        \\      provider: anthropic
        \\      source: host_env
        \\      credential_ref: anthropic_key
        \\      allowed_hosts:
        \\        - api.anthropic.com
        ,
    };
    for (bad_policies, 0..) |bad, index| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "bad-grant-source-{d}.yaml", .{index});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidPolicy, load.parseFromSlice(std.testing.allocator, bad, source));
    }
}

test "literal bracketed policy paths validate and match literally" {
    const load = @import("load.zig");
    const matchers = @import("matchers.zig");
    var loaded = try load.parseFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: strict
        \\files:
        \\  read:
        \\    allow:
        \\      - "./src/routes/[id]/+page.svelte"
        \\      - "./docs/[draft].md"
    , "brackets.yaml");
    defer loaded.deinit();

    try std.testing.expectEqualStrings("./src/routes/[id]/+page.svelte", loaded.files.read.allow[0]);
    try std.testing.expect(matchers.matchesPath(loaded.files.read.allow[0], "./src/routes/[id]/+page.svelte"));
    try std.testing.expect(matchers.matchesPath(loaded.files.read.allow[1], "./docs/[draft].md"));
}

test "all policy preset files under policies/presets validate" {
    const load = @import("load.zig");
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "policies/presets", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        const path = try std.fs.path.join(std.testing.allocator, &.{ "policies/presets", entry.name });
        defer std.testing.allocator.free(path);
        var loaded = try load.loadFile(std.testing.io, std.testing.allocator, path);
        defer loaded.deinit();
        try policy(&loaded);
        count += 1;
    }
    try std.testing.expect(count >= 10);
}
