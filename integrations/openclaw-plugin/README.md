# ryk OpenClaw Plugin

OpenClaw plugin wrapper for ryk runtime guardrails.

## Protection first (read this)

| Path | Grade | Blocks tools? |
|------|-------|---------------|
| `ryk run -- openclaw` | **`wrapper`** (supported) | Yes — process launched under ryk |
| npm / ClawHub / CLI-metadata plugin install | **`unprotected`** | **No** — OpenClaw wires `api.on` to a no-op; hooks never fire |
| Local / bundled plugin path | **unverified `hook`** | Only if the host actually registers and honors hooks (not proven by install alone) |

**Never treat “plugin installed” as protection.** For mediation you can rely on today, use:

```bash
ryk run -- openclaw
```

Grades: see the main README [protection grades](../../README.md#protection-grades) and `docs/compatibility.md`.

## What this plugin does

This plugin adds ryk-native lifecycle hooks to OpenClaw when the host exposes real `api.on` registration. It calls the ryk CLI for policy checks, audit logging, and runtime safety decisions without duplicating policy logic.

The ryk CLI remains the source of truth for all policy decisions. When hooks do not fire (npm/ClawHub), this package cannot enforce anything.

## Prerequisites

- ryk CLI built and available in PATH (run `ryk doctor` to verify)
- OpenClaw host installed

ryk is not bundled into this plugin package. Fast setup (install plumbing, not enforcement proof):

```bash
ryk plugin install openclaw --yes
```

Windows:

```powershell
ryk plugin install openclaw --yes
```

## Supported protection path

```bash
ryk run -- openclaw
```

This is the primary recommended path (grade **`wrapper`**). It does not depend on OpenClaw plugin hooks firing.

## Install from local path (optional plumbing)

If you have OpenClaw installed locally:

```bash
openclaw plugins install ./integrations/openclaw-plugin
```

Or:

```bash
ryk plugin install openclaw
```

Local install is still **not** a claim of live **`hook`** enforcement. Prefer `ryk run -- openclaw`. Confirm with `ryk plugin doctor openclaw` (installed ≠ protected).

## Install from npm / ClawHub — unprotected

These paths install metadata and may look successful, but in current OpenClaw **CLI-metadata** mode `api.on` is a no-op. Lifecycle hooks **do not fire**. Classification: **`unprotected`**.

```bash
# NOT recommended for security — unprotected (hooks no-op)
openclaw plugins install npm:ryk-openclaw-plugin
openclaw plugins install clawhub:ryk-openclaw-plugin
```

`--dangerously-force-unsafe-install` only bypasses OpenClaw’s security scanner so the package can load; it does **not** enable hook enforcement. Do not use it as a security install step.

For submission details (packaging only), see `docs/integrations/openclaw-clawhub.md`.

## Verify install (honest doctor)

```bash
ryk plugin doctor openclaw
```

Doctor reports host binary, extension paths, and whether a host plugin appears installed. **Installed does not mean protected.** Expect an enforcement note that npm/ClawHub is **`unprotected`** and that the preferred path is `ryk run -- openclaw`.

## Hooks included

When hooks actually register (not npm CLI-metadata), the plugin calls `ryk hook openclaw <event>`:

| Event | When it fires | Behavior |
|-------|---------------|----------|
| `session.start` | At the start of an OpenClaw session | Informational (readiness log) |
| `tool.before` | Before OpenClaw invokes a tool | **Blocking when hooks fire** — empty/malformed/`ask` fail closed to block |
| `tool.after` | After OpenClaw finishes using a tool | Informational (audit only) |
| `session.end` | When the session ends | Informational (audit only) |

OpenClaw does not currently expose dedicated permission lifecycle hooks to this plugin. Permission-like blocking is handled through `tool.before` **only if** `before_tool_call` runs.

**Do not claim `tool.before` is blocking for npm/ClawHub installs** — those installs are **`unprotected`**.

## How hooks call ryk

Each hook sends a JSON payload to `ryk hook openclaw <event>` via stdin and reads a JSON decision from stdout. On the blocking path (`tool.before`):

- empty or whitespace-only stdout → **block**
- JSON parse failure or missing `decision` → **block**
- `decision: "ask"` or unrecognized → **block** (no OpenClaw ask UX / approve-and-resume yet — documented host limitation; do not fake context notes as approval)
- `decision: "block"` → block
- `decision: "allow"` / `"warn"` → allow (warn logs only)

Human-readable logs go to stderr.

Example payload for `tool.before`:

```json
{
  "version": 1,
  "host": "openclaw",
  "event": "tool.before",
  "payload": {
    "tool": "shell",
    "command": "git status"
  },
  "session_id": "session-uuid",
  "timestamp": "2026-01-01T00:00:00Z"
}
```

Example response:

```json
{
  "version": 1,
  "decision": "allow",
  "risk": "low",
  "category": "command",
  "reason": "policy_allow",
  "message": "Allowed by policy"
}
```

If the decision is `block` (including fail-closed cases), the plugin returns a block result that prevents the tool from executing **when the host honors the hook**.

## Run redteam

```bash
ryk redteam --ci
```

## Replay sessions

```bash
ryk replay --session last --verify
```

## Uninstall

Remove the plugin from your OpenClaw configuration:

```bash
openclaw plugins uninstall ryk
```

This plugin does not mutate host configuration, so uninstalling is safe.

## Known limitations

- **npm/ClawHub/global installs are `unprotected`.** OpenClaw loads them with `registrationMode: "cli-metadata"`, where `api.on` is a no-op. Hooks never fire; the plugin cannot block tools. Supported protection: `ryk run -- openclaw` (**`wrapper`**).
- Local/bundled install does not by itself prove **`hook`** grade without live-host E2E.
- Hooks are advisory for informational events; blocking depends on OpenClaw honoring hook return values.
- Plugin installation depends on OpenClaw version and plugin loading mechanism.
- The plugin does not collect telemetry itself. Hook, plugin, and machine-readable calls are excluded from release CLI telemetry; a user-invoked `ryk run -- openclaw` wrapper may record only the fixed anonymous CLI metadata described in [`../../docs/telemetry.md`](../../docs/telemetry.md).
- npm package name prepared: `ryk-openclaw-plugin`. ClawHub package published for distribution — distribution ≠ enforcement.

## Security model

- This plugin calls the ryk CLI; it does not reimplement policy logic.
- No raw secrets are persisted in plugin files.
- Secrets are redacted from payloads before sending to ryk (keys matching `password`, `token`, `secret`, `api_key`, etc. are replaced with `[REDACTED]`).
- Blocking hooks fail closed on empty/malformed/`ask` responses.
- Human logs go to stderr.
- CI mode never prompts.
- This plugin does not claim stronger enforcement than OpenClaw hooks actually provide.
- Non-enforcing installs are labeled **`unprotected`**, not soft-warned “green” installs.

## No MCP server behavior

The OpenClaw plugin does not add MCP server behavior.

## OpenClaw Security Scan Notice

OpenClaw’s plugin security scanner may block packages that use `child_process`. The ryk plugin needs that only to call the local `ryk` binary.

Bypassing the scanner (for example with `--dangerously-force-unsafe-install`) is **not** a security recommendation and does **not** turn an npm install into an enforcing install. Prefer `ryk run -- openclaw`.
