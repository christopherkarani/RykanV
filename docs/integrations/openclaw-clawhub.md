# ryk OpenClaw Plugin — ClawHub Submission

This document describes how to publish the ryk OpenClaw plugin to [ClawHub](https://docs.openclaw.ai/clawhub), the OpenClaw plugin registry.

## What is ClawHub

ClawHub is the OpenClaw plugin registry. After publication, users can install the ryk plugin with:

```bash
openclaw plugins install clawhub:orca
```

**Status:** The plugin has been published to ClawHub as `ryk-openclaw-plugin@1.1.3`.

## Prerequisites

1. **ryk CLI installed separately**
   The plugin requires `ryk` to be available on `PATH`. It does not bundle the ryk CLI.

   ```bash
   ryk doctor
   ```

2. **OpenClaw plugin package exists**
   The plugin package is at `integrations/openclaw-plugin/`.

3. **npm package metadata validates**
   Verify with:

   ```bash
   npm run build --prefix integrations/openclaw-plugin
   npm pack --dry-run ./integrations/openclaw-plugin
   ```

4. **Runtime JS exists**
   `dist/index.js` and `dist/index.d.ts` must exist after `npm run build`.

## Package Metadata Validation

### `openclaw.plugin.json`

```json
{
  "id": "orca",
  "name": "ryk",
  "version": "1.1.3",
  "description": "Runtime guardrails for OpenClaw workflows via the ryk CLI.",
  "configSchema": {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  }
}
```

Checks:
- `id` is `"orca"` ✓
- `name` is `"ryk"` ✓
- `version` is present ✓
- `description` is accurate ✓
- `configSchema` exists ✓

### `package.json`

- `name`: `ryk-openclaw-plugin` ✓
- `main`: `dist/index.js` ✓
- `types`: `dist/index.d.ts` ✓
- `files`: includes `dist`, `openclaw.plugin.json`, `README.md`, `package.json` ✓
- `openclaw` field exists with `extensions` and `runtimeExtensions` ✓
- No `preinstall`, `install`, or `postinstall` scripts ✓
- No MCP fields ✓
- No drone fields ✓
- No telemetry fields ✓
- No secrets ✓

## Publish Commands

### Validation (dry-run)

Before publishing, validate the package:

```bash
# 1. Build the plugin
npm run build --prefix integrations/openclaw-plugin

# 2. Verify npm package contents
npm pack --dry-run ./integrations/openclaw-plugin

# 3. Verify the plugin manifest is valid JSON
node -e "JSON.parse(require('fs').readFileSync('integrations/openclaw-plugin/openclaw.plugin.json'))"

# 4. Run ryk plugin checks
./zig-out/bin/ryk plugin doctor openclaw
./zig-out/bin/ryk plugin manifest openclaw
./zig-out/bin/ryk plugin install openclaw --dry-run
```

### Publish command (already completed)

The plugin was published with:

```bash
clawhub package publish \
  ./integrations/openclaw-plugin \
  --family code-plugin \
  --name "ryk-openclaw-plugin" \
  --display-name "ryk" \
  --version "1.1.3" \
  --changelog "Initial ClawHub submission..." \
  --tags "security,guardrails,ai-agents,policy,audit,latest"
```

The `clawhub publish` command (ClawHub CLI v0.7.0) accepts:
- `--slug <slug>` — Skill slug
- `--name <name>` — Display name
- `--version <version>` — Version (semver)
- `--fork-of <slug[@version]>` — Mark as fork of existing skill
- `--changelog <text>` — Changelog text
- `--tags <tags>` — Comma-separated tags (default: "latest")

### Post-publish install

After ClawHub publication, install with:

```bash
openclaw plugins install clawhub:ryk-openclaw-plugin
```

**Note:** The `clawhub:` install protocol requires a recent OpenClaw version. If your OpenClaw version does not support it, use the local path or npm install methods instead.

## Verification Commands

After local install (for testing):

```bash
openclaw plugins list --json
openclaw plugins doctor
```

Through ryk CLI:

```bash
ryk plugin doctor openclaw
ryk plugin manifest openclaw
ryk plugin install openclaw --dry-run
```

Hook smoke test:

```bash
cat tests/plugin-fixtures/openclaw/tool_command_safe.json \
  | ./zig-out/bin/ryk hook openclaw tool.before
```

## Known Limitations

- **ClawHub CLI dry-run requires v0.12.3+.** Earlier versions (v0.7.0) did not support `--dry-run`.
- **`clawhub:` install protocol requires recent OpenClaw.** Older OpenClaw versions may not support `clawhub:` installs. Use local path or npm install as fallback.
- **Local path install may show runtime warnings.** OpenClaw local path installs load TypeScript source directly and may show context-shape warnings depending on OpenClaw version. The npm package (with compiled `dist/index.js`) is the recommended distribution format.
- **Hooks are advisory for informational events.** Blocking hooks depend on OpenClaw honoring thrown errors.
- **The strongest protection remains `ryk openclaw`.**
- **No telemetry is collected.**
- **No MCP server behavior is added.**
- **No drone-specific plugin features are added.**

## No Telemetry Statement

The ryk OpenClaw plugin does not collect telemetry. No usage data, session content, or metadata is transmitted to any external service.

## No MCP Behavior Statement

The ryk OpenClaw plugin does not add MCP server behavior or `.mcp.json`.

## No Drone Plugin Behavior Statement

The ryk OpenClaw plugin does not add drone-specific plugin features, drone skills, drone demos, or operational drone-control instructions.

## Security

- No raw secrets in plugin files.
- No raw secrets in documentation.
- No unsafe npm install scripts.
- No binary downloads during install.
- No remote code execution during install.

Report vulnerabilities privately through [SECURITY.md](../../SECURITY.md).

## Support

- Issues: [https://github.com/christopherkarani/rykan/issues](https://github.com/christopherkarani/rykan/issues)
- Docs: [docs/integrations/openclaw.md](openclaw.md)
- Security: [SECURITY.md](../../SECURITY.md)
