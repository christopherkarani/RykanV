# P09 — OpenClaw Plugin Deliverable

## Summary

This phase built a native OpenClaw plugin wrapper for ryk. The plugin follows the same thin-wrapper architecture as the existing Codex, Claude Code, and OpenCode plugins: it calls the ryk CLI for policy decisions and does not duplicate policy logic.

## Plugin files added

```text
integrations/openclaw-plugin/
  openclaw.plugin.json
  package.json
  tsconfig.json
  src/
    index.ts
  dist/
    index.js
    index.d.ts
    index.d.ts.map
  README.md
```

## Manifest status

- `openclaw.plugin.json` exists and validates as JSON.
- Contains `id: "ryk"`, `name: "ryk"`, `version: "1.0.0"`.
- Contains `configSchema` (empty object, `additionalProperties: false`).

## Package metadata status

- `package.json` exists and validates as JSON.
- `openclaw.extensions` points to `./src/index.ts`.
- `openclaw.runtimeExtensions` points to `./dist/index.js`.
- No install scripts that compile Zig or download binaries.

## Build output status

- `dist/index.js` exists after `npm run build`.
- `dist/index.d.ts` exists after `npm run build`.
- TypeScript compilation succeeded with zero errors.

## CLI commands added

The ryk Zig CLI now supports:

```bash
ryk plugin doctor openclaw
ryk plugin doctor openclaw --json
ryk plugin manifest openclaw
ryk plugin manifest openclaw --json
ryk plugin install openclaw --dry-run
ryk hook openclaw session.start
ryk hook openclaw tool.before
ryk hook openclaw tool.after
ryk hook openclaw session.end
```

## Hook adapter status

- `ryk hook openclaw <event>` reads JSON from stdin.
- Enforces 256 KiB max payload size.
- Validates JSON, host, and event fields.
- Maps OpenClaw dot-separated events to internal ryk events.
- Handles informational events (`session.end`) with `allow` responses.
- Evaluates `tool.before` through ryk policy.
- OpenClaw does not expose dedicated permission hooks; blocking is handled via `before_tool_call`.
- Emits valid JSON output.
- Debug logs go to stderr only.
- CI mode (`--ci`) never prompts.

## Tests run

- `zig build` — compiles successfully.
- `zig build test` — all tests pass (562+ tests).
- New tests added for OpenClaw in `src/cli/plugin.zig` and `src/cli/hook.zig`.

## Optional local OpenClaw validation

Not performed — OpenClaw was not installed in the test environment. The plugin was validated through:
- Zig unit tests
- Fixture-based hook smoke tests
- Plugin doctor and manifest commands

## Known limitations

- OpenClaw host binary detection reports "not found" if OpenClaw is not installed.
- npm package `ryk-openclaw-plugin@1.1.3` is published.
- ClawHub package `ryk-openclaw-plugin@1.1.3` is published.
- The OpenClaw plugin does not add MCP server behavior or drone-specific plugin features.

## Secret-safety result

- No real secrets in any plugin file.
- No secrets in generated dist output.
- Fixtures use only synthetic/fake data.

## Separate workstream/drone non-regression result

- No drone commands added.
- No drone skills added.
- No MCP behavior added.
- Existing drone tests remain untouched.

## Whether P10 is safe to start

**Yes.** P09 is complete. The OpenClaw plugin structure, CLI support, hooks, docs, and tests are all in place. P10 (npm packaging) can proceed.
