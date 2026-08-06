# ryk Plugin Changelog

Entries before the 1.2.9 hard cut retain historical product names where they
describe the releases that originally shipped them.

## 1.2.8 — 2026-07-04

### Changed
- All plugins and core unified to version **1.2.8**.

## 1.2.7 — 2026-07-03

### Changed
- All plugins and core unified to version **1.2.7**.
- Pi session identifiers are available to dashboard activity feeds.

## 1.2.6 — 2026-07-01

### Changed
- All plugins and core unified to version **1.2.6**.

### Fixed
- Minor stability improvements across plugin integrations.

## 1.2.5 — Branded guardrail decisions

### Changed
- **Pi extension** — block and ask states now use related, compact Orca cards with distinct frames, clearer reason labels, and stable above-editor placement.
- **OpenCode and OpenClaw** — fallback denial copy now identifies Orca explicitly.
- All plugins and core unified to version **1.2.5**.

## 1.2.4 — Pi session commands and release alignment

### Added
- **Pi extension** — `/orca-start` and `/orca-stop` slash commands for in-session protection control.

### Changed
- All plugins and core unified to version **1.2.4**.

### Fixed
- OpenCode 1.16 plugin API compatibility from 1.2.3 remains stable.

## 1.2.3 — OpenCode 1.16 plugin API fix

### Fixed
- **OpenCode plugin** — Rewrote `orca.ts` for the OpenCode 1.16 `Plugin` hook API (`tool.execute.before`, `permission.ask`, `event`). The previous `context.hooks.on` integration crashed at load on current OpenCode, so tool blocking never ran.

## 1.2.2 — One-step Pi onboarding and runtime packaging

### Added
- **Pi extension** — depends on the version-matched `@orca-sec/orca` package, resolves its bundled CLI and daemon, initializes missing workspace policy on session start, and exposes Pi-only `/orca-setup` without installing unrelated agent plugins.

### Changed
- **Pi extension** — `/orca-start` is a deprecated alias for `/orca-setup`; `/orca-doctor` now uses the supported `orca doctor` interface.

## 1.2.1 — Pi `/orca-start` non-interactive fix

### Fixed
- **Pi extension** (`ryk-pi/` → `@orca-sec/pi-orca@1.2.1`) — `/orca-start` now runs `orca start --auto` so onboarding works when Pi spawns Orca without a TTY (fixes exit code 2 in non-interactive terminals).

## 1.2.0 — Daemon Integration and Pi Extension

### Added
- **Pi extension** (`ryk-pi/` → `@orca-guard/pi-orca@1.2.0`) — Intercepts Pi `bash` tool calls via `orca evaluate --json --stdin`. First public npm publish.
- Slash commands `/orca-start`, `/orca-doctor`, `/orca-mode` for Pi sessions.

### Changed
- All hook-bridge plugins unified to version **1.2.0** (Codex, Claude, OpenCode, OpenClaw, Hermes Agent).
- Shell evaluation for hook hosts now benefits from daemon-backed policy when `orca-daemon` is running.

### Fixed
- **Hermes Agent** — Hardened Orca discovery, `RYK_HERMES_FAIL_OPEN` degraded-mode behavior, and install path alignment with `orca plugin doctor`.
- **Pi** — Honor deny decisions, request timeouts, cwd propagation, and auto unavailable-mode handling.

## 1.1.4 — Unified Version Release

### Fixed
- **OpenClaw plugin:** Detect and warn when `api.on` is a no-op for npm installs. Hooks silently failed when OpenClaw loaded the plugin via `registrationMode: "cli-metadata"`.
- Added unit tests for the `isOnNoop()` heuristic using Node's built-in test runner.

### Changed
- All plugins and core unified to version **1.1.4**.
- OpenClaw plugin: version aligned across `package.json`, `package-lock.json`, and `openclaw.plugin.json`.
- OpenCode plugin: version bumped to 1.1.4.
- Hermes plugin: version bumped to 1.1.4.
- Codex plugin: version bumped to 1.1.4.
- Claude Code plugin: version bumped to 1.1.4.

## 1.1.0 — Plugin Distribution and Marketplace

### Added

- **Codex plugin** (`integrations/codex-plugin/`)
  - Plugin manifest (`.codex-plugin/plugin.json`)
  - Skills: `orca-doctor`, `orca-init`, `orca-protect`, `orca-redteam`, `orca-replay`
  - Hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`
  - README with install instructions
  - Local marketplace example (`examples/marketplace.json`)

- **Claude Code plugin** (`integrations/claude-code-plugin/`)
  - Plugin manifest (`.claude-plugin/plugin.json`)
  - Skills: `doctor`, `init`, `protect`, `redteam`, `replay`
  - Hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `SessionEnd`
  - README with install instructions

- **OpenCode plugin** (`integrations/opencode-plugin/`)
  - Main file: `orca.ts`
  - Hooks: `session.created`, `tool.execute.before`, `tool.execute.after`, `permission.asked`, `permission.replied`, `file.edited`, `command.executed`, `session.updated`, `session.idle`, `session.error`, `shell.env`
  - README with install instructions

- **OpenClaw plugin** (`integrations/openclaw-plugin/`)
  - Manifest: `openclaw.plugin.json`
  - Package: `package.json` with `openclaw` field
  - Hooks: `session.start`, `tool.before`, `tool.after`, `permission.before`, `permission.after`, `session.end`
  - README with install instructions
  - npm package `orca-openclaw-plugin` prepared for distribution

- **Claude marketplace catalog** (`integrations/claude-marketplace/`)
  - Local marketplace example (`marketplace.json`)
  - README with usage instructions

- **Plugin packaging scripts**
  - `scripts/package-plugins.sh` — creates plugin zips and checksums
  - `scripts/package-plugins.ps1` — Windows PowerShell equivalent
  - `scripts/package-npm-plugins.sh` — creates npm tarballs and checksums
  - Produces:
    - `dist/plugins/orca-codex-plugin-vX.Y.Z.zip`
    - `dist/plugins/orca-claude-code-plugin-vX.Y.Z.zip`
    - `dist/plugins/orca-opencode-plugin-vX.Y.Z.zip`
    - `dist/plugins/orca-claude-marketplace-vX.Y.Z.zip`
    - `dist/plugins/orca-plugin-checksums.txt`
    - `dist/npm/orca-opencode-plugin-vX.Y.Z.tgz`
    - `dist/npm/orca-openclaw-plugin-vX.Y.Z.tgz`
    - `dist/npm/orca-npm-plugin-checksums.txt`

- **Plugin documentation**
  - `docs/integrations/codex.md` — Codex plugin install and usage
  - `docs/integrations/claude-code.md` — Claude Code plugin install and usage
  - `docs/integrations/opencode.md` — OpenCode plugin install and usage
  - `docs/integrations/orca-plugin.md` — Orca plugin surface reference
  - `docs/integrations/plugin-troubleshooting.md` — Common issues and fixes
  - `docs/integrations/plugin-security-model.md` — Trust boundaries and invariants
  - `docs/integrations/separate-workstream-guardrails.md` — Drone workstream isolation
  - `docs/integrations/plugin-compatibility.md` — Feature matrix

- **Release workflow updates**
  - Plugin packaging step added to `.github/workflows/release.yml`
  - Plugin artifacts uploaded alongside release binaries
  - Secret scan step runs before artifact upload

### Security

- No raw secrets in plugin artifacts.
- No raw secrets in documentation.
- No telemetry.
- No silent config mutation.
- Plugin install docs are reversible.
- Checksums generated for all plugin zips.
- Secret scan runs over artifacts before release.

### Known Limitations

- Hooks are advisory; they do not enforce policy independently of the host.
- The strongest local protection remains `orca run -- <agent-command>`.
- Official marketplace availability is not yet implemented.
- Plugin installation is preview/dry-run by default.
- No MCP server behavior is included.
- No drone-specific plugin features are included.

### Compatibility

- Orca core: 1.1.4
- Codex plugin: 1.1.4
- Claude Code plugin: 1.1.4
- OpenCode plugin: 1.1.4
- OpenClaw plugin npm package: 1.1.4 (published as `orca-openclaw-plugin`)
- OpenClaw ClawHub submission: published as `orca-openclaw-plugin@1.1.4`
- Requires Orca >= 1.0.0

---

## How to Verify This Release

```bash
# Build Orca
zig build

# Run tests
zig build test

# Verify plugin doctors
./zig-out/bin/ryk plugin doctor codex
./zig-out/bin/ryk plugin doctor claude
./zig-out/bin/ryk plugin doctor opencode

# Verify manifests
./zig-out/bin/ryk plugin manifest codex
./zig-out/bin/ryk plugin manifest claude
./zig-out/bin/ryk plugin manifest opencode

# Verify install dry-run
./zig-out/bin/ryk plugin install codex --dry-run
./zig-out/bin/ryk plugin install claude --dry-run
./zig-out/bin/ryk plugin install opencode --dry-run

# Test hooks
cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json \
  | ./zig-out/bin/ryk hook codex PreToolUse
cat tests/plugin-fixtures/claude/pre_tool_use_command_safe.json \
  | ./zig-out/bin/ryk hook claude PreToolUse
cat tests/plugin-fixtures/opencode/tool_execute_before_safe.json \
  | ./zig-out/bin/ryk hook opencode tool.execute.before

# Package plugins
./scripts/package-plugins.sh

# Verify artifacts
ls -la dist/plugins
cat dist/plugins/orca-plugin-checksums.txt

# Run redteam
./zig-out/bin/ryk redteam --ci
```
