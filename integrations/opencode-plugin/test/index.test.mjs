import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import orcaPlugin, { findOrca, parseHookResponse } from '../dist/index.js';

const pluginRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

async function withFakeOrca(run, scriptBody) {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const rykBin = join(directory, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;

  await writeFile(
    rykBin,
    scriptBody ??
      `#!/bin/sh
payload=$(cat)
case "$payload" in
  *'"command":"rm -rf'* ) printf '%s\\n' '{"decision":"block","message":"command blocked"}' ;;
  *'"command":"rm'* ) printf '%s\\n' '{"decision":"ask","message":"approval required"}' ;;
  * ) printf '%s\\n' '{"decision":"allow"}' ;;
esac
`
  );
  await chmod(rykBin, 0o755);
  process.env.PATH = `${directory}:${originalPath ?? ''}`;
  delete process.env.RYK_ALLOW_WORKSPACE_BIN;

  try {
    await run(await orcaPlugin({ directory, worktree: directory }));
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    await rm(directory, { recursive: true, force: true });
  }
}

for (const [command, message] of [
  ['rm file.txt', 'approval required'],
  ['rm -r build', 'approval required'],
  ['rm -rf build', 'command blocked'],
]) {
  test(`tool.execute.before blocks ${command}`, async () => {
    await withFakeOrca(async (plugin) => {
      const before = plugin['tool.execute.before'];
      assert.ok(before);

      await assert.rejects(
        before(
          { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
          { args: { command } }
        ),
        new RegExp(`ryk blocked tool execution: ${message}`)
      );
    });
  });
}

test('permission.ask keeps host ask for ryk ask (approve-and-resume)', async () => {
  await withFakeOrca(async (plugin) => {
    const permissionAsk = plugin['permission.ask'];
    assert.ok(permissionAsk);
    const output = { status: 'ask' };

    await permissionAsk({ sessionID: 'session-1', command: 'rm file.txt' }, output);

    // Native permission UI: ryk ask must not hard-deny without resume.
    assert.equal(output.status, 'ask');
  });
});

test('permission.ask denies ryk block', async () => {
  await withFakeOrca(async (plugin) => {
    const permissionAsk = plugin['permission.ask'];
    assert.ok(permissionAsk);
    const output = { status: 'ask' };

    await permissionAsk({ sessionID: 'session-1', command: 'rm -rf build' }, output);

    assert.equal(output.status, 'deny');
  });
});

test('permission.ask fail-closes unknown decisions', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const rykBin = join(directory, 'ryk');
  const originalPath = process.env.PATH;
  await writeFile(
    rykBin,
    `#!/bin/sh
printf '%s\\n' '{"decision":"unexpected","message":"bad decision"}'
`
  );
  await chmod(rykBin, 0o755);
  process.env.PATH = `${directory}:${originalPath ?? ''}`;
  try {
    const plugin = await orcaPlugin({ directory, worktree: directory });
    const permissionAsk = plugin['permission.ask'];
    assert.ok(permissionAsk);
    const output = { status: 'ask' };
    await permissionAsk({ sessionID: 'session-1', command: 'echo hi' }, output);
    assert.equal(output.status, 'deny');
  } finally {
    process.env.PATH = originalPath;
    await rm(directory, { recursive: true, force: true });
  }
});

test('tool.execute.before still hard-blocks ryk ask (no resume on that path)', async () => {
  await withFakeOrca(async (plugin) => {
    const before = plugin['tool.execute.before'];
    assert.ok(before);
    await assert.rejects(
      before(
        { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
        { args: { command: 'rm file.txt' } }
      ),
      /ryk blocked tool execution: approval required/
    );
  });
});

test('orca.ts is a single-source sync of src/index.ts', async () => {
  const src = await readFile(join(pluginRoot, 'src/index.ts'), 'utf8');
  const dropIn = await readFile(join(pluginRoot, 'orca.ts'), 'utf8');
  assert.equal(
    dropIn,
    src,
    'orca.ts must match src/index.ts (npm run build copies src → orca.ts)'
  );
});

test('missing binary registers fail-closed veto hooks', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  // Empty PATH so `which orca` fails; no workspace candidates without env gate.
  process.env.PATH = directory;
  delete process.env.RYK_ALLOW_WORKSPACE_BIN;
  try {
    const plugin = await orcaPlugin({ directory, worktree: directory });
    const before = plugin['tool.execute.before'];
    const permissionAsk = plugin['permission.ask'];
    assert.ok(before, 'missing binary must register tool.execute.before veto');
    assert.ok(permissionAsk, 'missing binary must register permission.ask veto');

    await assert.rejects(
      before(
        { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
        { args: { command: 'echo hi' } }
      ),
      /ryk binary not found/
    );

    const output = { status: 'ask' };
    await permissionAsk({ sessionID: 'session-1', command: 'echo hi' }, output);
    assert.equal(output.status, 'deny');
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    await rm(directory, { recursive: true, force: true });
  }
});

test('tool.execute.before blocks empty stdout', async () => {
  await withFakeOrca(
    async (plugin) => {
      const before = plugin['tool.execute.before'];
      assert.ok(before);
      await assert.rejects(
        before(
          { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
          { args: { command: 'echo hi' } }
        ),
        /ryk blocked tool execution/
      );
    },
    `#!/bin/sh
# empty stdout
`
  );
});

test('tool.execute.before blocks decision error', async () => {
  await withFakeOrca(
    async (plugin) => {
      const before = plugin['tool.execute.before'];
      assert.ok(before);
      await assert.rejects(
        before(
          { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
          { args: { command: 'echo hi' } }
        ),
        /ryk blocked tool execution/
      );
    },
    `#!/bin/sh
printf '%s\\n' '{"decision":"error","message":"evaluator failed"}'
`
  );
});

test('tool.execute.before blocks unknown decision', async () => {
  await withFakeOrca(
    async (plugin) => {
      const before = plugin['tool.execute.before'];
      assert.ok(before);
      await assert.rejects(
        before(
          { tool: 'bash', sessionID: 'session-1', callID: 'call-1' },
          { args: { command: 'echo hi' } }
        ),
        /ryk blocked tool execution/
      );
    },
    `#!/bin/sh
printf '%s\\n' '{"decision":"unexpected","message":"bad decision"}'
`
  );
});

test('findOrca accepts absolute RYK_BIN when path exists', () => {
  const prevRyk = process.env.RYK_BIN;
  const prevOrca = process.env.RYK_BIN;
  try {
    delete process.env.RYK_BIN;
    process.env.RYK_BIN = process.execPath;
    assert.equal(findOrca(), process.execPath);
  } finally {
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
    if (prevOrca === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevOrca;
  }
});

test('findOrca rejects relative path-shaped RYK_BIN', () => {
  const prevRyk = process.env.RYK_BIN;
  const prevOrca = process.env.RYK_BIN;
  try {
    delete process.env.RYK_BIN;
    process.env.RYK_BIN = './zig-out/bin/ryk';
    assert.equal(findOrca(), null);
    process.env.RYK_BIN = 'evil/ryk';
    assert.equal(findOrca(), null);
  } finally {
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
    if (prevOrca === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevOrca;
  }
});

test('findryk does not shell-interpolate metacharacters in bare RYK_BIN', () => {
  const prevRyk = process.env.RYK_BIN;
  const prevOrca = process.env.RYK_BIN;
  const marker = join(tmpdir(), `opencode-inject-${Date.now()}`);
  try {
    delete process.env.RYK_BIN;
    // Would create marker if interpolated into a shell; argv which must not.
    process.env.RYK_BIN = `ryk; touch ${marker}`;
    assert.equal(findOrca(), null);
    assert.equal(
      (() => {
        try {
          return require('node:fs').existsSync(marker);
        } catch {
          return false;
        }
      })(),
      false
    );
  } finally {
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
    if (prevOrca === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevOrca;
  }
});

test('findOrca ignores workspace zig-out without RYK_ALLOW_WORKSPACE_BIN', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const zigOutBin = join(directory, 'zig-out', 'bin');
  const rykBin = join(zigOutBin, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  await mkdir(zigOutBin, { recursive: true });
  await writeFile(rykBin, '#!/bin/sh\necho ok\n');
  await chmod(rykBin, 0o755);
  process.env.PATH = directory; // no ryk on PATH
  delete process.env.RYK_ALLOW_WORKSPACE_BIN;
  try {
    assert.equal(findOrca(directory), null);
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    await rm(directory, { recursive: true, force: true });
  }
});

test('findOrca accepts workspace zig-out when RYK_ALLOW_WORKSPACE_BIN=1', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const zigOutBin = join(directory, 'zig-out', 'bin');
  // Prefer ryk primary name under workspace allowlist.
  const rykBin = join(zigOutBin, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  const prevRyk = process.env.RYK_BIN;
  const prevOrca = process.env.RYK_BIN;
  await mkdir(zigOutBin, { recursive: true });
  await writeFile(rykBin, '#!/bin/sh\necho ok\n');
  await chmod(rykBin, 0o755);
  process.env.PATH = directory; // no ryk/orca on PATH
  process.env.RYK_ALLOW_WORKSPACE_BIN = '1';
  delete process.env.RYK_BIN;
  delete process.env.RYK_BIN;
  try {
    assert.equal(findOrca(directory), rykBin);
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
    if (prevOrca === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevOrca;
    await rm(directory, { recursive: true, force: true });
  }
});

test('parseHookResponse empty stdout blocks on blocking path', () => {
  const r = parseHookResponse('', true);
  assert.equal(r.decision, 'block');
  assert.equal(r.reason, 'orca_empty_response');
});

test('parseHookResponse empty stdout allows on non-blocking path', () => {
  const r = parseHookResponse('', false);
  assert.equal(r.decision, 'allow');
});

test('parseHookResponse error decision blocks on blocking path', () => {
  const r = parseHookResponse(JSON.stringify({ decision: 'error', message: 'boom' }), true);
  assert.equal(r.decision, 'block');
});

test('parseHookResponse unknown decision blocks on blocking path', () => {
  const r = parseHookResponse(JSON.stringify({ decision: 'maybe' }), true);
  assert.equal(r.decision, 'block');
  assert.equal(r.reason, 'orca_unrecognized_decision');
});

test('parseHookResponse keeps ask on blocking path for permission.ask UX', () => {
  const r = parseHookResponse(JSON.stringify({ decision: 'ask', message: 'need approval' }), true);
  assert.equal(r.decision, 'ask');
});
