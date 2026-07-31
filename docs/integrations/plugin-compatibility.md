# Plugin Compatibility Matrix

This document describes feature compatibility across the ryk CLI and host plugins.

## Feature Matrix

| Feature | ryk CLI | Codex Plugin | Claude Code Plugin | OpenCode Plugin | OpenClaw Plugin |
|---------|-----------|--------------|-------------------|-----------------|-----------------|
| plugin doctor | yes | calls CLI | calls CLI | calls CLI | calls CLI |
| manifest status | yes | yes | yes | yes | yes |
| install dry-run | yes | yes | yes | yes | yes |
| skills | n/a | yes | yes | n/a | n/a |
| hooks | n/a | yes | yes | yes | yes |
| decision API | yes | calls CLI | calls CLI | calls CLI | calls CLI |
| MCP server behavior | no | no | no | no | no |
| drone plugin features | no | no | no | no | no |
| telemetry | no | no | no | no | no |

## Command Compatibility

| Command | ryk CLI | Codex Plugin | Claude Code Plugin | OpenCode Plugin | OpenClaw Plugin |
|---------|-----------|--------------|-------------------|-----------------|-----------------|
| `ryk plugin doctor` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk plugin manifest` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk plugin install --dry-run` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk decide` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk hook` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk redteam --ci` | native | calls CLI | calls CLI | calls CLI | calls CLI |
| `ryk replay` | native | calls CLI | calls CLI | calls CLI | calls CLI |

## Host Limitations

### Codex

- Hooks are advisory; enforcement depends on Codex host support.
- Actual plugin loading mechanism depends on Codex version.
- Event names: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`.

### Claude Code

- Hooks are advisory; enforcement depends on Claude Code host support.
- Actual plugin loading mechanism depends on Claude Code version.
- Event names: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `SessionEnd`.

### OpenCode

- Hooks are advisory; enforcement depends on OpenCode host support.
- Actual plugin loading mechanism depends on OpenCode version.
- OpenCode uses hooks, not skills.
- Event names: `session.created`, `tool.execute.before`, `tool.execute.after`, `permission.asked`, `permission.replied`, `file.edited`, `command.executed`, `session.updated`, `session.idle`, `session.error`, `shell.env`.

### OpenClaw

- Hooks are advisory; enforcement depends on OpenClaw host support.
- **npm/ClawHub/CLI-metadata installs are `unprotected`** (`api.on` no-op; hooks do not fire). Supported path: `ryk openclaw` (grade **`wrapper`**).
- Actual plugin loading mechanism depends on OpenClaw version.
- OpenClaw uses hooks, not skills.
- OpenClaw hooks: `session_start`, `before_tool_call`, `after_tool_call`, `session_end` (map to ryk CLI events `session.start`, `tool.before`, `tool.after`, `session.end`).
- OpenClaw does not expose dedicated permission hooks; blocking is handled via `before_tool_call` only when hooks actually fire.
- npm package: published (ryk-openclaw-plugin@1.1.3) — distribution only, not enforcement
- ClawHub submission: published (ryk-openclaw-plugin@1.1.3) — distribution only, not enforcement

## Version Compatibility

| Component | Version | Minimum ryk CLI |
|-----------|---------|-------------------|
| ryk core | 1.1.0 | 1.0.0 |
| Codex plugin | 1.1.0 | 1.0.0 |
| Claude Code plugin | 1.1.0 | 1.0.0 |
| OpenCode plugin | 1.1.0 | 1.0.0 |
| OpenClaw plugin | 1.1.3 | 1.0.0 |

ryk plugins 1.x require ryk CLI >= 1.0.0.

## Platform Support

All plugin features work on the same platforms as the ryk CLI:

| Platform | ryk CLI | Codex Plugin | Claude Code Plugin | OpenCode Plugin | OpenClaw Plugin |
|----------|-----------|--------------|-------------------|-----------------|-----------------|
| macOS (arm64) | yes | yes | yes | yes | yes |
| macOS (x86_64) | yes | yes | yes | yes | yes |
| Linux (x86_64) | yes | yes | yes | yes | yes |
| Linux (arm64) | yes | yes | yes | yes | yes |
| Windows (x86_64) | yes | yes | yes | yes | yes |

## Marketplace Support

| Marketplace Type | Codex | Claude Code | OpenCode | OpenClaw |
|------------------|-------|-------------|----------|----------|
| Repo marketplace | `.agents/plugins/marketplace.json` | `.claude-plugin/marketplace.json` | n/a | n/a |
| Official marketplace | not yet listed | not yet listed | n/a | ClawHub: published |
| npm package | n/a | n/a | published (ryk-opencode-plugin@1.1.1) | published (ryk-openclaw-plugin@1.1.3) |

Repo marketplace files point to the local plugin directories:
- Codex: `integrations/codex-plugin/`
- Claude Code: `integrations/claude-code-plugin/`
- OpenClaw: `integrations/openclaw-plugin/`

These are repo marketplace sources, not official marketplace listings.

## What Is Not Supported

| Feature | Status | Notes |
|---------|--------|-------|
| MCP server behavior | not included | Future work if explicitly needed |
| Drone plugin features | not included | Separate workstream, out of scope |
| Telemetry | not included | No phone-home behavior |
| SaaS requirement | not included | All operations are local |
| Official marketplace | not yet implemented | Repo marketplace is available; official listing is separate |
| OpenClaw npm package | published | ryk-openclaw-plugin@1.1.3 |
| OpenClaw ClawHub submission | published in P11 | Published as `ryk-openclaw-plugin@1.1.3` |

## See Also

- `docs/integrations/ryk-cli-plugin.md`
- `docs/integrations/codex.md`
- `docs/integrations/claude-code.md`
- `docs/integrations/opencode.md`
- `docs/integrations/plugin-security-model.md`
