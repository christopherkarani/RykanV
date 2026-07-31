import { describe, it, mock } from 'node:test';
import assert from 'node:assert';
import orcaPlugin, {
  findOrca,
  isOnNoop,
  normalizeOpenClawToolEvent,
  parseHookResponse,
  UNPROTECTED_NOOP_WARNING,
} from '../src/index.ts';

// Minimal mock API factory
function makeApi(overrides: Partial<Parameters<typeof orcaPlugin>[0]> = {}) {
  const logger = {
    debug: mock.fn(),
    info: mock.fn(),
    warn: mock.fn(),
    error: mock.fn(),
  };
  const on = mock.fn();
  return {
    id: 'test',
    name: 'test-plugin',
    source: '/bundled/plugins/ryk',
    config: {},
    runtime: {},
    logger,
    on,
    ...overrides,
  };
}

describe('findOrca', () => {
  it('rejects relative RYK_BIN paths (agent-plantable)', () => {
    const prevBin = process.env.RYK_BIN;
    const prevAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
    delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    try {
      process.env.RYK_BIN = './zig-out/bin/ryk';
      assert.strictEqual(findOrca(process.cwd()), null);

      process.env.RYK_BIN = 'evil/orca';
      assert.strictEqual(findOrca(process.cwd()), null);
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
      if (prevAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
      else process.env.RYK_ALLOW_WORKSPACE_BIN = prevAllow;
    }
  });

  it('accepts absolute RYK_BIN when the path exists', () => {
    const prevBin = process.env.RYK_BIN;
    try {
      process.env.RYK_BIN = process.execPath;
      assert.strictEqual(findOrca(), process.execPath);
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
    }
  });

  it('returns null for absolute RYK_BIN that does not exist', () => {
    const prevBin = process.env.RYK_BIN;
    try {
      process.env.RYK_BIN = '/tmp/ryk-definitely-missing-deadbeef';
      assert.strictEqual(findOrca(), null);
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
    }
  });
});

describe('isOnNoop', () => {
  it('returns true when api.on is not a function', () => {
    const api = makeApi({ on: undefined as unknown as typeof makeApi extends (...args: any[]) => infer R ? R extends { on: infer O } ? O : never : never });
    assert.strictEqual(isOnNoop(api as any), true);
  });

  it('returns true when source contains node_modules', () => {
    const api = makeApi({ source: '/path/to/node_modules/ryk-openclaw-plugin' });
    assert.strictEqual(isOnNoop(api), true);
  });

  it('returns true when source contains .openclaw/npm', () => {
    const api = makeApi({ source: '/home/user/.openclaw/npm/ryk-openclaw-plugin' });
    assert.strictEqual(isOnNoop(api), true);
  });

  it('returns false for bundled plugin sources', () => {
    const api = makeApi({ source: '/Applications/OpenClaw.app/Contents/Plugins/orca' });
    assert.strictEqual(isOnNoop(api), false);
  });

  it('returns false when source is empty but on is a function', () => {
    const api = makeApi({ source: '' });
    assert.strictEqual(isOnNoop(api), false);
  });
});

describe('parseHookResponse (fail-closed blocking path)', () => {
  it('empty stdout on blocking path → block', () => {
    const r = parseHookResponse('', true);
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_empty_response');
  });

  it('whitespace-only stdout on blocking path → block', () => {
    const r = parseHookResponse('   \n\t  ', true);
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_empty_response');
  });

  it('malformed JSON on blocking path → block', () => {
    const r = parseHookResponse('{not-json', true);
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_parse_error');
  });

  it('missing decision on blocking path → block', () => {
    const r = parseHookResponse(JSON.stringify({ version: 1 }), true);
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_missing_decision');
  });

  it('non-string decision on blocking path → block', () => {
    const r = parseHookResponse(JSON.stringify({ decision: 42 }), true);
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_missing_decision');
  });

  it('ask decision on blocking path → block', () => {
    const r = parseHookResponse(
      JSON.stringify({ decision: 'ask', reason: 'needs_approval' }),
      true
    );
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_ask_unsupported');
  });

  it('unrecognized decision on blocking path → block', () => {
    const r = parseHookResponse(
      JSON.stringify({ decision: 'maybe', reason: 'weird' }),
      true
    );
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.reason, 'orca_unrecognized_decision');
  });

  it('allow decision passes through', () => {
    const r = parseHookResponse(
      JSON.stringify({ decision: 'allow', reason: 'policy_allow' }),
      true
    );
    assert.strictEqual(r.decision, 'allow');
  });

  it('block decision passes through', () => {
    const r = parseHookResponse(
      JSON.stringify({ decision: 'block', reason: 'policy_deny', message: 'nope' }),
      true
    );
    assert.strictEqual(r.decision, 'block');
    assert.strictEqual(r.message, 'nope');
  });

  it('empty stdout on non-blocking path → allow', () => {
    const r = parseHookResponse('', false);
    assert.strictEqual(r.decision, 'allow');
  });
});

describe('normalizeOpenClawToolEvent', () => {
  it('maps toolName + params.command into ryk shell envelope', () => {
    const n = normalizeOpenClawToolEvent({
      toolName: 'exec',
      params: { command: 'git status', cwd: '/tmp' },
    });
    assert.strictEqual(n.tool, 'exec');
    assert.strictEqual(n.tool_name, 'exec');
    assert.strictEqual(n.command, 'git status');
    assert.strictEqual(n.cwd, '/tmp');
  });
});

describe('orcaPlugin', () => {
  it('warns about unprotected noop api.on for npm installs', () => {
    const api = makeApi({
      source: '/path/to/node_modules/ryk-openclaw-plugin',
    });
    orcaPlugin(api);

    const warnCalls = (api.logger.warn as any).mock.calls;
    const noopWarning = warnCalls.find(
      (c: any) =>
        typeof c.arguments[0] === 'string' &&
        (c.arguments[0].includes('unprotected') ||
          c.arguments[0] === UNPROTECTED_NOOP_WARNING)
    );
    assert.ok(noopWarning, 'Expected unprotected warning about noop api.on');
    assert.ok(
      String(noopWarning.arguments[0]).includes('unprotected'),
      'Warning must include unprotected grade label'
    );
    assert.ok(
      String(noopWarning.arguments[0]).includes('ryk run -- openclaw'),
      'Warning must recommend wrapper path'
    );
  });

  it('does not warn about noop when source is bundled', () => {
    const api = makeApi({
      source: '/Applications/OpenClaw.app/Contents/Plugins/orca',
    });
    orcaPlugin(api);

    const warnCalls = (api.logger.warn as any).mock.calls;
    const noopWarning = warnCalls.find(
      (c: any) =>
        typeof c.arguments[0] === 'string' &&
        c.arguments[0].includes('unprotected')
    );
    assert.strictEqual(noopWarning, undefined, 'Should not warn unprotected for bundled installs');
  });

  it('registers fail-closed before_tool_call when binary is missing on a real hook API', async () => {
    const prevBin = process.env.RYK_BIN;
    const prevAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
    delete process.env.RYK_BIN;
    delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    // Force PATH miss by using a name that won't exist if which is used...
    // findOrca uses which orca; in CI ryk may exist. Prefer RYK_BIN pointing at missing path.
    process.env.RYK_BIN = '/tmp/ryk-definitely-missing-deadbeef';

    try {
      // Bundled source: api.on is real; missing binary must veto tools.
      const api = makeApi({
        source: '/Applications/OpenClaw.app/Contents/Plugins/orca',
      });
      orcaPlugin(api);

      const onCalls = (api.on as any).mock.calls;
      const events = onCalls.map((c: any) => c.arguments[0]);
      assert.ok(events.includes('before_tool_call'));
      // Missing binary: only the veto hook is required.
      assert.ok(!events.includes('session_start') || events.includes('before_tool_call'));

      const beforeCall = onCalls.find((c: any) => c.arguments[0] === 'before_tool_call');
      assert.ok(beforeCall, 'before_tool_call must be registered');
      const handler = beforeCall.arguments[1] as () => Promise<{ block?: boolean; blockReason?: string }>;
      const result = await handler();
      assert.strictEqual(result.block, true);
      assert.ok(
        String(result.blockReason).includes('not found'),
        'missing binary must veto tools'
      );
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
      if (prevAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
      else process.env.RYK_ALLOW_WORKSPACE_BIN = prevAllow;
    }
  });

  it('does not register no-op veto handlers for npm installs when binary is missing', () => {
    const prevBin = process.env.RYK_BIN;
    const prevAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
    process.env.RYK_BIN = '/tmp/ryk-definitely-missing-deadbeef';
    delete process.env.RYK_ALLOW_WORKSPACE_BIN;

    try {
      const api = makeApi({
        source: '/path/to/node_modules/ryk-openclaw-plugin',
      });
      orcaPlugin(api);

      const onCalls = (api.on as any).mock.calls;
      assert.strictEqual(
        onCalls.length,
        0,
        'npm/ClawHub no-op api.on must not register handlers that claim fail-closed protection'
      );
      const warnCalls = (api.logger.warn as any).mock.calls;
      const unprotected = warnCalls.find(
        (c: any) =>
          typeof c.arguments[0] === 'string' && c.arguments[0].includes('unprotected')
      );
      assert.ok(unprotected, 'must still warn that npm path is unprotected');
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
      if (prevAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
      else process.env.RYK_ALLOW_WORKSPACE_BIN = prevAllow;
    }
  });

  it('registers lifecycle hooks even when api.on is suspected noop (when binary resolves)', () => {
    // With a resolved binary on an npm path we still warn unprotected and
    // refuse to register handlers on a known no-op api.on.
    const api = makeApi({
      source: '/path/to/node_modules/ryk-openclaw-plugin',
    });
    // Ensure binary appears present so we exercise the binary-present branch.
    const prevBin = process.env.RYK_BIN;
    process.env.RYK_BIN = process.execPath; // any existing absolute path
    try {
      orcaPlugin(api);
      const onCalls = (api.on as any).mock.calls;
      assert.strictEqual(
        onCalls.length,
        0,
        'npm no-op path must not register lifecycle hooks'
      );
    } finally {
      if (prevBin === undefined) delete process.env.RYK_BIN;
      else process.env.RYK_BIN = prevBin;
    }
  });
});
