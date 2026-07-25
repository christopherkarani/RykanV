# Orca Codex Plugin Integration

This document describes the Orca Codex plugin, how to install it, and how to use it.

## Overview

The Orca Codex plugin is a local integration package that adds Orca skills and lifecycle hooks to Codex. It lives under `integrations/codex-plugin/` in the Orca repository.

The plugin is a thin layer. All policy decisions are made by the Orca CLI. The plugin does not duplicate policy logic.

## Prerequisites

- Zig 0.15.2 (to build Orca from source)
- Orca CLI built and available in PATH
- Codex host binary installed

## Install instructions

### Build Orca

```bash
zig build
```

### Install from release artifact

1. Download the latest plugin zip from the release page:
   ```text
   orca-codex-plugin-vX.Y.Z.zip
   ```

2. Verify the checksum:
   ```bash
   sha256sum -c orca-plugin-checksums.txt
   ```

3. Extract the plugin to your preferred location:
   ```bash
   unzip orca-codex-plugin-vX.Y.Z.zip -d ~/orca-plugins/codex
   ```

4. Point Codex to the extracted plugin directory.

### Install from local path (repo)

1. Build Orca:
   ```bash
   zig build
   ```

2. Point Codex to the plugin directory:
   ```text
   integrations/codex-plugin/
   ```

3. Verify the plugin is recognized:
   ```bash
   ./zig-out/bin/orca plugin doctor codex
   ```

### Repo marketplace install

If your Codex version supports repo marketplace sources, add this repository:

```bash
codex plugin marketplace add christopherkarani/rykan
```

Then install ryk from Codex's plugin UI/directory after adding the marketplace.

This command adds the ryk repository as a plugin marketplace source. This is not the same as being listed in the official Codex marketplace.

### Local marketplace example

For reference, a local marketplace example is available at:

```text
integrations/codex-plugin/examples/marketplace.json
```

This is a documented example only. The exact schema depends on your Codex version.

The root-level marketplace file for repo marketplace install is:

```text
.agents/plugins/marketplace.json
```

### Manual fallback install

If your Codex version does not support automatic plugin loading:

1. Copy the skills from `integrations/codex-plugin/skills/` into your Codex skills directory.
2. Copy the hooks from `integrations/codex-plugin/hooks/hooks.json` into your Codex hooks configuration.
3. Ensure `orca` is in PATH or use the full path to the binary.

## Verify install

### Plugin doctor

```bash
./zig-out/bin/orca plugin doctor codex
```

Expected output sections:
- Orca version
- Policy status (present/valid)
- Plugin directories (codex: found)
- Host binaries (codex: detected or not detected)

### Plugin manifest

```bash
./zig-out/bin/orca plugin manifest codex
```

This reports the expected manifest path and existence status.

### Hook smoke test

```bash
cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json \
  | ./zig-out/bin/orca hook codex PreToolUse
```

Expected: `allow` decision in valid JSON.

### Run redteam

```bash
./zig-out/bin/orca redteam --ci
```

### Replay last session

```bash
./zig-out/bin/orca replay --session last --verify
```

## Skill list

| Skill | File | Purpose |
|-------|------|---------|
| `orca-doctor` | `skills/orca-doctor/SKILL.md` | Check installation and readiness |
| `orca-init` | `skills/orca-init/SKILL.md` | Create or repair a policy |
| `orca-protect` | `skills/orca-protect/SKILL.md` | Explain strongest protection |
| `orca-redteam` | `skills/orca-redteam/SKILL.md` | Run red-team fixtures |
| `orca-replay` | `skills/orca-replay/SKILL.md` | Replay latest session |

## Hook list

Hooks call `orca hook codex <event>` with a JSON payload on stdin:

| Event | Description | Timeout |
|-------|-------------|---------|
| `SessionStart` | Session initialization check | 10s |
| `UserPromptSubmit` | Prompt secret/redaction check | 10s |
| `PreToolUse` | Tool use policy evaluation | 15s |
| `PermissionRequest` | Permission policy evaluation | 15s |
| `PostToolUse` | Post-tool acknowledgment | 10s |
| `Stop` | Session stop notification | 10s |

## Uninstall

Remove the plugin from Codex using your Codex plugin management commands. This plugin does not mutate host configuration, so uninstalling is safe.

If you installed from a release artifact, simply delete the extracted directory.

## Troubleshooting

### Plugin directory not found

Ensure you run `orca plugin doctor codex` from the repository root. The doctor looks for `integrations/codex-plugin/` relative to the workspace root.

### Hooks timeout

If hooks exceed their timeout, Codex may skip them. Check that `orca` is in PATH and that `.orca/policy.yaml` loads quickly.

### Policy not found

Run `orca init --preset codex` to create a default policy, then validate with `orca policy check .orca/policy.yaml`.

### Orca binary not found

Build Orca with `zig build` or ensure `./zig-out/bin/orca` is in your PATH.

### Fake secret redaction questions

The plugin uses synthetic test secrets (e.g., `fake_p05_secret_value`) in fixtures only. If you see redaction warnings about these values in test output, that is expected behavior.

## Limitations

- Hooks are advisory; enforcement depends on Codex host support.
- The strongest protection is `orca codex`.
- Plugin installation is a preview/dry-run by default.
- No telemetry is collected.
- Official marketplace availability is not yet implemented.

## Security model

- The Orca CLI is the source of truth.
- The plugin does not reimplement policy logic.
- No secrets are stored in plugin files.
- Hook stdout is host-valid JSON.
- Human logs go to stderr.
- CI mode never prompts.

## Separate workstream note

A separate drone workstream exists in this repository under `packages/edge/`. The Orca Codex plugin does not expose or modify drone functionality.

## No MCP support

This plugin does not add MCP server behavior.

## No drone plugin support

This plugin does not add drone-specific plugin features.
