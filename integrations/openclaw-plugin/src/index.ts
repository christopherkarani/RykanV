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

interface PluginLogger {
  debug?: (message: string) => void;
  info: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
}

/**
 * Minimal type for the OpenClaw Plugin API passed at runtime.
 * Matches OpenClawPluginApi from the openclaw/plugin-sdk types.
 */
interface OpenClawPluginApi {
  id: string;
  name: string;
  version?: string;
  description?: string;
  source: string;
  config: unknown;
  pluginConfig?: Record<string, unknown>;
  runtime: unknown;
  logger: PluginLogger;
  on: <K extends string>(
    hookName: K,
    handler: (event: unknown, ctx: unknown) => unknown | Promise<unknown>,
    opts?: { priority?: number }
  ) => void;
}

const SECRET_KEYS = [
  'password', 'token', 'secret', 'api_key', 'apikey', 'api_secret',
  'auth', 'authorization', 'bearer', 'private_key', 'access_token',
  'refresh_token', 'credential', 'passwd', 'pwd',
];

const ALLOW_DECISIONS = new Set(['allow', 'warn', 'context_only']);

/** Matches Zig `openclaw_status.enforcement_note` intent (prefer wrapper; npm unprotected). */
export const ENFORCEMENT_NOTE =
  'unprotected for npm/ClawHub (hooks no-op); prefer wrapper: orca run -- openclaw';

/** Standing warning text for npm/ClawHub unprotected installs. */
export const UNPROTECTED_NOOP_WARNING =
  `[orca] unprotected: npm/ClawHub/CLI-metadata install — OpenClaw wires api.on to a no-op, ` +
  `so before_tool_call / after_tool_call hooks will NOT fire and cannot block tools. ` +
  `Prefer wrapper: \`orca run -- openclaw\` (${ENFORCEMENT_NOTE}).`;

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
    host: 'openclaw',
    event,
    payload: redactSecrets(data),
    session_id: sessionId,
    timestamp: new Date().toISOString(),
  };
}

/**
 * Resolve the ryk/orca binary (Phase 5a dual-name).
 * Prefer absolute RYK_BIN / ORCA_BIN, then PATH (`ryk` then `orca`). Relative
 * env bins and workspace zig-out paths are agent-plantable (fake always-allow
 * binary), so:
 * - path-shaped env must be absolute
 * - workspace zig-out candidates require ORCA_ALLOW_WORKSPACE_BIN=1 (dev only)
 */
export function findOrca(cwd?: string): string | null {
  const envBin = (process.env.RYK_BIN ?? process.env.ORCA_BIN)?.trim();
  if (envBin) {
    if (envBin.includes('/') || envBin.includes('\\')) {
      // Relative paths like ./zig-out/bin/ryk or evil/orca are agent-writable.
      // Require an absolute path (no PATH fallback for path-shaped values).
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
    const names = ['ryk', 'orca'] as const;
    const candidates: string[] = [];
    for (const name of names) {
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

/** Normalize OpenClaw tool events into the envelope Orca hook understands. */
export function normalizeOpenClawToolEvent(event: unknown): Record<string, unknown> {
  const e = (event && typeof event === 'object' ? event : {}) as Record<string, unknown>;
  const params =
    e.params && typeof e.params === 'object'
      ? (e.params as Record<string, unknown>)
      : e.tool_input && typeof e.tool_input === 'object'
        ? (e.tool_input as Record<string, unknown>)
        : {};
  const tool =
    (typeof e.toolName === 'string' && e.toolName) ||
    (typeof e.tool_name === 'string' && e.tool_name) ||
    (typeof e.tool === 'string' && e.tool) ||
    undefined;
  const command =
    (typeof params.command === 'string' && params.command) ||
    (typeof e.command === 'string' && e.command) ||
    undefined;
  const cwd =
    (typeof params.cwd === 'string' && params.cwd) ||
    (typeof params.workdir === 'string' && params.workdir) ||
    (typeof e.cwd === 'string' && e.cwd) ||
    undefined;

  return {
    ...e,
    tool,
    tool_name: tool,
    toolName: tool,
    params,
    command,
    cwd,
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
  if (decision === 'ask') {
    return failClosedBlock(
      'orca_ask_unsupported',
      'Orca requested interactive approval (ask); OpenClaw has no ask UX — blocking.'
    );
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
 * `ask`, and unrecognized decisions (no OpenClaw ask UX).
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

async function callOrca(
  orcaBin: string,
  event: string,
  data: unknown,
  sessionId: string | undefined,
  blocking: boolean,
  logger: PluginLogger | undefined
): Promise<OrcaResponse> {
  const payload = buildPayload(event, data, sessionId);
  const payloadJson = JSON.stringify(payload);

  try {
    // argv array — no shell interpolation of orcaBin
    const stdout = execFileSync(
      orcaBin,
      ['hook', 'openclaw', event],
      {
        input: payloadJson,
        encoding: 'utf-8',
        timeout: blocking ? 15000 : 10000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }
    );

    return parseHookResponse(stdout, blocking);
  } catch (err: unknown) {
    const safeErr = redactSecrets({ message: (err as Error).message });
    logger?.error?.(`[orca] Hook ${event} failed: ${(safeErr as { message: string }).message}`);

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

/**
 * Detect whether api.on is likely a no-op.
 * OpenClaw loads npm plugins with registrationMode "cli-metadata", where
 * api.on is wired to a no-op function. This is a known limitation.
 *
 * We use a path heuristic: if the plugin source contains "node_modules" or
 * ".openclaw/npm", it was installed via npm/ClawHub and hooks will not fire.
 */
export function isOnNoop(api: OpenClawPluginApi): boolean {
  if (typeof api.on !== 'function') return true;

  const source = api.source || '';
  if (source.includes('node_modules') || source.includes('.openclaw/npm')) {
    return true;
  }

  return false;
}

export default function orcaPlugin(api: OpenClawPluginApi): void {
  const cwd = process.cwd();
  const sessionId = undefined;
  const orcaBin = findOrca(cwd);
  const { logger } = api;

  if (typeof api.on !== 'function') {
    logger?.warn?.(
      '[orca] OpenClaw plugin API does not expose hook registration (api.on). ' +
        'Plugin will not register lifecycle hooks. State: unprotected for hook grade; prefer wrapper: `orca run -- openclaw`.'
    );
    return;
  }

  const onIsNoop = isOnNoop(api);

  if (onIsNoop) {
    logger?.warn?.(UNPROTECTED_NOOP_WARNING);
    // npm/ClawHub installs wire api.on to a no-op. Registering a veto handler
    // would claim fail-closed protection while hooks never fire. Prefer the
    // wrapper path instead of a false sense of enforcement.
    if (!orcaBin) {
      logger?.warn?.(
        '[orca] Binary not found in PATH (or ORCA_BIN). ' +
          'npm/ClawHub install remains unprotected (hooks no-op); ' +
          'prefer wrapper: `orca run -- openclaw`.'
      );
    }
    return;
  }

  if (!orcaBin) {
    logger?.warn?.(
      '[orca] Binary not found in PATH (or ORCA_BIN). ' +
        'Registering fail-closed before_tool_call vetoes. ' +
        'Install Orca or set ORCA_BIN to an absolute path. Prefer wrapper: `orca run -- openclaw`.'
    );
    // Fail closed only when hooks can actually fire (bundled / real api.on).
    api.on(
      'before_tool_call',
      async () => ({
        block: true,
        blockReason: 'Orca binary not found; blocking as a precaution.',
      }),
      { timeoutMs: 5_000 }
    );
    return;
  }

  logger?.info?.(`[orca] Plugin loaded. Binary: ${orcaBin}`);

  api.on('session_start', async (event) => {
    logger?.info?.('[orca] Plugin ready for session.');
    await callOrca(
      orcaBin,
      'session.start',
      { session_id: (event as { sessionId?: string })?.sessionId },
      sessionId,
      false,
      logger
    );
  });

  // Host timeout is fail-open; keep CLI budget under the hook budget.
  api.on(
    'before_tool_call',
    async (event) => {
      const normalized = normalizeOpenClawToolEvent(event);
      const response = await callOrca(orcaBin, 'tool.before', normalized, sessionId, true, logger);

      if (response.decision === 'block') {
        const msg = response.message || response.reason || 'Orca blocked this command.';
        logger?.error?.(`[orca] Blocked tool execution: ${msg}`);
        return { block: true, blockReason: msg };
      }

      if (response.decision === 'warn') {
        logger?.warn?.(`[orca] Warning: ${response.message || response.reason}`);
      }

      // Do not return { params: undefined } — some hosts treat that as a rewrite.
      return;
    },
    { timeoutMs: 20_000 }
  );

  api.on('after_tool_call', async (event) => {
    await callOrca(orcaBin, 'tool.after', normalizeOpenClawToolEvent(event), sessionId, false, logger);
  });

  api.on('session_end', async (event) => {
    await callOrca(orcaBin, 'session.end', event, sessionId, false, logger);
  });
}
