# OpenClaw plugin distribution

This page covers local package validation and registry distribution for the OpenClaw integration. A package install is not proof that enforcement is active. Current npm and ClawHub installs use OpenClaw's CLI-metadata path, where hooks do not enforce tool calls. Use `ryk openclaw` when process supervision is required.

## Validate the local package

The package lives at `integrations/openclaw-plugin/` and requires a separately installed `ryk` binary.

```sh
ryk doctor
npm run build --prefix integrations/openclaw-plugin
npm pack --dry-run ./integrations/openclaw-plugin
node -e "JSON.parse(require('fs').readFileSync('integrations/openclaw-plugin/openclaw.plugin.json'))"
```

Check the package contents before publishing. It should contain the compiled plugin, manifest, README, and package metadata. It should not contain install scripts, secrets, telemetry code, or MCP server configuration.

## Registry publication

Registry commands and publication status change independently of the ryk release. Follow the current [ClawHub documentation](https://docs.openclaw.ai/clawhub) and verify the package name and version in the registry before making a release claim.

Keep the package version aligned with `VERSION`. Do not put credentials or registry tokens in this repository.

## Verify an installed package

```sh
ryk plugin doctor openclaw
ryk plugin manifest openclaw
ryk plugin install openclaw --dry-run
openclaw plugins list --json
```

For a hook smoke test from this repository:

```sh
cat tests/plugin-fixtures/openclaw/tool_command_safe.json \
  | ./zig-out/bin/ryk hook openclaw tool.before
```

For the enforcement boundary and known host limitations, read [the OpenClaw integration guide](openclaw.md) and [the plugin security model](plugin-security-model.md).
