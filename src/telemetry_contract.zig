const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("ryk_core").core;
const host_launch = @import("cli/host_launch.zig");
const exit_codes = @import("cli/exit_codes.zig");
const product = @import("telemetry_product.zig");

pub const event_name = "ryk_cli_command";
pub const fm_summary_event_name = "ryk_fm_steward_summary";
pub const enforcement_summary_event_name = "ryk_enforcement_summary";
pub const integration_summary_event_name = "ryk_integration_summary";
pub const session_summary_event_name = "ryk_session_summary";
pub const feature_summary_event_name = "ryk_feature_summary";
pub const reliability_summary_event_name = "ryk_reliability_summary";
pub const schema_version: i64 = 1;
pub const posthog_batch_endpoint = "https://us.i.posthog.com/batch/";
pub const max_queue_events = 64;
pub const max_event_bytes = 16 * 1024;
pub const max_summary_count: u32 = 1_000_000;
pub const transport_marker = if (build_options.posthog_project_token.len == 0)
    "ryk-telemetry-transport-disabled-v1"
else
    "ryk-telemetry-transport-enabled-v1";

pub const Invocation = struct {
    command: []const u8,
    host: []const u8,
    outcome: []const u8,
};

pub const FmSummary = struct {
    host: []const u8,
    source: []const u8,
    verdict: []const u8,
    status: []const u8,
    model_available: bool,
    timed_out: bool,
    upgraded: bool,
    latency_bucket: []const u8,
    count: u32,
};

pub const EnforcementSummary = struct {
    host: []const u8,
    source: []const u8,
    decision: []const u8,
    risk: []const u8,
    effect: []const u8,
    mode: []const u8,
    count: u32,
};

pub const IntegrationSummary = struct {
    host: []const u8,
    operation: []const u8,
    result: []const u8,
    count: u32,
};

pub const SessionSummary = struct {
    host: []const u8,
    event_type: []const u8,
    result: []const u8,
    count: u32,
};

pub const FeatureSummary = struct {
    feature: []const u8,
    operation: []const u8,
    result: []const u8,
    count: u32,
};

pub const ReliabilitySummary = struct {
    operation: []const u8,
    failure: []const u8,
    source: []const u8,
    count: u32,
};

pub const Summary = union(enum) {
    fm: FmSummary,
    enforcement: EnforcementSummary,
    integration: IntegrationSummary,
    session: SessionSummary,
    feature: FeatureSummary,
    reliability: ReliabilitySummary,
};

pub fn validInvocation(invocation: Invocation) bool {
    if (!validCommand(invocation.command)) return false;
    if (!std.mem.eql(u8, invocation.host, "none") and !host_launch.isHostLaunchAlias(invocation.host)) return false;
    if (!validOutcome(invocation.outcome)) return false;
    if (std.mem.eql(u8, invocation.command, "host_launch") != !std.mem.eql(u8, invocation.host, "none")) return false;
    return true;
}

pub fn validCommand(command_name: []const u8) bool {
    if (std.mem.eql(u8, command_name, "host_launch")) return true;
    const commands = [_][]const u8{
        "run",       "start", "init",    "doctor",     "policy", "credentials", "replay",    "scan",   "packs",
        "allowlist", "allow", "unallow", "allow-once", "stop",   "disable",     "uninstall", "update", "shutdown",
        "feedback",
    };
    for (commands) |candidate| if (std.mem.eql(u8, command_name, candidate)) return true;
    return false;
}

pub fn validOutcome(outcome: []const u8) bool {
    const outcomes = [_][]const u8{ "success", "denied", "ask", "warning", "usage_error", "failure" };
    for (outcomes) |candidate| if (std.mem.eql(u8, outcome, candidate)) return true;
    return false;
}

pub fn validHost(value: []const u8) bool {
    if (std.mem.eql(u8, value, "none") or std.mem.eql(u8, value, "all") or
        std.mem.eql(u8, value, "other") or std.mem.eql(u8, value, "pi") or
        std.mem.eql(u8, value, "cursor")) return true;
    return host_launch.isHostLaunchAlias(value);
}

pub fn sanitizeHost(value: ?[]const u8) []const u8 {
    const candidate = value orelse "none";
    if (std.mem.eql(u8, candidate, "none")) return "none";
    if (std.mem.eql(u8, candidate, "all")) return "all";
    if (std.mem.eql(u8, candidate, "other")) return "other";
    if (std.mem.eql(u8, candidate, "pi")) return "pi";
    if (std.mem.eql(u8, candidate, "cursor")) return "cursor";
    if (std.mem.eql(u8, candidate, "claude")) return "claude";
    if (std.mem.eql(u8, candidate, "codex")) return "codex";
    if (std.mem.eql(u8, candidate, "opencode")) return "opencode";
    if (std.mem.eql(u8, candidate, "openclaw")) return "openclaw";
    if (std.mem.eql(u8, candidate, "hermes")) return "hermes";
    if (std.mem.eql(u8, candidate, "grok")) return "grok";
    return "other";
}

pub fn validSource(value: []const u8) bool {
    const sources = [_][]const u8{ "cli", "hook", "evaluate", "run", "integration", "fm_steward", "other" };
    for (sources) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

pub fn sanitizeSource(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "cli")) return "cli";
    if (std.mem.eql(u8, value, "hook")) return "hook";
    if (std.mem.eql(u8, value, "evaluate")) return "evaluate";
    if (std.mem.eql(u8, value, "run")) return "run";
    if (std.mem.eql(u8, value, "integration")) return "integration";
    if (std.mem.eql(u8, value, "fm_steward")) return "fm_steward";
    return "other";
}

pub fn latencyBucket(latency_ms: ?i64) []const u8 {
    const value = latency_ms orelse return "unknown";
    if (value < 10) return "under_10ms";
    if (value < 50) return "10_49ms";
    if (value < 250) return "50_249ms";
    if (value < 1000) return "250_999ms";
    return "1000ms_or_more";
}

fn validLatencyBucket(value: []const u8) bool {
    const values = [_][]const u8{ "under_10ms", "10_49ms", "50_249ms", "250_999ms", "1000ms_or_more", "unknown" };
    for (values) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validCount(count: u32) bool {
    return count > 0 and count <= max_summary_count;
}

pub fn validSummary(summary: Summary) bool {
    return switch (summary) {
        .fm => |value| validFmSummary(value),
        .enforcement => |value| validEnforcementSummary(value),
        .integration => |value| validIntegrationSummary(value),
        .session => |value| validSessionSummary(value),
        .feature => |value| validFeatureSummary(value),
        .reliability => |value| validReliabilitySummary(value),
    };
}

pub fn summaryEventName(summary: Summary) []const u8 {
    return switch (summary) {
        .fm => fm_summary_event_name,
        .enforcement => enforcement_summary_event_name,
        .integration => integration_summary_event_name,
        .session => session_summary_event_name,
        .feature => feature_summary_event_name,
        .reliability => reliability_summary_event_name,
    };
}

pub fn validFmSummary(value: FmSummary) bool {
    return validHost(value.host) and validSource(value.source) and validFmVerdict(value.verdict) and
        validFmStatus(value.status) and validLatencyBucket(value.latency_bucket) and validCount(value.count);
}

pub fn validEnforcementSummary(value: EnforcementSummary) bool {
    return validHost(value.host) and validSource(value.source) and validDecision(value.decision) and
        validRisk(value.risk) and validEffect(value.effect) and validMode(value.mode) and validCount(value.count);
}

pub fn validIntegrationSummary(value: IntegrationSummary) bool {
    return validHost(value.host) and validIntegrationOperation(value.operation) and
        validIntegrationResult(value.result) and validCount(value.count);
}

pub fn validSessionSummary(value: SessionSummary) bool {
    return validHost(value.host) and validSessionEvent(value.event_type) and
        validSessionResult(value.result) and validCount(value.count);
}

pub fn validFeatureSummary(value: FeatureSummary) bool {
    return validFeature(value.feature) and validOperation(value.operation) and
        validResult(value.result) and validCount(value.count);
}

pub fn validReliabilitySummary(value: ReliabilitySummary) bool {
    return validOperation(value.operation) and validFailure(value.failure) and
        validSource(value.source) and validCount(value.count);
}

fn validFmVerdict(value: []const u8) bool {
    return std.mem.eql(u8, value, "continue") or std.mem.eql(u8, value, "ask") or
        std.mem.eql(u8, value, "ask_sticky_candidate");
}

fn validFmStatus(value: []const u8) bool {
    return std.mem.eql(u8, value, "model") or std.mem.eql(u8, value, "no_model") or
        std.mem.eql(u8, value, "fallback") or std.mem.eql(u8, value, "timeout");
}

fn validDecision(value: []const u8) bool {
    return std.mem.eql(u8, value, "allow") or std.mem.eql(u8, value, "observe") or
        std.mem.eql(u8, value, "ask") or std.mem.eql(u8, value, "deny") or
        std.mem.eql(u8, value, "error");
}

fn validRisk(value: []const u8) bool {
    return std.mem.eql(u8, value, "low") or std.mem.eql(u8, value, "medium") or
        std.mem.eql(u8, value, "high") or std.mem.eql(u8, value, "critical") or
        std.mem.eql(u8, value, "unknown");
}

fn validEffect(value: []const u8) bool {
    const effects = [_][]const u8{ "shell", "file_read", "file_write", "network", "tool", "prompt", "environment", "other" };
    for (effects) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validMode(value: []const u8) bool {
    const modes = [_][]const u8{ "observe", "ask", "yolo", "strict", "ci", "redteam", "trusted", "unknown" };
    for (modes) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validIntegrationOperation(value: []const u8) bool {
    const operations = [_][]const u8{ "install", "verify", "inspect", "repair", "onboard", "remove", "other" };
    for (operations) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validIntegrationResult(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or std.mem.eql(u8, value, "blocked") or
        std.mem.eql(u8, value, "failure") or std.mem.eql(u8, value, "usage") or
        std.mem.eql(u8, value, "deferred");
}

fn validSessionEvent(value: []const u8) bool {
    const events = [_][]const u8{ "session_start", "session_end", "prompt", "pre_tool", "permission", "post_tool", "stop", "other" };
    for (events) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validSessionResult(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or std.mem.eql(u8, value, "blocked") or
        std.mem.eql(u8, value, "failure");
}

fn validFeature(value: []const u8) bool {
    const features = [_][]const u8{
        "help",      "version", "run",         "start",      "init",   "doctor",  "policy",    "credentials", "replay",   "scan",   "packs",
        "allowlist", "allow",   "unallow",     "allow-once", "stop",   "disable", "uninstall", "update",      "shutdown", "plugin", "mcp",
        "tools",     "redteam", "completions", "dashboard",  "report", "ci",      "env",       "explain",     "diff",     "apply",  "discard",
        "feedback",  "other",
    };
    for (features) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validOperation(value: []const u8) bool {
    const operations = [_][]const u8{
        "default", "doctor", "install", "verify", "inspect", "repair", "onboard",  "remove", "list",       "manifest",
        "serve",   "run",    "status",  "enable", "disable", "hook",   "evaluate", "cli",    "fm_steward", "other",
    };
    for (operations) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validResult(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or std.mem.eql(u8, value, "denied") or
        std.mem.eql(u8, value, "ask") or std.mem.eql(u8, value, "warning") or
        std.mem.eql(u8, value, "usage_error") or std.mem.eql(u8, value, "failure");
}

fn validFailure(value: []const u8) bool {
    const failures = [_][]const u8{
        "usage", "evaluator_error", "protocol_error", "timeout", "policy_load", "hook_failure", "command_failure", "other",
    };
    for (failures) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

pub fn classifyInvocation(argv: []const []const u8, exit_code: u8) ?Invocation {
    var command_index: usize = 0;
    while (command_index < argv.len and std.mem.eql(u8, argv[command_index], "--no-rich")) : (command_index += 1) {}
    if (command_index == argv.len) return null;
    const command_argv = argv[command_index..];
    if (hasExcludedFlag(command_argv)) return null;
    const command_name = command_argv[0];
    if (host_launch.isHostLaunchAlias(command_name)) {
        return .{
            .command = "host_launch",
            .host = command_name,
            .outcome = outcomeForCommand("host_launch", exit_code),
        };
    }

    if (!validCommand(command_name) or std.mem.eql(u8, command_name, "host_launch")) return null;
    return .{ .command = command_name, .host = "none", .outcome = outcomeForCommand(command_name, exit_code) };
}

fn hasExcludedFlag(argv: []const []const u8) bool {
    var scan_len = argv.len;
    if (argv.len > 0 and host_launch.isHostLaunchAlias(argv[0])) {
        scan_len = 1;
    } else if (argv.len > 0 and std.mem.eql(u8, argv[0], "run")) {
        for (argv[1..], 1..) |arg, index| {
            if (std.mem.eql(u8, arg, "--")) {
                scan_len = index;
                break;
            }
        }
    }

    for (argv[0..scan_len], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--stdin") or
            std.mem.eql(u8, arg, "--robot") or std.mem.eql(u8, arg, "--raw") or
            std.mem.eql(u8, arg, "--ci") or std.mem.eql(u8, arg, "--machine") or
            std.mem.eql(u8, arg, "--dry-run")) return true;
        if ((std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) and index + 1 < argv.len and
            (std.mem.eql(u8, argv[index + 1], "json") or std.mem.eql(u8, argv[index + 1], "markdown"))) return true;
        if (std.mem.startsWith(u8, arg, "--format=") and
            (std.mem.eql(u8, arg[9..], "json") or std.mem.eql(u8, arg[9..], "markdown"))) return true;
        if (std.mem.eql(u8, arg, "--mode") and index + 1 < argv.len and std.mem.eql(u8, argv[index + 1], "ci")) return true;
    }
    return false;
}

pub fn classifyFeatureInvocation(argv: []const []const u8, exit_code: u8) ?FeatureSummary {
    var command_index: usize = 0;
    while (command_index < argv.len and std.mem.eql(u8, argv[command_index], "--no-rich")) : (command_index += 1) {}
    if (command_index == argv.len) return null;
    const command_argv = argv[command_index..];
    if (hasExcludedFlag(command_argv)) return null;

    const command_name = command_argv[0];
    // Telemetry controls are privacy controls, not product usage. Never let a
    // status/enable/disable command create an analytics event about itself.
    if (std.mem.eql(u8, command_name, "telemetry")) return null;
    const feature = if (host_launch.isHostLaunchAlias(command_name)) "run" else featureName(command_name) orelse return null;
    if (std.mem.eql(u8, feature, "other")) return null;
    return .{
        .feature = feature,
        .operation = featureOperation(feature, command_argv[1..]),
        .result = outcomeForCommand(command_name, exit_code),
        .count = 1,
    };
}

pub fn classifySessionInvocation(argv: []const []const u8, exit_code: u8) ?SessionSummary {
    var command_index: usize = 0;
    while (command_index < argv.len and std.mem.eql(u8, argv[command_index], "--no-rich")) : (command_index += 1) {}
    if (command_index == argv.len) return null;
    const command_argv = argv[command_index..];
    if (hasExcludedFlag(command_argv) or command_argv.len < 3 or !std.mem.eql(u8, command_argv[0], "hook")) return null;
    const host = command_argv[1];
    if (!validHost(host) or std.mem.eql(u8, host, "none") or std.mem.eql(u8, host, "all") or std.mem.eql(u8, host, "other")) return null;
    const event_type = sessionEventType(command_argv[2]) orelse return null;
    return .{
        .host = sanitizeHost(host),
        .event_type = event_type,
        .result = if (exit_code == exit_codes.success) "success" else if (exit_code == exit_codes.denial) "blocked" else "failure",
        .count = 1,
    };
}

pub fn classifyIntegrationInvocation(argv: []const []const u8, exit_code: u8) ?IntegrationSummary {
    var command_index: usize = 0;
    while (command_index < argv.len and std.mem.eql(u8, argv[command_index], "--no-rich")) : (command_index += 1) {}
    if (command_index == argv.len) return null;
    const command_argv = argv[command_index..];
    if (hasExcludedFlag(command_argv)) return null;

    var operation: []const u8 = "other";
    var host: []const u8 = "all";
    if (std.mem.eql(u8, command_argv[0], "start")) {
        operation = "onboard";
    } else if (std.mem.eql(u8, command_argv[0], "doctor") and containsFixedArg(command_argv[1..], "--fix")) {
        operation = "repair";
    } else if (std.mem.eql(u8, command_argv[0], "plugin")) {
        const plugin_operation = firstKnownOperation(command_argv[1..]) orelse return null;
        operation = switch (plugin_operation) {
            .install => "install",
            // Plain plugin doctor records its authoritative health result at
            // the report boundary in cli/plugin.zig.
            .doctor => return null,
            .list, .manifest => "inspect",
        };
        if (std.mem.eql(u8, operation, "install") or std.mem.eql(u8, operation, "verify")) host = pluginTarget(command_argv[2..]);
    } else return null;

    return .{
        .host = sanitizeHost(host),
        .operation = operation,
        .result = integrationResult(exit_code),
        .count = 1,
    };
}

pub fn classifyReliabilityInvocation(argv: []const []const u8, exit_code: u8) ?ReliabilitySummary {
    var command_index: usize = 0;
    while (command_index < argv.len and std.mem.eql(u8, argv[command_index], "--no-rich")) : (command_index += 1) {}
    if (command_index == argv.len) return null;
    const command_argv = argv[command_index..];
    if (hasExcludedFlag(command_argv)) return null;
    const command_name = command_argv[0];
    // Evaluate records detailed failure classes at its protocol/evaluator
    // boundaries. The generic process-exit classifier would double count it.
    if (std.mem.eql(u8, command_name, "evaluate")) return null;
    if (exit_code == exit_codes.success or exit_code == exit_codes.ask or exit_code == exit_codes.warn or
        (exit_code == exit_codes.denial and !std.mem.eql(u8, command_name, "evaluate")) or
        (std.mem.eql(u8, command_name, "hook") and exit_code == 2)) return null;

    const operation: []const u8 = if (std.mem.eql(u8, command_name, "hook")) "hook" else if (std.mem.eql(u8, command_name, "evaluate")) "evaluate" else if (std.mem.eql(u8, command_name, "run")) "run" else "cli";
    const failure: []const u8 = if (exit_code == exit_codes.usage) "usage" else if ((std.mem.eql(u8, command_name, "evaluate") or std.mem.eql(u8, command_name, "run")) and exit_code == 3)
        "evaluator_error"
    else if (std.mem.eql(u8, command_name, "hook")) "hook_failure" else "command_failure";
    return .{ .operation = operation, .failure = failure, .source = operation, .count = 1 };
}

fn featureOperation(feature: []const u8, args: []const []const u8) []const u8 {
    if (args.len == 0) return "default";
    if (std.mem.eql(u8, feature, "plugin")) {
        if (std.mem.eql(u8, args[0], "install")) return "install";
        if (std.mem.eql(u8, args[0], "doctor")) return "doctor";
        if (std.mem.eql(u8, args[0], "list")) return "list";
        if (std.mem.eql(u8, args[0], "manifest")) return "manifest";
        if (std.mem.eql(u8, args[0], "mcp-server")) return "serve";
        return "other";
    }
    if (std.mem.eql(u8, feature, "mcp") or std.mem.eql(u8, feature, "tools") or
        std.mem.eql(u8, feature, "redteam"))
    {
        if (std.mem.eql(u8, args[0], "list")) return "list";
        if (std.mem.eql(u8, args[0], "serve")) return "serve";
        if (std.mem.eql(u8, args[0], "run")) return "run";
        return "other";
    }
    if (std.mem.eql(u8, feature, "dashboard") or std.mem.eql(u8, feature, "report") or
        std.mem.eql(u8, feature, "completions")) return "default";
    return "default";
}

const KnownOperation = enum { install, doctor, list, manifest };

fn firstKnownOperation(args: []const []const u8) ?KnownOperation {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "install")) return .install;
        if (std.mem.eql(u8, arg, "doctor")) return .doctor;
        if (std.mem.eql(u8, arg, "list")) return .list;
        if (std.mem.eql(u8, arg, "manifest")) return .manifest;
    }
    return null;
}

fn pluginTarget(args: []const []const u8) []const u8 {
    for (args) |arg| {
        const host = sanitizeHost(arg);
        if (!std.mem.eql(u8, host, "other")) return host;
    }
    return "all";
}

fn featureName(value: []const u8) ?[]const u8 {
    const features = [_][]const u8{
        "help",     "version",   "run",   "start",   "init",       "doctor",      "policy",    "credentials", "replay", "scan",
        "packs",    "allowlist", "allow", "unallow", "allow-once", "stop",        "disable",   "uninstall",   "update", "shutdown",
        "feedback", "plugin",    "mcp",   "tools",   "redteam",    "completions", "dashboard", "report",      "ci",     "env",
        "explain",  "diff",      "apply", "discard",
    };
    for (features) |feature| if (std.mem.eql(u8, value, feature)) return feature;
    return null;
}

fn containsFixedArg(args: []const []const u8, candidate: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, candidate)) return true;
    return false;
}

fn integrationResult(code: u8) []const u8 {
    return if (code == exit_codes.success) "success" else if (code == exit_codes.usage) "usage" else if (code == exit_codes.denial) "blocked" else "failure";
}

pub fn sessionEventType(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "SessionStart") or std.mem.eql(u8, value, "session_start") or
        std.mem.eql(u8, value, "sessionStart") or std.mem.eql(u8, value, "session.created") or
        std.mem.eql(u8, value, "session.start") or std.mem.eql(u8, value, "on_session_start")) return "session_start";
    if (std.mem.eql(u8, value, "SessionEnd") or std.mem.eql(u8, value, "session_end") or
        std.mem.eql(u8, value, "sessionEnd") or std.mem.eql(u8, value, "session.end") or
        std.mem.eql(u8, value, "on_session_end") or std.mem.eql(u8, value, "on_session_finalize") or
        std.mem.eql(u8, value, "on_session_reset")) return "session_end";
    if (std.mem.eql(u8, value, "UserPromptSubmit") or std.mem.eql(u8, value, "user_prompt_submit") or
        std.mem.eql(u8, value, "pre_llm_call")) return "prompt";
    if (std.mem.eql(u8, value, "PreToolUse") or std.mem.eql(u8, value, "pre_tool_call") or
        std.mem.eql(u8, value, "tool.execute.before") or std.mem.eql(u8, value, "command.execute.before") or
        std.mem.eql(u8, value, "tool.before")) return "pre_tool";
    if (std.mem.eql(u8, value, "PermissionRequest") or std.mem.eql(u8, value, "permission.asked") or
        std.mem.eql(u8, value, "permission.before") or std.mem.eql(u8, value, "permission.replied") or
        std.mem.eql(u8, value, "permission.after")) return "permission";
    if (std.mem.eql(u8, value, "PostToolUse") or std.mem.eql(u8, value, "post_tool_call") or
        std.mem.eql(u8, value, "tool.execute.after") or std.mem.eql(u8, value, "command.executed") or
        std.mem.eql(u8, value, "tool.after")) return "post_tool";
    if (std.mem.eql(u8, value, "Stop") or std.mem.eql(u8, value, "subagent_stop")) return "stop";
    return null;
}

fn outcomeForCommand(command_name: []const u8, code: u8) []const u8 {
    // `run` and host aliases mirror arbitrary child exit codes. Only zero is
    // authoritative there; numeric values such as 2 or 3 are not Ryk policy
    // outcomes unless Ryk itself produced them before child launch.
    if (std.mem.eql(u8, command_name, "run") or std.mem.eql(u8, command_name, "host_launch")) {
        return if (code == exit_codes.success) "success" else "failure";
    }
    return switch (code) {
        exit_codes.success => "success",
        exit_codes.denial => "denied",
        exit_codes.ask => "ask",
        exit_codes.warn => "warning",
        exit_codes.usage => "usage_error",
        else => "failure",
    };
}

pub fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "other",
    };
}

pub fn validOsName(value: []const u8) bool {
    return std.mem.eql(u8, value, "macos") or std.mem.eql(u8, value, "linux") or
        std.mem.eql(u8, value, "windows") or std.mem.eql(u8, value, "other");
}

pub fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        .x86 => "x86",
        .arm => "arm",
        else => "other",
    };
}

pub fn validArchName(value: []const u8) bool {
    return std.mem.eql(u8, value, "aarch64") or std.mem.eql(u8, value, "x86_64") or
        std.mem.eql(u8, value, "x86") or std.mem.eql(u8, value, "arm") or std.mem.eql(u8, value, "other");
}

pub fn rejectUnknownKeys(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidTelemetryState;
    }
}

pub fn validQueuedEvent(value: std.json.Value) bool {
    if (product.validQueuedEvent(value)) return true;
    if (value != .object) return false;
    const root = value.object;
    rejectUnknownKeys(root, &.{ "event", "properties" }) catch return false;
    const event_value = root.get("event") orelse return false;
    if (event_value != .string) return false;
    const properties_value = root.get("properties") orelse return false;
    if (properties_value != .object) return false;

    if (std.mem.eql(u8, event_value.string, event_name)) return validCommandEvent(properties_value.object);
    if (std.mem.eql(u8, event_value.string, fm_summary_event_name) or
        std.mem.eql(u8, event_value.string, enforcement_summary_event_name) or
        std.mem.eql(u8, event_value.string, integration_summary_event_name) or
        std.mem.eql(u8, event_value.string, session_summary_event_name) or
        std.mem.eql(u8, event_value.string, feature_summary_event_name) or
        std.mem.eql(u8, event_value.string, reliability_summary_event_name))
    {
        return validSummaryEvent(event_value.string, properties_value.object);
    }
    return false;
}

fn validCommandEvent(properties: std.json.ObjectMap) bool {
    rejectUnknownKeys(properties, &.{
        "distinct_id",
        "$process_person_profile",
        "$ip",
        "telemetry_schema_version",
        "command",
        "host",
        "outcome",
        "product_version",
        "os",
        "arch",
        "occurred_at",
    }) catch return false;

    const distinct_id = properties.get("distinct_id") orelse return false;
    if (distinct_id != .string or !validInstallationId(distinct_id.string)) return false;
    const profile = properties.get("$process_person_profile") orelse return false;
    if (profile != .bool or profile.bool) return false;
    const ip = properties.get("$ip") orelse return false;
    if (ip != .integer or ip.integer != 0) return false;
    const version = properties.get("telemetry_schema_version") orelse return false;
    if (version != .integer or version.integer != schema_version) return false;

    const command_value = properties.get("command") orelse return false;
    if (command_value != .string or !validCommand(command_value.string)) return false;
    const host_value = properties.get("host") orelse return false;
    if (host_value != .string or (!std.mem.eql(u8, host_value.string, "none") and
        !host_launch.isHostLaunchAlias(host_value.string))) return false;
    if (std.mem.eql(u8, command_value.string, "host_launch") !=
        !std.mem.eql(u8, host_value.string, "none")) return false;

    const outcome = properties.get("outcome") orelse return false;
    if (outcome != .string or !validOutcome(outcome.string)) return false;
    const product_version = properties.get("product_version") orelse return false;
    if (product_version != .string or !validVersionToken(product_version.string)) return false;
    const os = properties.get("os") orelse return false;
    if (os != .string or !validOsName(os.string)) return false;
    const arch = properties.get("arch") orelse return false;
    if (arch != .string or !validArchName(arch.string)) return false;
    const occurred_at = properties.get("occurred_at") orelse return false;
    if (occurred_at != .string or !validTimestamp(occurred_at.string)) return false;
    return true;
}

fn validSummaryEvent(event: []const u8, properties: std.json.ObjectMap) bool {
    const allowed: []const []const u8 = if (std.mem.eql(u8, event, fm_summary_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "host", "source", "verdict", "status", "model_available", "timed_out", "upgraded", "latency_bucket", "count", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, enforcement_summary_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "host", "source", "decision", "risk", "effect", "mode", "count", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, integration_summary_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "host", "operation", "result", "count", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, session_summary_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "host", "event_type", "result", "count", "product_version", "os", "arch", "occurred_at" }
    else if (std.mem.eql(u8, event, feature_summary_event_name))
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "feature", "operation", "result", "count", "product_version", "os", "arch", "occurred_at" }
    else
        &[_][]const u8{ "distinct_id", "$process_person_profile", "$ip", "telemetry_schema_version", "operation", "failure", "source", "count", "product_version", "os", "arch", "occurred_at" };
    rejectUnknownKeys(properties, allowed) catch return false;

    const distinct_id = properties.get("distinct_id") orelse return false;
    if (distinct_id != .string or !validInstallationId(distinct_id.string)) return false;
    const profile = properties.get("$process_person_profile") orelse return false;
    if (profile != .bool or profile.bool) return false;
    const ip = properties.get("$ip") orelse return false;
    if (ip != .integer or ip.integer != 0) return false;
    const version = properties.get("telemetry_schema_version") orelse return false;
    if (version != .integer or version.integer != schema_version) return false;
    const product_version = properties.get("product_version") orelse return false;
    if (product_version != .string or !validVersionToken(product_version.string)) return false;
    const os = properties.get("os") orelse return false;
    if (os != .string or !validOsName(os.string)) return false;
    const arch = properties.get("arch") orelse return false;
    if (arch != .string or !validArchName(arch.string)) return false;
    const occurred_at = properties.get("occurred_at") orelse return false;
    if (occurred_at != .string or !validTimestamp(occurred_at.string)) return false;
    const count = properties.get("count") orelse return false;
    if (count != .integer or count.integer < 1 or count.integer > max_summary_count) return false;

    if (std.mem.eql(u8, event, fm_summary_event_name)) {
        const host = properties.get("host") orelse return false;
        const source = properties.get("source") orelse return false;
        const verdict = properties.get("verdict") orelse return false;
        const status = properties.get("status") orelse return false;
        const model = properties.get("model_available") orelse return false;
        const timed_out = properties.get("timed_out") orelse return false;
        const upgraded = properties.get("upgraded") orelse return false;
        const latency = properties.get("latency_bucket") orelse return false;
        return host == .string and validHost(host.string) and source == .string and validSource(source.string) and
            verdict == .string and validFmVerdict(verdict.string) and status == .string and validFmStatus(status.string) and
            model == .bool and timed_out == .bool and upgraded == .bool and latency == .string and validLatencyBucket(latency.string);
    }
    if (std.mem.eql(u8, event, enforcement_summary_event_name)) {
        const host = properties.get("host") orelse return false;
        const source = properties.get("source") orelse return false;
        const decision = properties.get("decision") orelse return false;
        const risk = properties.get("risk") orelse return false;
        const effect = properties.get("effect") orelse return false;
        const mode = properties.get("mode") orelse return false;
        return host == .string and validHost(host.string) and source == .string and validSource(source.string) and
            decision == .string and validDecision(decision.string) and risk == .string and validRisk(risk.string) and
            effect == .string and validEffect(effect.string) and mode == .string and validMode(mode.string);
    }
    if (std.mem.eql(u8, event, integration_summary_event_name)) {
        const host = properties.get("host") orelse return false;
        const operation = properties.get("operation") orelse return false;
        const result = properties.get("result") orelse return false;
        return host == .string and validHost(host.string) and operation == .string and validIntegrationOperation(operation.string) and
            result == .string and validIntegrationResult(result.string);
    }
    if (std.mem.eql(u8, event, session_summary_event_name)) {
        const host = properties.get("host") orelse return false;
        const event_type = properties.get("event_type") orelse return false;
        const result = properties.get("result") orelse return false;
        return host == .string and validHost(host.string) and event_type == .string and validSessionEvent(event_type.string) and
            result == .string and validSessionResult(result.string);
    }
    if (std.mem.eql(u8, event, feature_summary_event_name)) {
        const feature = properties.get("feature") orelse return false;
        const operation = properties.get("operation") orelse return false;
        const result = properties.get("result") orelse return false;
        return feature == .string and validFeature(feature.string) and operation == .string and validOperation(operation.string) and
            result == .string and validResult(result.string);
    }
    const operation = properties.get("operation") orelse return false;
    const failure = properties.get("failure") orelse return false;
    const source = properties.get("source") orelse return false;
    return operation == .string and validOperation(operation.string) and failure == .string and validFailure(failure.string) and
        source == .string and validSource(source.string);
}

pub fn validVersionToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    var component: usize = 0;
    var saw_digit = false;
    var suffix = false;
    var saw_suffix = false;
    for (value) |byte| {
        if (suffix) {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_' or byte == '+')) return false;
            saw_suffix = true;
        } else if (std.ascii.isDigit(byte)) {
            saw_digit = true;
        } else if (byte == '.' and component < 2 and saw_digit) {
            component += 1;
            saw_digit = false;
        } else if ((byte == '-' or byte == '+') and component == 2 and saw_digit) {
            suffix = true;
            saw_digit = false;
        } else {
            return false;
        }
    }
    return component == 2 and (saw_digit or saw_suffix);
}

pub fn validTimestamp(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':' or value[19] != 'Z') return false;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13 or index == 16 or index == 19) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

pub fn renderEvent(allocator: std.mem.Allocator, io: std.Io, installation_id: []const u8, invocation: Invocation) ![]u8 {
    var timestamp_buf: [32]u8 = undefined;
    const occurred_at = try core.time.Timestamp.now(io).formatIso(&timestamp_buf);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"event\":");
    try core.util.writeJsonString(&out.writer, event_name);
    try out.writer.writeAll(",\"properties\":{\"distinct_id\":");
    try core.util.writeJsonString(&out.writer, installation_id);
    try out.writer.print(
        ",\"$process_person_profile\":false,\"$ip\":0,\"telemetry_schema_version\":{d},\"command\":",
        .{schema_version},
    );
    try core.util.writeJsonString(&out.writer, invocation.command);
    try out.writer.writeAll(",\"host\":");
    try core.util.writeJsonString(&out.writer, invocation.host);
    try out.writer.writeAll(",\"outcome\":");
    try core.util.writeJsonString(&out.writer, invocation.outcome);
    try out.writer.writeAll(",\"product_version\":");
    try core.util.writeJsonString(&out.writer, build_options.version);
    try out.writer.writeAll(",\"os\":");
    try core.util.writeJsonString(&out.writer, osName());
    try out.writer.writeAll(",\"arch\":");
    try core.util.writeJsonString(&out.writer, archName());
    try out.writer.writeAll(",\"occurred_at\":");
    try core.util.writeJsonString(&out.writer, occurred_at);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

pub fn renderSummary(allocator: std.mem.Allocator, io: std.Io, installation_id: []const u8, summary: Summary) ![]u8 {
    if (!validInstallationId(installation_id) or !validSummary(summary)) return error.InvalidTelemetryEvent;
    var timestamp_buf: [32]u8 = undefined;
    const occurred_at = try core.time.Timestamp.now(io).formatIso(&timestamp_buf);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("{\"event\":");
    try core.util.writeJsonString(&out.writer, summaryEventName(summary));
    try out.writer.writeAll(",\"properties\":{\"distinct_id\":");
    try core.util.writeJsonString(&out.writer, installation_id);
    try out.writer.print(
        ",\"$process_person_profile\":false,\"$ip\":0,\"telemetry_schema_version\":{d}",
        .{schema_version},
    );
    switch (summary) {
        .fm => |value| {
            try writeJsonField(&out.writer, "host", value.host);
            try writeJsonField(&out.writer, "source", value.source);
            try writeJsonField(&out.writer, "verdict", value.verdict);
            try writeJsonField(&out.writer, "status", value.status);
            try writeBoolField(&out.writer, "model_available", value.model_available);
            try writeBoolField(&out.writer, "timed_out", value.timed_out);
            try writeBoolField(&out.writer, "upgraded", value.upgraded);
            try writeJsonField(&out.writer, "latency_bucket", value.latency_bucket);
            try writeCountField(&out.writer, value.count);
        },
        .enforcement => |value| {
            try writeJsonField(&out.writer, "host", value.host);
            try writeJsonField(&out.writer, "source", value.source);
            try writeJsonField(&out.writer, "decision", value.decision);
            try writeJsonField(&out.writer, "risk", value.risk);
            try writeJsonField(&out.writer, "effect", value.effect);
            try writeJsonField(&out.writer, "mode", value.mode);
            try writeCountField(&out.writer, value.count);
        },
        .integration => |value| {
            try writeJsonField(&out.writer, "host", value.host);
            try writeJsonField(&out.writer, "operation", value.operation);
            try writeJsonField(&out.writer, "result", value.result);
            try writeCountField(&out.writer, value.count);
        },
        .session => |value| {
            try writeJsonField(&out.writer, "host", value.host);
            try writeJsonField(&out.writer, "event_type", value.event_type);
            try writeJsonField(&out.writer, "result", value.result);
            try writeCountField(&out.writer, value.count);
        },
        .feature => |value| {
            try writeJsonField(&out.writer, "feature", value.feature);
            try writeJsonField(&out.writer, "operation", value.operation);
            try writeJsonField(&out.writer, "result", value.result);
            try writeCountField(&out.writer, value.count);
        },
        .reliability => |value| {
            try writeJsonField(&out.writer, "operation", value.operation);
            try writeJsonField(&out.writer, "failure", value.failure);
            try writeJsonField(&out.writer, "source", value.source);
            try writeCountField(&out.writer, value.count);
        },
    }
    try writeJsonField(&out.writer, "product_version", build_options.version);
    try writeJsonField(&out.writer, "os", osName());
    try writeJsonField(&out.writer, "arch", archName());
    try writeJsonField(&out.writer, "occurred_at", occurred_at);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try core.util.writeJsonString(writer, name);
    try writer.writeByte(':');
    try core.util.writeJsonString(writer, value);
}

fn writeBoolField(writer: anytype, name: []const u8, value: bool) !void {
    try writer.writeByte(',');
    try core.util.writeJsonString(writer, name);
    try writer.writeByte(':');
    try writer.writeAll(if (value) "true" else "false");
}

fn writeCountField(writer: anytype, count: u32) !void {
    try writer.print(",\"count\":{d}", .{count});
}

pub fn renderBatch(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"api_key\":");
    try core.util.writeJsonString(&out.writer, build_options.posthog_project_token);
    try out.writer.writeAll(",\"batch\":[");
    for (items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(item);
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

pub fn generateInstallationId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = "0123456789abcdef";
    const id = try allocator.alloc(u8, 36);
    @memcpy(id[0..4], "ryk_");
    for (random, 0..) |byte, index| {
        id[4 + index * 2] = hex[byte >> 4];
        id[5 + index * 2] = hex[byte & 0x0f];
    }
    return id;
}

pub fn validInstallationId(id: []const u8) bool {
    if (id.len != 36 or !std.mem.startsWith(u8, id, "ryk_")) return false;
    for (id[4..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}
