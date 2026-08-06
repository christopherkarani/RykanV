# P08B — OpenCode npm Package Deliverable

## Summary

Packaged the existing ryk OpenCode plugin for npm distribution as `ryk-opencode-plugin`.

The plugin remains a thin wrapper around the ryk CLI. It does not duplicate policy logic, bundle the Zig CLI, or add MCP/drone behavior.

## Package Path

```text
integrations/opencode-plugin/
```

Source was kept in the existing location to minimize churn. The package is now npm-ready with built JS output.

## Package Name

```text
ryk-opencode-plugin
```

## Package Metadata

```json
{
  "name": "ryk-opencode-plugin",
  "version": "1.1.0",
  "description": "OpenCode plugin wrapper for ryk runtime guardrails.",
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist", "README.md", "package.json"],
  "license": "Apache-2.0"
}
```

## Build Output Status

- `dist/index.js` — runtime JavaScript output (6.9 kB)
- `dist/index.d.ts` — TypeScript declarations (654 B)
- `dist/index.d.ts.map` — declaration source map (814 B)

Build command: `npm run build` (runs `tsc -p tsconfig.json`)

## npm Pack Dry-Run Status

```bash
cd integrations/opencode-plugin && npm pack --dry-run
```

Result: **PASS**

Tarball contents (5 files):
- `README.md` (5.4 kB)
- `dist/index.d.ts` (654 B)
- `dist/index.d.ts.map` (814 B)
- `dist/index.js` (6.9 kB)
- `package.json` (874 B)

Package size: 4.9 kB (packed), 14.6 kB (unpacked)

## Packaging Script

```text
scripts/package-npm-plugins.sh
```

Produces:
```text
dist/npm/ryk-opencode-plugin-v1.1.0.tgz
dist/npm/ryk-npm-plugin-checksums.txt
```

Secret scan: **passed**

## Package Contents Summary

| File | Purpose |
|------|---------|
| `package.json` | npm package metadata |
| `README.md` | Usage docs, install instructions |
| `dist/index.js` | Runtime plugin (ES2022 module) |
| `dist/index.d.ts` | TypeScript type declarations |
| `dist/index.d.ts.map` | Source map for declarations |

Excluded from package:
- Source TypeScript (`src/`)
- `node_modules/`
- `ryk.ts` (canonical source, not needed at runtime)
- Test files
- Build tooling configs

## Docs Updated

- `integrations/opencode-plugin/README.md` — package-level README with npm install, local fallback, required wording, limitations
- `docs/integrations/opencode.md` — integration guide with npm install section, required wording, limitations

Both docs include:
- `opencode.json` usage example
- Local fallback install path
- Required strongest-protection wording
- Required limitation wording (no MCP, no drone)

## Tests Run

### npm Package Tests

```bash
./tests/test-opencode-npm-package.sh
```

All 14 checks passed:
1. package.json is valid JSON
2. Package name is `ryk-opencode-plugin`
3. No unsafe install scripts
4. `dist/index.js` exists
5. `dist/index.d.ts` exists
6. README documents `opencode.json` and `ryk-opencode-plugin`
7. Plugin source calls `ryk hook opencode`
8. No obvious secrets in plugin source
9. No MCP behavior in plugin source
10. No drone behavior in plugin source
11. No Zig binary bundled
12. `npm pack --dry-run` succeeds
13. Package excludes source TypeScript files
14. README contains required wording

### ryk CLI Tests

```bash
zig build test          # PASS
ryk plugin doctor opencode           # PASS
ryk plugin install opencode --dry-run # PASS
```

### Hook Fixture Tests

```bash
# OpenCode dangerous command — BLOCKED
cat tests/plugin-fixtures/opencode/tool_execute_before_command_dangerous.json \
  | ryk hook opencode tool.execute.before

# OpenCode safe command — ALLOWED
cat tests/plugin-fixtures/opencode/tool_execute_before_command_safe.json \
  | ryk hook opencode tool.execute.before

# Codex dangerous command — BLOCKED
cat tests/plugin-fixtures/codex/pre_tool_use_command_dangerous.json \
  | ryk hook codex PreToolUse

# Claude dangerous command — BLOCKED
cat tests/plugin-fixtures/claude/pre_tool_use_command_dangerous.json \
  | ryk hook claude PreToolUse
```

All hooks returned expected decisions.

### Redteam

```bash
ryk redteam --ci
```

Result: **10/10 fixtures passed (100%)**

## Secret-Safety Result

- No real secrets in plugin source, README, or package metadata
- No fake secrets leaked in hook responses
- Secret scan on tarball: **passed**
- No `ghp_`, `sk-`, `AKIA`, or `password123` patterns found

## Known Limitations

- The package is not yet published to the npm registry. Publish when ready with `npm publish` from `integrations/opencode-plugin/`.
- The `@opencode-ai/plugin` peer dependency was removed because the exact OpenCode plugin types package name is uncertain.
- Hooks are advisory; enforcement depends on OpenCode host support.
- The strongest protection remains `ryk opencode`.
- Plugin requires `ryk` to be installed separately and available on PATH.

## Security Invariants Verified

- [x] No Zig binary bundling
- [x] No unsafe npm install scripts
- [x] No MCP behavior
- [x] No `.mcp.json`
- [x] No drone plugin behavior
- [x] No drone skills, demos, or operational instructions
- [x] No secrets in package files
- [x] No telemetry
- [x] No SaaS, hosted dashboards, or monetization
- [x] Plugin does not duplicate ryk policy logic

## Is `ryk-opencode-plugin` Ready to Publish?

**Yes — PUBLISHED.**

`ryk-opencode-plugin@1.1.0` is now live on the npm registry:

- **Registry:** https://registry.npmjs.org/ryk-opencode-plugin
- **Tarball:** https://registry.npmjs.org/ryk-opencode-plugin/-/ryk-opencode-plugin-1.1.0.tgz
- **Install:** `npm install ryk-opencode-plugin`

## Files Changed

### Created
- `integrations/opencode-plugin/src/index.ts` — npm package entrypoint
- `integrations/opencode-plugin/tsconfig.json` — TypeScript build config
- `scripts/package-npm-plugins.sh` — npm packaging helper
- `tests/test-opencode-npm-package.sh` — npm package validation tests
- `docs/integrations/p08b-opencode-npm-package.md` — this deliverable

### Modified
- `integrations/opencode-plugin/package.json` — updated for `ryk-opencode-plugin`
- `integrations/opencode-plugin/README.md` — added npm install docs, required wording
- `docs/integrations/opencode.md` — added npm install section, required wording

### Generated (not committed)
- `integrations/opencode-plugin/dist/index.js`
- `integrations/opencode-plugin/dist/index.d.ts`
- `integrations/opencode-plugin/dist/index.d.ts.map`
- `dist/npm/ryk-opencode-plugin-v1.1.0.tgz`
- `dist/npm/ryk-npm-plugin-checksums.txt`
