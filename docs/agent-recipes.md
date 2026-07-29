# Agent Recipes

These are starting points. Agent-specific presets are generic unless their policy file says otherwise.

## Safe Launch (day-1)

```sh
./zig-out/bin/orca start
./zig-out/bin/orca claude   # or: codex | pi | opencode | openclaw | hermes
./zig-out/bin/orca status
```

`orca start` creates policy when missing (Ask on risk / `generic-agent`), wires host integrations, and verifies readiness. Host aliases are the taught launch path; bare `orca run -- …` is advanced.

## Day-1 coding agents (Claude / Pi / Codex)

**Usable model credentials today:** omit `--secretless`. Launch under process wrap so env filtering, command policy, and audit apply, while env-based API keys (or the host’s own login store) can still authenticate.

```sh
./zig-out/bin/orca start
./zig-out/bin/orca claude   # or: pi | codex | …
./zig-out/bin/orca status
```

Notes:

- Prefer the agent host’s built-in login/session credentials when available; those do not depend on raw `*_API_KEY` env vars surviving the child filter.
- In `strict` / `ci` / `redteam`, secret-like env is stripped unless policy allows it — model keys in env will not be present even without `--secretless`.
- Plugin/hooks alone are not secretless and are not process wrap; strongest local protection remains a host alias or `orca run -- <agent-command>`.

## Advanced: generic / custom agents

Power users and automation can still scaffold and launch via `init` + `run`:

```sh
./zig-out/bin/orca init --preset generic-agent
./zig-out/bin/orca run -- <agent-command>
```

## MCP Development

```sh
./zig-out/bin/orca run --policy policies/presets/mcp-dev.yaml -- <agent-command>
./zig-out/bin/orca mcp inspect --name demo --command python3 -- fixtures/mcp/fake_server.py
```

## Strict Local Mode

```sh
./zig-out/bin/orca run --policy policies/presets/strict-local.yaml --mode strict -- <agent-command>
```

## Trusted Local Mode

Use only for code and commands you already trust:

```sh
./zig-out/bin/orca run --policy policies/presets/trusted-local.yaml --mode trusted -- <agent-command>
```

## No-network Mode

```sh
./zig-out/bin/orca run --no-network -- <agent-command>
```

This updates Orca network policy decisions and environment metadata. It is not transparent network blocking unless `orca doctor` reports an active backend.

## Secretless Runtime (empty backpack, opt-in only)

**Not ready — do not default** for day-1 agent launches that need model API keys from the environment. `--secretless` is **empty backpack**: public host env only (no raw secrets, no `orca-secret://` rewrite), OS sandbox required, and workspace `.env` secret forms denied at the OS layer when attach succeeds. Claude, Pi, Codex, and similar hosts that expect env API keys will fail auth — see [credentials.md](credentials.md) § Secretless Mode.

```sh
./zig-out/bin/ryk credentials check
./zig-out/bin/ryk run --secretless --network-backend proxy -- <command>
```

This constructs a public-only child environment and requires OS FS isolation. Orca records policy, redaction, and proxy request decision evidence, but it is not a vault and does **not** inject usable credentials into the child environment or into HTTPS to model providers. Proxy mode is explicit and loopback-only; HTTPS policy is host/port-only unless a cooperative hook supplies method/path metadata.

Use secretless for deliberate leak-resistance / secret-boundary demos, not as the default agent launch path until a product path supplies usable credentials.

## CI Mode

```sh
./zig-out/bin/orca run --mode ci -- zig build test
./zig-out/bin/orca redteam --ci
```

## Staged Write Review

```sh
./zig-out/bin/orca diff --session last
./zig-out/bin/orca apply --session last
./zig-out/bin/orca discard --session last
```

## Preset Notes

Presets exist for `claude-code`, `codex`, `cursor-agent`, `opencode`, `cline-roo`, `mcp-dev`, `github-actions`, `strict-local`, and `trusted-local`. They are local policy templates, not integrations with vendor services.
