# ryk CLI Plugin Surface

> Scope: P01 — ryk CLI plugin namespace and safe plugin-facing surfaces
> Version: 1.1.0

## Overview

The ryk CLI itself is now plugin-capable. This means:

- The `ryk` binary exposes a `plugin` command namespace.
- Host plugins (Codex, Claude Code, and future integrations) call the ryk CLI instead of duplicating policy logic.
- The ryk CLI remains the source of truth for policy, audit, replay, and capability reporting.

## Commands

### `ryk plugin doctor`

Reports ryk version, workspace state, policy presence, host binary detection, plugin directory status, and platform capabilities.

```sh
ryk plugin doctor
ryk plugin doctor --json
ryk plugin doctor codex
ryk plugin doctor claude
ryk plugin doctor codex --json
ryk plugin doctor claude --json
```

**Security properties:**
- Does not print raw environment variable values.
- Does not print secrets, credentials, or connection strings.
- Does not claim a host plugin is installed unless detected.
- Does not claim a protection is active unless it is actually active.

### `ryk plugin manifest`

Reports the expected plugin manifest path and existence status.

```sh
ryk plugin manifest codex
ryk plugin manifest claude
ryk plugin manifest all
ryk plugin manifest codex --json
```

If a manifest does not exist yet, it reports `missing` clearly — not as an error.

Expected paths:
- Codex: `integrations/codex-plugin/.codex-plugin/plugin.json`
- Claude Code: `integrations/claude-code-plugin/.claude-plugin/plugin.json`

### `ryk plugin install`

Previews or performs plugin installation. Defaults to safe dry-run behavior.

```sh
ryk plugin install codex --dry-run
ryk plugin install claude --dry-run
ryk plugin install all --dry-run
ryk plugin install codex --path <plugin-path> --dry-run
```

**Safety rules:**
- Defaults to `--dry-run` if the actual host install command is not known.
- Never silently overwrites user config.
- Requires `--yes` for non-dry-run installation.
- Does not mutate Codex or Claude config silently.
- Does not store credentials.
- Does not add telemetry.

### `ryk decide`

Exposes stable JSON decisions for commands, files, prompts, and host tool calls.

```sh
ryk decide command --json '{"version":1,"host":"codex","command":"git status"}'
ryk decide command --json '{"version":1,"host":"claude","command":"git status"}'
ryk decide file --json '{"version":1,"host":"codex","path":"/etc/passwd","operation":"write"}'
ryk decide prompt --json '{"version":1,"host":"claude","prompt":"hello"}'
ryk decide tool --json '{"version":1,"host":"codex","tool":"shell","command":"ls"}'
```

### `ryk hook`

Processes host plugin lifecycle hooks with JSON payloads on stdin.

```sh
echo '{"version":1,"host":"codex","event":"PreToolUse","payload":{"tool":"shell","command":"git status"}}' \
  | ryk hook codex PreToolUse
```

## Plugin Packaging

Plugin artifacts are packaged by `scripts/package-plugins.sh` (and `scripts/package-plugins.ps1` on Windows).

Packaged artifacts:

```text
dist/plugins/ryk-codex-plugin-vX.Y.Z.zip
dist/plugins/ryk-claude-code-plugin-vX.Y.Z.zip
dist/plugins/ryk-plugin-checksums.txt
```

Artifact contents include:
- Plugin manifest (`plugin.json`)
- Skills directory
- Hooks configuration (`hooks.json`)
- README

Artifacts exclude:
- `.mcp.json`
- Drone files
- Build artifacts
- Temporary files
- Secrets

## Install dry-run behavior

`ryk plugin install` defaults to `--dry-run`. In dry-run mode:
- The command previews what would be installed.
- No host configuration is mutated.
- The user sees the plugin path, manifest status, and host compatibility.

For actual installation, use `--yes`:
```sh
ryk plugin install codex --yes
```

## Host limitations

Plugin hooks are limited by host capabilities. ryk cannot enforce what the host IDE does not expose.

- Codex hooks: advisory; enforcement depends on Codex host support.
- Claude Code hooks: advisory; enforcement depends on Claude Code host support.

## Architecture

```
Host IDE (Codex / Claude Code / Cursor / ...)
    |
    v
ryk CLI plugin surface  <--  ryk plugin doctor / manifest / install
    |
    v
ryk Core (policy, audit, replay, decision engine)
```

Plugins call ryk instead of duplicating policy logic. The strongest local protection remains:

```sh
ryk run -- <agent-command>
```

## No Telemetry, No SaaS

- No telemetry is collected by the plugin surface.
- No SaaS account, dashboard, or monetization layer is required.
- All operations are local to the machine.

## Drone Safety Reporting

When the ryk Edge workstream is detected, `ryk plugin doctor` includes a drone safety section:

```
Drone workstream:
  detected: yes
  safety mode: plugin default-deny for live-control patterns
  simulation demos: allowed
  live control: requires explicit policy and human approval
```

Live drone operations are classified as safety-critical and require explicit policy and human approval.

## Schemas

Plugin request/response schemas live in:
- `integrations/common/schemas/ryk-plugin-request-v1.json`
- `integrations/common/schemas/ryk-plugin-response-v1.json`

Hook request/response schemas live in:
- `integrations/common/schemas/hook-request-v1.json`
- `integrations/common/schemas/hook-response-v1.json`

## Compatibility

ryk plugins 1.x require ryk CLI >= 1.0.0.

| Component | Version |
|-----------|---------|
| ryk core | 1.1.0 |
| Codex plugin | 1.1.0 |
| Claude Code plugin | 1.1.0 |

## See Also

- `docs/integrations/plugin-security-model.md`
- `docs/integrations/plugin-troubleshooting.md`
- `docs/integrations/plugin-compatibility.md`
- `docs/integrations/drone-safety.md`
- `RYK_CLI_PLUGIN_CONTRACT.md`
- `PLUGIN_SECURITY_MODEL.md`
