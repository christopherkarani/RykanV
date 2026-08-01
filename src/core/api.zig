const std = @import("std");

const audit = @import("../audit/mod.zig");
const core = @import("public.zig");
const policy = @import("../policy/mod.zig");

pub const Action = core.types.Action;
pub const Decision = core.decision.Decision;
pub const DecisionResult = core.decision.DecisionResult;
pub const Evaluation = policy.schema.Evaluation;
pub const EvaluationContext = policy.schema.EvaluationContext;
pub const Policy = policy.schema.Policy;
pub const LoadedPolicy = policy.schema.LoadedPolicy;
pub const Preset = policy.presets.Preset;
pub const ReplayOptions = audit.replay.ReplayOptions;
pub const ReplayEvent = audit.replay.ReplayEvent;
pub const ReplaySession = audit.replay.ReplaySession;
pub const isDeniedFields = audit.replay.isDeniedFields;
pub const VerifyResult = audit.replay.VerifyResult;
pub const ParseIntegrityFailed = audit.replay.ParseIntegrityFailed;
pub const AuditWriter = audit.writer.SessionWriter;
pub const SummaryInput = audit.summary.SummaryInput;

pub const DecisionInput = struct {
    result: DecisionResult,
    reason: []const u8,
    rule_id: ?[]const u8 = null,
    risk_score: ?u8 = null,
    requires_user: bool = false,
    ci_may_proceed: bool = false,
};

pub const AuditEventInput = struct {
    session_id: core.session.SessionId,
    event_id: core.event.EventId,
    timestamp: core.time.Timestamp,
    event_type: core.event.EventType,
    actor: core.types.Actor,
    target: core.types.Target,
    decision: ?Decision = null,
    redactions: core.event.RedactionSummary = .{},
};

pub fn parsePolicyFromSlice(allocator: std.mem.Allocator, text: []const u8, source_path: ?[]const u8) !Policy {
    return policy.load.parseFromSlice(allocator, text, source_path);
}

pub fn loadPolicyFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Policy {
    return policy.load.loadFile(io, allocator, path);
}

pub fn loadPolicyPreset(allocator: std.mem.Allocator, preset: Preset) !Policy {
    return policy.load.loadPreset(allocator, preset);
}

pub fn discoverPolicy(io: std.Io, allocator: std.mem.Allocator, explicit_path: ?[]const u8, workspace_root: []const u8) !LoadedPolicy {
    return policy.load.discover(io, allocator, explicit_path, workspace_root);
}

pub fn validatePolicy(value: *const Policy) !void {
    return policy.validate.policy(value);
}

pub fn explainAction(
    allocator: std.mem.Allocator,
    value: *const Policy,
    kind: policy.explain.ExplainKind,
    target: []const u8,
) !Evaluation {
    return policy.explain.explain(allocator, value, kind, target);
}

pub fn explainActionWithOptions(
    allocator: std.mem.Allocator,
    value: *const Policy,
    kind: policy.explain.ExplainKind,
    target: []const u8,
    options: policy.explain.ExplainOptions,
) !Evaluation {
    return policy.explain.explainWithOptions(allocator, value, kind, target, options);
}

pub fn writePolicyExplanation(writer: anytype, value: *const Policy, evaluation: Evaluation) !void {
    try policy.explain.write(writer, value, evaluation);
}

pub fn evaluateAction(allocator: std.mem.Allocator, value: *const Policy, action: Action, context: EvaluationContext) !Evaluation {
    return policy.evaluate.action(value, action, context, allocator);
}

pub fn makeDecision(input: DecisionInput) Decision {
    return .{
        .result = input.result,
        .rule_id = input.rule_id,
        .reason = input.reason,
        .risk_score = input.risk_score,
        .requires_user = input.requires_user,
        .ci_may_proceed = input.ci_may_proceed,
    };
}

pub fn createAuditEvent(input: AuditEventInput) !core.event.Event {
    return .{
        .session_id = input.session_id,
        .event_id = input.event_id,
        .timestamp = input.timestamp,
        .event_type = input.event_type,
        .actor = input.actor,
        .target = input.target,
        .decision = input.decision,
        .redactions = input.redactions,
    };
}

pub fn createAuditWriter(io: std.Io, allocator: std.mem.Allocator, session: core.session.Session) !AuditWriter {
    return AuditWriter.init(io, allocator, session);
}

pub fn createAuditWriterWithDirName(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: core.session.Session,
    audit_dir_name: []const u8,
) !AuditWriter {
    return AuditWriter.initWithDirName(io, allocator, session, audit_dir_name);
}

pub fn openAuditWriter(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) !AuditWriter {
    return AuditWriter.openExisting(io, allocator, workspace_root, session_id);
}

pub fn appendAuditEvent(writer: *AuditWriter, event: core.event.Event) !void {
    try writer.appendEvent(event);
}

pub fn writeAuditSummary(allocator: std.mem.Allocator, session_dir_path: []const u8, input: SummaryInput) !void {
    try audit.summary.writeFiles(allocator, session_dir_path, input);
}

pub fn updateAuditSummaryFinalHash(allocator: std.mem.Allocator, session_dir_path: []const u8, event_count: usize, final_event_hash: []const u8) !void {
    try audit.summary.updateFinalHash(allocator, session_dir_path, event_count, final_event_hash);
}

pub fn redactString(value: []const u8) []const u8 {
    return audit.redact_bridge.redactString(value);
}

pub fn redactStringBounded(value: []const u8, buffer: []u8) []const u8 {
    return audit.redact_bridge.redactStringBounded(value, buffer);
}

pub fn redactTargetValueBounded(kind_name: []const u8, value: []const u8, buffer: []u8) []const u8 {
    return audit.redact_bridge.redactTargetValueBounded(kind_name, value, buffer);
}

pub fn verifyReplay(io: std.Io, allocator: std.mem.Allocator, session_dir_path: []const u8) !VerifyResult {
    return audit.replay.verifySessionDir(io, allocator, session_dir_path);
}

pub fn loadReplay(io: std.Io, allocator: std.mem.Allocator, workspace_root: []const u8, options: ReplayOptions) !ReplaySession {
    return audit.replay.load(io, allocator, workspace_root, options);
}

pub fn writeReplayJson(writer: anytype, replay: ReplaySession) !void {
    try audit.replay.writeJson(writer, replay);
}

pub fn writeReplayHuman(writer: anytype, replay: ReplaySession, show_verify: bool) !void {
    try audit.replay.writeHuman(writer, replay, show_verify);
}

test "core API exposes policy evaluation and audit redaction for CLI callers" {
    var selected = try parsePolicyFromSlice(std.testing.allocator,
        \\version: 1
        \\mode: strict
        \\commands:
        \\  allow:
        \\    - "echo *"
    , "core-api-test.yaml");
    defer selected.deinit();

    var evaluation = try evaluateAction(std.testing.allocator, &selected, .{ .command_exec = .{ .argv = &.{ "echo", "ok" } } }, .{});
    defer evaluation.deinit(std.testing.allocator);
    try std.testing.expectEqual(DecisionResult.allow, evaluation.decision.result);

    const redacted = redactString("TOKEN=fake_secret_value_phase25");
    try std.testing.expect(std.mem.indexOf(u8, redacted, "fake_secret_value_phase25") == null);
}
