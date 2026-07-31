# P10 — OpenClaw npm Package Deliverable

## Summary

This phase packaged the ryk OpenClaw plugin for npm distribution as `ryk-openclaw-plugin`. The package is a thin wrapper around the ryk CLI and does not bundle or compile the Zig binary.

## Package path

```text
integrations/openclaw-plugin/
```

## Package name

```text
ryk-openclaw-plugin
```

## Package metadata status

- `package.json` exists and validates as JSON.
- `name` is `ryk-openclaw-plugin`.
- `version` is `1.1.3`.
- `main` points to `dist/index.js`.
- `types` points to `dist/index.d.ts`.
- `files` includes `dist`, `openclaw.plugin.json`, `README.md`, `package.json`.
- `openclaw` field exists with `extensions` and `runtimeExtensions`.
- `license` is `Apache-2.0`.
- No `preinstall`, `install`, or `postinstall` scripts.
- No MCP or drone fields.
- No telemetry fields.

## Manifest status

- `openclaw.plugin.json` exists and validates as JSON.
- Contains `id: "orca"`, `name: "ryk"`, `version: "1.1.3"`.
- Contains `configSchema` with `type: "object"`, `additionalProperties: false`.

## Build output status

- `dist/index.js` exists (5.9 kB).
- `dist/index.d.ts` exists (654 B).
- `dist/index.d.ts.map` exists (814 B).
- TypeScript compilation succeeded with zero errors.

## npm pack dry-run status

```bash
cd integrations/openclaw-plugin && npm pack --dry-run
```

Result: **succeeded**.

Tarball contents:

```text
package.json
openclaw.plugin.json
README.md
dist/index.js
dist/index.d.ts
dist/index.d.ts.map
```

Total files: 6
Package size: 4.6 kB
Unpacked size: 13.3 kB

## Package contents summary

The package includes only runtime artifacts and metadata:

| File | Purpose |
|------|---------|
| `package.json` | npm package metadata with `openclaw` field |
| `openclaw.plugin.json` | OpenClaw plugin manifest |
| `README.md` | Install and usage documentation |
| `dist/index.js` | Runtime JavaScript output |
| `dist/index.d.ts` | TypeScript declarations |
| `dist/index.d.ts.map` | Declaration source map |

The package does **not** include:

- `src/` (TypeScript source is not shipped in the npm package)
- `node_modules`
- Planning files
- Drone files
- `.mcp.json`
- Real secrets
- Temporary files
- `.git`
- zig build artifacts

## Docs updated

- `integrations/openclaw-plugin/README.md` — Added npm install instructions with `openclaw plugins install npm:ryk-openclaw-plugin`.
- `docs/integrations/openclaw.md` — Added npm install path, verification commands (`ryk plugin doctor openclaw`, `openclaw plugins list --json`, `openclaw plugins doctor`), and updated limitations wording.
- `docs/integrations/p09-openclaw-plugin.md` — Referenced as prior phase.

## Tests run

### Zig tests

```bash
zig build test
```

Result: **all tests pass**.

New tests added to `tests/phase39_openclaw_plugin.zig`:

- `openclaw package.json main points to dist/index.js`
- `openclaw package.json types points to dist/index.d.ts`
- `openclaw package.json files includes openclaw.plugin.json`
- `openclaw package.json has no install scripts`
- `openclaw package.json has no mcp or drone fields`
- `openclaw plugin README has npm install instructions`
- `openclaw plugin README does not claim npm publication happened`
- `openclaw plugin directory has no .mcp.json`
- `openclaw plugin directory has no drone files`

### Plugin smoke tests

```bash
cat tests/plugin-fixtures/openclaw/tool_command_safe.json | ./zig-out/bin/ryk hook openclaw tool.before
cat tests/plugin-fixtures/openclaw/tool_command_dangerous.json | ./zig-out/bin/ryk hook openclaw tool.before
./zig-out/bin/ryk plugin doctor openclaw
./zig-out/bin/ryk plugin manifest openclaw
```

Results: **all passed**.

### Cross-plugin regression tests

```bash
cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json | ./zig-out/bin/ryk hook codex PreToolUse
cat tests/plugin-fixtures/claude/pre_tool_use_command_safe.json | ./zig-out/bin/ryk hook claude PreToolUse
cat tests/plugin-fixtures/opencode/tool_execute_before_command_safe.json | ./zig-out/bin/ryk hook opencode tool.execute.before
```

Results: **all passed**.

### Redteam

```bash
./zig-out/bin/ryk redteam --ci
```

Result: **10/10 fixtures passed (100%)**.

### npm packaging script

```bash
./scripts/package-npm-plugins.sh
```

Result: **succeeded**. Produced:

```text
dist/npm/ryk-openclaw-plugin-v1.1.3.tgz
dist/npm/ryk-opencode-plugin-v1.1.1.tgz
dist/npm/ryk-npm-plugin-checksums.txt
```

Secret scan: **passed**.

## Secret-safety result

- No real secrets in any plugin file.
- No secrets in generated dist output.
- No secrets in npm tarball.
- Fixtures use only synthetic/fake data.
- Secret scan in packaging script passed.

## Known limitations

- npm package `ryk-openclaw-plugin@1.1.3` is published.
- ClawHub package `ryk-openclaw-plugin@1.1.3` is published.
- The OpenClaw plugin does not add MCP server behavior or drone-specific plugin features.
- Hooks are advisory for informational events; blocking hooks depend on OpenClaw honoring thrown errors.
- The strongest local protection remains `ryk openclaw`.

## Whether npm publication is ready

**Yes.** The `ryk-openclaw-plugin` package is ready for npm publication:

- Package metadata is complete.
- Runtime JS output exists.
- Type declarations exist.
- `openclaw.plugin.json` is included.
- `npm pack --dry-run` succeeds.
- Package contents are clean and minimal.
- Docs explain the npm install flow.
- The package does not bundle ryk CLI.
- The package requires `ryk` on PATH.
- No unsafe install scripts.
- No MCP behavior.
- No drone plugin behavior.
- No secrets.
- All existing tests pass.

To publish:

```bash
cd integrations/openclaw-plugin
npm login
npm publish --access public
```

## Files changed

- `integrations/openclaw-plugin/README.md` — Updated install instructions
- `integrations/openclaw-plugin/dist/index.js` — Built from src/index.ts
- `integrations/openclaw-plugin/dist/index.d.ts` — Generated by tsc
- `integrations/openclaw-plugin/dist/index.d.ts.map` — Generated by tsc
- `docs/integrations/openclaw.md` — Updated install and verification docs
- `scripts/package-npm-plugins.sh` — Added openclaw-plugin support
- `src/cli/plugin.zig` — Updated doctor note text
- `tests/phase39_openclaw_plugin.zig` — Added npm package validation tests
- `PLUGIN_RELEASE_NOTES.md` — Added npm install section and updated wording
- `PLUGIN_CHANGELOG.md` — Added OpenClaw plugin and npm packaging entries
- `LAUNCH_PLUGINS.md` — Updated P10 status

## New file created

- `docs/integrations/p10-openclaw-npm-package.md` — This deliverable document
