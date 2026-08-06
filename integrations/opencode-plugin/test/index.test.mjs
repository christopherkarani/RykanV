import assert from 'node:assert/strict';
import { realpathSync } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import rykPlugin, { findRyk, parseHookResponse } from '../dist/index.js';

const pluginRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

async function withFakeRyk(run, scriptBody) {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const body =
    scriptBody ??
    `
payload=$(cat)
case "$payload" in
  *'"command":"rm -rf'* ) printf '%s\\n' '{"decision":"block","message":"command blocked"}' ;;
  *'"command":"rm'* ) printf '%s\\n' '{"decision":"ask","message":"approval required"}' ;;
  * ) printf '%s\\n' '{"decision":"allow"}' ;;
esac
`;
  const script = `#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "--json" ]; then
  printf '%s\\n' '{"product":"ryk","version":"0.0.0"}'
  exit 0
fi
  ${body.startsWith('#!/bin/sh\n') ? body.slice('#!/bin/sh\n'.length) : body}`;
  const rykBin = join(directory, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  const originalRykBin = process.env.RYK_BIN;

  await writeFile(rykBin, script);
  await chmod(rykBin, 0o755);
  process.env.PATH = `${directory}:${originalPath ?? ''}`;
  process.env.RYK_BIN = rykBin;
  process.env.RYK_ALLOW_WORKSPACE_BIN = '1';

  try {
    await run(await rykPlugin({ directory, worktree: directory }));
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    if (originalRykBin === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = originalRykBin;
    await rm(directory, { recursive: true, force: true });
  }
}

for (const [command, message] of [
  ['rm file.txt', 'approval required'],
  ['rm -r build', 'approval required'],
  ['rm -rf build', 'command blocked'],
]) {
  test(`tool.execute.before blocks ${command}`, async () => {
    await withFakeRyk(async (plugin) => {
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
  await withFakeRyk(async (plugin) => {
    const permissionAsk = plugin['permission.ask'];
    assert.ok(permissionAsk);
    const output = { status: 'ask' };

    await permissionAsk({ sessionID: 'session-1', command: 'rm file.txt' }, output);

    // Native permission UI: ryk ask must not hard-deny without resume.
    assert.equal(output.status, 'ask');
  });
});

test('permission.ask denies ryk block', async () => {
  await withFakeRyk(async (plugin) => {
    const permissionAsk = plugin['permission.ask'];
    assert.ok(permissionAsk);
    const output = { status: 'ask' };

    await permissionAsk({ sessionID: 'session-1', command: 'rm -rf build' }, output);

    assert.equal(output.status, 'deny');
  });
});

test('permission.ask fail-closes unknown decisions', async () => {
  await withFakeRyk(
    async (plugin) => {
      const permissionAsk = plugin['permission.ask'];
      assert.ok(permissionAsk);
      const output = { status: 'ask' };
      await permissionAsk({ sessionID: 'session-1', command: 'echo hi' }, output);
      assert.equal(output.status, 'deny');
    },
    `#!/bin/sh
printf '%s\n' '{"decision":"unexpected","message":"bad decision"}'
`
  );
});

test('tool.execute.before still hard-blocks ryk ask (no resume on that path)', async () => {
  await withFakeRyk(async (plugin) => {
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

test('ryk.ts is a single-source sync of src/index.ts', async () => {
  const src = await readFile(join(pluginRoot, 'src/index.ts'), 'utf8');
  const dropIn = await readFile(join(pluginRoot, 'ryk.ts'), 'utf8');
  assert.equal(
    dropIn,
    src,
    'ryk.ts must match src/index.ts (npm run build copies src → ryk.ts)'
  );
});

test('package metadata publishes the canonical OpenCode drop-in', async () => {
  const packageJson = JSON.parse(await readFile(join(pluginRoot, 'package.json'), 'utf8'));
  assert.deepEqual(
    packageJson.files.filter((file) => file.endsWith('.ts')),
    ['ryk.ts']
  );
  assert.equal(packageJson.scripts.build, 'tsc -p tsconfig.json && cp src/index.ts ryk.ts');
});

test('missing binary registers fail-closed veto hooks', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  // Empty PATH so `which ryk` fails; no workspace candidates without env gate.
  process.env.PATH = directory;
  delete process.env.RYK_ALLOW_WORKSPACE_BIN;
  try {
    const plugin = await rykPlugin({ directory, worktree: directory });
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
  await withFakeRyk(
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
  await withFakeRyk(
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
  await withFakeRyk(
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

test('findRyk rejects an existing non-ryk absolute RYK_BIN', () => {
  const prevRyk = process.env.RYK_BIN;
  try {
    delete process.env.RYK_BIN;
    process.env.RYK_BIN = process.execPath;
    assert.equal(findRyk(), null);
  } finally {
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
  }
});

test('findRyk rejects relative path-shaped RYK_BIN', () => {
  const prevRyk = process.env.RYK_BIN;
  try {
    delete process.env.RYK_BIN;
    process.env.RYK_BIN = './zig-out/bin/ryk';
    assert.equal(findRyk(), null);
    process.env.RYK_BIN = 'evil/ryk';
    assert.equal(findRyk(), null);
  } finally {
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
  }
});

test('findRyk does not shell-interpolate metacharacters in bare RYK_BIN', () => {
  const prevRyk = process.env.RYK_BIN;
  const marker = join(tmpdir(), `opencode-inject-${Date.now()}`);
  try {
    delete process.env.RYK_BIN;
    // Would create marker if interpolated into a shell; argv which must not.
    process.env.RYK_BIN = `ryk; touch ${marker}`;
    assert.equal(findRyk(), null);
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
  }
});

test('findRyk ignores workspace zig-out without RYK_ALLOW_WORKSPACE_BIN', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const zigOutBin = join(directory, 'zig-out', 'bin');
  const rykBin = join(zigOutBin, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  await mkdir(zigOutBin, { recursive: true });
  await writeFile(rykBin, '#!/bin/sh\nif [ "$1" = version ] && [ "$2" = --json ]; then printf \'%s\\n\' \'{"product":"ryk","version":"0.0.0"}\'; else echo ok; fi\n');
  await chmod(rykBin, 0o755);
  process.env.PATH = directory; // no ryk on PATH
  delete process.env.RYK_ALLOW_WORKSPACE_BIN;
  try {
    assert.equal(findRyk(directory), null);
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    await rm(directory, { recursive: true, force: true });
  }
});

test('findRyk accepts workspace zig-out when RYK_ALLOW_WORKSPACE_BIN=1', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const zigOutBin = join(directory, 'zig-out', 'bin');
  // Prefer ryk primary name under workspace allowlist.
  const rykBin = join(zigOutBin, 'ryk');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  const prevRyk = process.env.RYK_BIN;
  await mkdir(zigOutBin, { recursive: true });
  await writeFile(
    rykBin,
    '#!/bin/sh\nif [ "$1" = version ] && [ "$2" = --json ]; then\n' +
      '  printf \'%s\\n\' \'{"product":"ryk","version":"0.0.0"}\'\n' +
      'else\n  echo ok\nfi\n'
  );
  await chmod(rykBin, 0o755);
  process.env.PATH = directory; // no ryk on PATH
  process.env.RYK_ALLOW_WORKSPACE_BIN = '1';
  delete process.env.RYK_BIN;
  try {
    assert.equal(findRyk(directory), realpathSync(rykBin));
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    if (prevRyk === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = prevRyk;
    await rm(directory, { recursive: true, force: true });
  }
});

test('findRyk resolves ryk.exe on a Windows-style PATH', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ryk-opencode-plugin-'));
  const rykBin = join(directory, 'ryk.exe');
  const originalPath = process.env.PATH;
  const originalAllow = process.env.RYK_ALLOW_WORKSPACE_BIN;
  const originalRykBin = process.env.RYK_BIN;
  await writeFile(
    rykBin,
    '#!/bin/sh\nif [ "$1" = version ] && [ "$2" = --json ]; then\n' +
      '  printf \'%s\\n\' \'{"product":"ryk","version":"0.0.0"}\'\n' +
      'fi\n'
  );
  await chmod(rykBin, 0o755);
  process.env.PATH = directory;
  process.env.RYK_ALLOW_WORKSPACE_BIN = '1';
  delete process.env.RYK_BIN;
  try {
    assert.equal(findRyk(directory, 'win32'), realpathSync(rykBin));
  } finally {
    process.env.PATH = originalPath;
    if (originalAllow === undefined) delete process.env.RYK_ALLOW_WORKSPACE_BIN;
    else process.env.RYK_ALLOW_WORKSPACE_BIN = originalAllow;
    if (originalRykBin === undefined) delete process.env.RYK_BIN;
    else process.env.RYK_BIN = originalRykBin;
    await rm(directory, { recursive: true, force: true });
  }
});

test('parseHookResponse empty stdout blocks on blocking path', () => {
  const r = parseHookResponse('', true);
  assert.equal(r.decision, 'block');
  assert.equal(r.reason, 'ryk_empty_response');
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
  assert.equal(r.reason, 'ryk_unrecognized_decision');
});

test('parseHookResponse keeps ask on blocking path for permission.ask UX', () => {
  const r = parseHookResponse(JSON.stringify({ decision: 'ask', message: 'need approval' }), true);
  assert.equal(r.decision, 'ask');
});

test('shell.env scrubs secret-looking variables', async () => {
  await withFakeRyk(async (plugin) => {
    const shellEnv = plugin['shell.env'];
    assert.ok(shellEnv);
    const output = {
      env: {
        PATH: '/usr/bin',
        HOME: '/home/dev',
        OPENAI_API_KEY: 'sk-secret',
        GITHUB_TOKEN: 'ghp_secret',
        MY_NORMAL: 'ok',
      },
    };
    await shellEnv({ cwd: '/tmp', sessionID: 's1' }, output);
    assert.equal(output.env.PATH, '/usr/bin');
    assert.equal(output.env.MY_NORMAL, 'ok');
    assert.equal(output.env.OPENAI_API_KEY, undefined);
    assert.equal(output.env.GITHUB_TOKEN, undefined);
  });
});

test('tool.execute.before blocks .env reads locally', async () => {
  await withFakeRyk(async (plugin) => {
    const before = plugin['tool.execute.before'];
    assert.ok(before);
    await assert.rejects(
      before(
        { tool: 'read', sessionID: 'session-1', callID: 'call-1' },
        { args: { path: '.env' } }
      ),
      /\.env protection/
    );
  });
});

test('command.execute.before blocks when ryk returns block', async () => {
  await withFakeRyk(
    async (plugin) => {
      const hook = plugin['command.execute.before'];
      assert.ok(hook);
      await assert.rejects(
        hook(
          { command: 'danger', sessionID: 'session-1', arguments: '' },
          { parts: [] }
        ),
        /ryk blocked command/
      );
    },
    `#!/bin/sh
printf '%s\\n' '{"decision":"block","message":"command blocked"}'
`
  );
});

test('parseHookResponse keeps remediation_commands', () => {
  const r = parseHookResponse(
    JSON.stringify({
      decision: 'block',
      message: 'nope',
      remediation_commands: ['ryk allow-once abc', 'ryk explain "rm"'],
    }),
    true
  );
  assert.equal(r.decision, 'block');
  assert.deepEqual(r.remediation_commands, ['ryk allow-once abc', 'ryk explain "rm"']);
});
