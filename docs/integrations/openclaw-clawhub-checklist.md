# ryk OpenClaw Plugin — ClawHub Readiness Checklist

This checklist tracks whether the ryk OpenClaw plugin is ready for ClawHub submission.

## Metadata Checklist

- [x] `openclaw.plugin.json` validates as JSON.
- [x] `openclaw.plugin.json` contains `id: "ryk"`.
- [x] `openclaw.plugin.json` contains `name: "ryk"`.
- [x] `openclaw.plugin.json` contains `version`.
- [x] `openclaw.plugin.json` contains `description`.
- [x] `openclaw.plugin.json` contains `configSchema`.
- [x] `package.json` validates as JSON.
- [x] `package.json` `name` is `ryk-openclaw-plugin`.
- [x] `package.json` `main` points to `dist/index.js`.
- [x] `package.json` `types` points to `dist/index.d.ts`.
- [x] `package.json` `files` includes `dist`, `openclaw.plugin.json`, `README.md`, `package.json`.
- [x] `package.json` includes `openclaw` field with `extensions` and `runtimeExtensions`.
- [x] `package.json` `license` is `Apache-2.0`.

## Build Checklist

- [x] `npm run build` succeeds (TypeScript compiles with zero errors).
- [x] `dist/index.js` exists.
- [x] `dist/index.d.ts` exists.
- [x] `dist/index.d.ts.map` exists.

## npm Package Checklist

- [x] `npm pack --dry-run` succeeds.
- [x] Package contents include `package.json`, `openclaw.plugin.json`, `README.md`, `dist/index.js`, `dist/index.d.ts`.
- [x] Package does not include `node_modules`.
- [x] Package does not include `src/` (source is not shipped in npm package).
- [x] Package does not include planning files.
- [x] Package does not include drone files.
- [x] Package does not include `.mcp.json`.
- [x] Package does not include real secrets.
- [x] Package does not include temporary files.
- [x] Package does not include zig build artifacts.

## Safety Checklist

- [x] No `preinstall`, `install`, or `postinstall` scripts in `package.json`.
- [x] No scripts that compile Zig.
- [x] No scripts that download or execute binaries.
- [x] No raw secrets in any plugin file.
- [x] No raw secrets in generated `dist/` output.
- [x] No `.env` file in plugin directory.
- [x] No MCP fields in `package.json`.
- [x] No drone fields in `package.json`.
- [x] No telemetry fields.

## Docs Checklist

- [x] `integrations/openclaw-plugin/README.md` explains ryk CLI dependency.
- [x] `docs/integrations/openclaw.md` explains install paths.
- [x] `docs/integrations/openclaw-clawhub.md` exists (ClawHub submission docs).
- [x] `docs/integrations/openclaw-clawhub-checklist.md` exists (this checklist).
- [x] Docs do not claim ClawHub publication before it happens.
- [x] Docs do not claim npm publication happened unless it did.
- [x] Release notes are honest about publication status.

## ryk CLI Checklist

- [x] `ryk plugin doctor openclaw` reports plugin directory present.
- [x] `ryk plugin manifest openclaw` reports manifest exists.
- [x] `ryk plugin install openclaw --dry-run` succeeds.
- [x] Hook smoke test (`tool.before` with safe fixture) returns `allow`.
- [x] Hook smoke test (`tool.before` with dangerous fixture) returns `block`.
- [x] `zig build test` passes.
- [x] `ryk redteam --ci` passes (10/10 fixtures).

## Cross-Plugin Regression Checklist

- [x] Codex plugin smoke test passes.
- [x] Claude Code plugin smoke test passes.
- [x] OpenCode plugin smoke test passes.

## ClawHub CLI Checklist

- [x] `clawhub` CLI is installed and authenticated.
- [x] `clawhub package publish --dry-run` succeeds.
- [x] Real `clawhub package publish` has been run and confirmed.

## Summary

| Category | Status |
|----------|--------|
| Metadata | Ready |
| Build | Ready |
| npm Package | Ready |
| Safety | Ready |
| Docs | Ready |
| ryk CLI | Ready |
| Cross-plugin | Ready |
| ClawHub CLI | Published |
| Support links | Ready |
| Release notes | Ready |

**ClawHub submission is complete. The plugin is published as `ryk-openclaw-plugin@1.1.3`.**

The manual publish command (when authorized) is:

```bash
clawhub publish \
  --slug ryk \
  --name "ryk" \
  --version 1.1.3 \
  --tags "security,guardrails,ai-agents" \
  ./integrations/openclaw-plugin
```

After publication, users should be able to install with:

```bash
openclaw plugins install clawhub:ryk-openclaw-plugin
```
