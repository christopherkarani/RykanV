import { execFileSync } from 'child_process';
import { existsSync } from 'fs';
import { isAbsolute, join, resolve } from 'path';

interface OrcaResponse {
  version?: number;
  decision: 'allow' | 'block' | 'warn' | 'ask' | 'context_only' | 'error';
  risk?: 'low' | 'medium' | 'high' | 'critical' | 'unknown';
  category?: string;
  reason?: string;
  rule?: string | null;
  message?: string;
  redactions?: Array<{ field: string; reason: string }>;
  host_limitations?: string[];
}

type PluginContext = {
  directory: string;
  worktree: string;
};

type ToolExecuteBeforeInput = {
  tool: string;
  sessionID: string;
  callID: string;
};

type ToolExecuteBeforeOutput = {
  args: Record<string, unknown>;
};

type ToolExecuteAfterInput = ToolExecuteBeforeInput & {
  args: Record<string, unknown>;
};

type ToolExecuteAfterOutput = {
  title: string;
  output: string;
  metadata: unknown;
};

type PermissionAskOutput = {
  status: 'ask' | 'deny' | 'allow';
};

type ShellEnvInput = {
  cwd: string;
  sessionID?: string;
  callID?: string;
};

type ShellEnvOutput = {
  env: Record<string, string>;
};

type PluginHooks = {
  event?: (input: { event: Record<string, unknown> }) => Promise<void>;
  'tool.execute.before'?: (
    input: ToolExecuteBeforeInput,
    output: ToolExecuteBeforeOutput
  ) => Promise<void>;
  'tool.execute.after'?: (
    input: ToolExecuteAfterInput,
    output: ToolExecuteAfterOutput
  ) => Promise<void>;
  'permission.ask'?: (input: Record<string, unknown>, output: PermissionAskOutput) => Promise<void>;
  'shell.env'?: (input: ShellEnvInput, output: ShellEnvOutput) => Promise<void>;
};

/** Decisions that may pass through on a blocking path (ask kept for permission.ask UX). */
const ALLOW_DECISIONS = new Set(['allow', 'warn', 'context_only', 'ask']);

/** Decisions that do not veto tool.execute.before after parsing. */
const BLOCKING_PASS_THROUGH = new Set(['allow', 'warn', 'context_only']);

const SECRET_KEYS = [
  'password', 'token', 'secret', 'api_key', 'apikey', 'api_secret',
  'auth', 'authorization', 'bearer', 'private_key', 'access_token',
  'refresh_token', 'credential', 'passwd', 'pwd',
];

const AUDIT_EVENT_TYPES = new Set([
  'session.created',
  'permission.replied',
  'file.edited',
  'command.executed',
  'session.updated',
  'session.idle',
  'session.error',
]);

function redactSecrets(data: unknown): unknown {
  if (data === null || data === undefined) return data;
  if (typeof data === 'string') return data;
  if (Array.isArray(data)) return data.map(redactSecrets);
  if (typeof data !== 'object') return data;

  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
    const lowerKey = key.toLowerCase();
    if (SECRET_KEYS.some((s) => lowerKey.includes(s))) {
      result[key] = '[REDACTED]';
    } else {
      result[key] = redactSecrets(value);
    }
  }
  return result;
}

function buildPayload(event: string, data: unknown, sessionId?: string): object {
  return {
    version: 1,
    host: 'opencode',
    event,
    payload: redactSecrets(data),
    session_id: sessionId,
    timestamp: new Date().toISOString(),
  };
}

function failClosedBlock(reason: string, message: string): OrcaResponse {
  return {
    decision: 'block',
    risk: 'high',
    category: 'unknown',
    reason,
    message,
  };
}

function softAllow(reason: string, message?: string): OrcaResponse {
  return {
    decision: 'allow',
    risk: 'unknown',
    category: 'unknown',
    reason,
    message,
  };
}

function normalizeBlockingDecision(
  decision: string,
  base: Partial<OrcaResponse>
): OrcaResponse {
  if (decision === 'block' || decision === 'error') {
    return {
      ...base,
      decision: 'block',
      risk: base.risk ?? 'high',
      category: base.category ?? 'unknown',
      reason: base.reason,
      message:
        base.message ||
        base.reason ||
        (decision === 'error'
          ? 'Orca returned error; blocking as a precaution.'
          : 'Orca blocked this command.'),
    };
  }
  if (!ALLOW_DECISIONS.has(decision)) {
    return failClosedBlock(
      'orca_unrecognized_decision',
      `Orca returned unrecognized decision "${decision}"; blocking as a precaution.`
    );
  }
  return {
    decision: decision as OrcaResponse['decision'],
    risk: base.risk,
    category: base.category,
    reason: base.reason,
    message: base.message,
    version: base.version,
    rule: base.rule,
    redactions: base.redactions,
    host_limitations: base.host_limitations,
  };
}

/**
 * Parse Orca hook stdout into a decision.
 * Non-blocking: soft-allow on empty/malformed.
 * Blocking: fail closed on empty/whitespace, parse errors, missing/non-string decision,
 * `error`, and unrecognized decisions. `ask` is preserved for OpenCode permission.ask UX;
 * tool.execute.before still hard-blocks ask via applyBlockingDecision.
 */
export function parseHookResponse(stdout: string, blocking: boolean): OrcaResponse {
  const fail = (reason: string, blockMsg: string, softMsg: string): OrcaResponse =>
    blocking ? failClosedBlock(reason, blockMsg) : softAllow(reason, softMsg);

  if (!stdout.trim()) {
    return fail(
      'orca_empty_response',
      'Orca returned empty output; blocking as a precaution.',
      'Orca returned empty output; allowing non-blocking event.'
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return fail(
      'orca_parse_error',
      'Orca returned unreadable JSON; blocking as a precaution.',
      'Orca returned unreadable JSON; allowing non-blocking event.'
    );
  }

  if (!parsed || typeof parsed !== 'object') {
    return fail(
      'orca_missing_decision',
      'Orca response missing decision; blocking as a precaution.',
      'Orca response missing decision; allowing non-blocking event.'
    );
  }

  const record = parsed as Record<string, unknown>;
  const decisionRaw = record.decision;
  if (typeof decisionRaw !== 'string') {
    return fail(
      'orca_missing_decision',
      'Orca response missing decision; blocking as a precaution.',
      'Orca response missing decision; allowing non-blocking event.'
    );
  }

  if (!blocking) {
    return {
      decision: decisionRaw as OrcaResponse['decision'],
      version: typeof record.version === 'number' ? record.version : undefined,
      risk: record.risk as OrcaResponse['risk'],
      category: typeof record.category === 'string' ? record.category : undefined,
      reason: typeof record.reason === 'string' ? record.reason : undefined,
      message: typeof record.message === 'string' ? record.message : undefined,
    };
  }

  return normalizeBlockingDecision(decisionRaw, {
    version: typeof record.version === 'number' ? record.version : undefined,
    risk: record.risk as OrcaResponse['risk'],
    category: typeof record.category === 'string' ? record.category : undefined,
    reason: typeof record.reason === 'string' ? record.reason : undefined,
    message: typeof record.message === 'string' ? record.message : undefined,
    rule: (record.rule as string | null | undefined) ?? undefined,
  });
}

/**
 * Resolve the ryk/orca binary (Phase 5a dual-name).
 * Prefer absolute RYK_BIN / ORCA_BIN, then PATH (`ryk` then `orca`).
 * Relative path-shaped env bins are agent-plantable — rejected.
 * Bare names and hook spawns use argv (no shell interpolation).
 */
export function findOrca(cwd?: string): string | null {
  // Phase 5a: prefer RYK_BIN, then ORCA_BIN, then PATH ryk then orca.
  const envBin = (process.env.RYK_BIN ?? process.env.ORCA_BIN)?.trim();
  if (envBin) {
    if (envBin.includes('/') || envBin.includes('\\')) {
      if (!isAbsolute(envBin)) return null;
      return existsSync(envBin) ? envBin : null;
    }
    // Bare name — resolve via PATH only (no shell interpolation).
    try {
      const which = execFileSync('which', [envBin], {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'ignore'],
      });
      const bin = which.trim();
      if (bin) return bin;
    } catch {
      // not on PATH
    }
    return null;
  }

  for (const name of ['ryk', 'orca'] as const) {
    try {
      const which = execFileSync('which', [name], {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'ignore'],
      });
      const bin = which.trim();
      if (bin) return bin;
    } catch {
      // not on PATH
    }
  }

  // Dev-only: never trust agent-writable workspace bins in production loads.
  if (process.env.ORCA_ALLOW_WORKSPACE_BIN === '1' || process.env.RYK_ALLOW_WORKSPACE_BIN === '1') {
    const candidates: string[] = [];
    for (const name of ['ryk', 'orca'] as const) {
      if (cwd) {
        candidates.push(join(cwd, 'zig-out', 'bin', name));
        candidates.push(join(cwd, '..', 'zig-out', 'bin', name));
        candidates.push(join(cwd, '..', '..', 'zig-out', 'bin', name));
      }
      candidates.push(resolve('zig-out', 'bin', name));
      candidates.push(resolve('..', 'zig-out', 'bin', name));
      candidates.push(resolve('..', '..', 'zig-out', 'bin', name));
    }

    for (const p of candidates) {
      if (existsSync(p)) return p;
    }
  }

  return null;
}

function callOrca(
  orcaBin: string,
  event: string,
  data: unknown,
  sessionId: string | undefined,
  blocking: boolean
): OrcaResponse {
  const payloadJson = JSON.stringify(buildPayload(event, data, sessionId));

  try {
    // argv array — no shell interpolation of orcaBin or event
    const stdout = execFileSync(orcaBin, ['hook', 'opencode', event], {
      input: payloadJson,
      encoding: 'utf-8',
      timeout: blocking ? 15000 : 10000,
      stdio: ['pipe', 'pipe', 'pipe'],
      maxBuffer: 1024 * 1024,
    });

    return parseHookResponse(stdout, blocking);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[orca] Hook ${event} failed: ${message}`);

    return blocking
      ? failClosedBlock(
          'orca_hook_error',
          'Orca hook failed; blocking as a precaution.'
        )
      : softAllow(
          'orca_hook_error',
          'Orca hook failed; allowing because this event is non-blocking.'
        );
  }
}

function buildToolBeforePayload(
  input: ToolExecuteBeforeInput,
  output: ToolExecuteBeforeOutput
): Record<string, unknown> {
  return {
    tool: input.tool,
    sessionID: input.sessionID,
    callID: input.callID,
    ...output.args,
    args: output.args,
  };
}

function applyBlockingDecision(response: OrcaResponse, context: string): void {
  if (response.decision === 'warn') {
    console.warn(`[orca] Warning: ${response.message || response.reason}`);
    return;
  }

  if (BLOCKING_PASS_THROUGH.has(response.decision)) {
    return;
  }

  // block, ask, error, unrecognized → veto tool execution
  const msg = response.message || response.reason || 'Orca blocked this command.';
  console.error(`[orca] Blocked ${context}: ${msg}`);
  throw new Error(`Orca blocked ${context}: ${msg}`);
}

/** Orca decision → OpenCode permission.ask status. Unknown decisions fail closed to deny. */
const PERMISSION_STATUS: Record<string, PermissionAskOutput['status']> = {
  block: 'deny',
  error: 'deny',
  ask: 'ask',
  allow: 'allow',
  context_only: 'allow',
  // Keep host permission UI for advisory outcomes (do not auto-allow).
  warn: 'ask',
};

function applyPermissionDecision(response: OrcaResponse, output: PermissionAskOutput): void {
  const status = PERMISSION_STATUS[response.decision];
  if (!status) {
    const msg = response.message || response.reason || 'Orca returned an invalid permission decision';
    console.error(`[orca] Blocked permission (fail-closed): ${msg}`);
    output.status = 'deny';
    return;
  }
  if (status === 'deny') {
    const msg = response.message || response.reason || 'Orca blocked this command.';
    console.error(`[orca] Blocked permission: ${msg}`);
  }
  if (response.decision === 'warn') {
    console.warn(`[orca] Permission warning: ${response.message || response.reason}`);
  }
  output.status = status;
}

function auditEventPayload(event: Record<string, unknown>): unknown {
  if (event.type === 'session.error') {
    return redactSecrets({
      message: event.message,
      stack: event.stack,
      type: event.type,
    });
  }
  return redactSecrets(event);
}

function sessionIdFromEvent(event: Record<string, unknown>): string | undefined {
  if (typeof event.sessionID === 'string') return event.sessionID;
  if (typeof event.session_id === 'string') return event.session_id;
  return undefined;
}

function sessionIdFromRecord(value: Record<string, unknown>): string | undefined {
  if (typeof value.sessionID === 'string') return value.sessionID;
  if (typeof value.session_id === 'string') return value.session_id;
  return undefined;
}

const MISSING_BINARY_MSG = 'Orca binary not found; blocking as a precaution.';

export default async function orcaPlugin(ctx: PluginContext): Promise<PluginHooks> {
  const cwd = ctx.worktree || ctx.directory || process.cwd();
  // Fail closed on unexpected resolve errors so hooks still register.
  let orcaBin: string | null = null;
  try {
    orcaBin = findOrca(cwd);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[orca] Binary resolve failed (fail-closed): ${message}`);
    orcaBin = null;
  }

  if (!orcaBin) {
    console.warn(
      '[orca] Binary not found in PATH or typical build paths. ' +
        'Registering fail-closed veto hooks. ' +
        'Run: ./scripts/install-orca-plugin.sh opencode project (or .\\scripts\\install-orca-plugin.ps1 opencode project on Windows).'
    );
    return {
      'tool.execute.before': async () => {
        console.error(`[orca] Blocked tool execution: ${MISSING_BINARY_MSG}`);
        throw new Error(MISSING_BINARY_MSG);
      },
      'permission.ask': async (_input, output) => {
        console.error(`[orca] Blocked permission: ${MISSING_BINARY_MSG}`);
        output.status = 'deny';
      },
    };
  }

  console.log(`[orca] Plugin loaded. Binary: ${orcaBin}`);

  return {
    event: async ({ event }) => {
      const eventType = typeof event.type === 'string' ? event.type : '';
      if (!AUDIT_EVENT_TYPES.has(eventType)) return;

      if (eventType === 'session.created') {
        console.log('[orca] Plugin ready for session.');
      }

      await callOrca(
        orcaBin,
        eventType,
        auditEventPayload(event),
        sessionIdFromEvent(event),
        false
      );
    },

    'tool.execute.before': async (input, output) => {
      const response = callOrca(
        orcaBin,
        'tool.execute.before',
        buildToolBeforePayload(input, output),
        input.sessionID,
        true
      );
      applyBlockingDecision(response, 'tool execution');
    },

    'tool.execute.after': async (input, output) => {
      await callOrca(
        orcaBin,
        'tool.execute.after',
        {
          tool: input.tool,
          sessionID: input.sessionID,
          callID: input.callID,
          args: input.args,
          title: output.title,
          output: output.output,
          metadata: output.metadata,
        },
        input.sessionID,
        false
      );
    },

    'permission.ask': async (input, output) => {
      const sessionId = sessionIdFromRecord(input);
      const response = callOrca(orcaBin, 'permission.asked', input, sessionId, true);
      // Host already presents permission UI: map via table (ask stays ask for resume).
      applyPermissionDecision(response, output);
    },

    'shell.env': async (input, output) => {
      await callOrca(
        orcaBin,
        'shell.env',
        {
          cwd: input.cwd,
          sessionID: input.sessionID,
          callID: input.callID,
          env: redactSecrets(output.env),
        },
        input.sessionID,
        false
      );
    },
  };
}
