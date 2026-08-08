# Plugin Security Model

> Version: 1.1.0
> Status: Active

This document defines the trust boundaries, sandbox expectations, and permission model for ryk plugins.

## Principles

1. **ryk is the source of truth.** Plugins call ryk; they do not reimplement policy logic.
2. **Strongest protection is `ryk run`.** Plugin hooks are additive, not a replacement for supervised execution.
3. **Default deny.** If a plugin cannot verify safety, it must fail closed.
4. **No silent mutation.** Host configs, policies, and credentials are never changed without explicit user approval.
5. **Plugin telemetry boundary.** The plugin surface does not collect telemetry or phone home with plugin payloads. Release CLI commands have their separate fixed anonymous telemetry contract; hook, plugin, and machine-readable paths are excluded.

## Trust Boundaries

```
┌─────────────────────────────────────────┐
│  Host IDE (Codex, Claude Code, etc.)    │  ← Untrusted by default
│  Runs arbitrary agent code                │
├─────────────────────────────────────────┤
│  ryk Plugin (future package)          │  ← Semi-trusted; read-only
│  Calls ryk for decisions            │
├─────────────────────────────────────────┤
│  ryk (`ryk plugin *`)           │  ← Trusted local surface
│  Owns policy, audit, replay               │
├─────────────────────────────────────────┤
│  ryk Core (policy engine, audit)      │  ← Trusted
│  Local-only, no network dependency        │
└─────────────────────────────────────────┘
```

## Permission Levels

| Level | What It Can Do | Example |
|-------|----------------|---------|
| **Read-only** | Query status, read policy, check manifests | `ryk plugin doctor`, `ryk plugin manifest` |
| **Preview** | Simulate changes without writing | `ryk plugin install --dry-run` |
| **Mutate** | Modify host config or policy | Requires `--yes` + explicit user confirmation |
| **Actuate** | Trigger real-world effects | **Not exposed by default** |

## Plugin Default Behavior

- `ryk plugin install` defaults to `--dry-run`.
- `ryk plugin doctor` does not print secrets or raw env values.
- `ryk plugin mcp-server` is a documented stub; no real server starts.
- Drone-related operations are default-deny.

## Credential Handling

- Plugins must not print credentials, API keys, or connection strings.
- Plugins must not store credentials in plugin-specific config files.
- Plugins must not forward credentials to remote services.

## Host Config Mutations

- ryk plugin commands must not silently overwrite Codex, Claude Code, or other host configs.
- Any config change must be previewed with `--dry-run` first.
- Any actual change requires `--yes`.

## Sandboxing Expectations

The plugin surface does not claim to sandbox the host IDE. It provides:
- Policy queries
- Audit log summaries
- Capability reporting
- Safe installation previews

Actual sandboxing is provided by:
- `ryk run -- <command>` for child process supervision
- Host IDE's own extension sandbox (if any)
- OS-level protections

## Rejection Criteria

A plugin request is rejected if it would:
- Expose live drone actuation tools by default
- Auto-approve high-risk operations
- Weaken existing safety tests or policies
- Exfiltrate audit logs without redaction
- Mutate policy without explicit approval

## See Also

- `docs/integrations/ryk-plugin.md`
- `docs/integrations/drone-safety.md`
