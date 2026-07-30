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

`--secretless` is **empty backpack**: public host env plus exact session phantoms for granted Anthropic/OpenAI keys, OS sandbox required, and workspace `.env` secret forms denied at the OS layer. A loopback gateway swaps only exact mints for fixed provider hosts. The flag remains explicit until the default-on checklist is complete.

```sh
./zig-out/bin/ryk run --secretless -- <command>
```

This constructs the boundary environment and requires OS FS isolation. The CONNECT policy proxy and provider gateway are separate; route-forced proxy plus gateway currently fails closed.

Prefer host login when the agent supports it. The explicit escape is loud:

```sh
./zig-out/bin/ryk run --with-host-secrets -- <command>
```

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
