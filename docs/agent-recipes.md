# Agent Recipes

These are starting points. Agent-specific presets are generic unless their policy file says otherwise.

## Safe Launch (day-1)

```sh
./zig-out/bin/ryk start
./zig-out/bin/ryk claude   # or: codex | pi | opencode | openclaw | hermes
./zig-out/bin/ryk status
```

`ryk start` creates policy when missing (Ask on risk / `generic-agent`), wires host integrations, and verifies readiness. Host aliases are the taught launch path; bare `ryk run -- …` is advanced.

## Day-1 coding agents (Claude / Pi / Codex)

Host aliases default to empty backpack. Prefer the host’s login store; configured Anthropic/OpenAI env-key grants are replaced with session phantoms and resolved only by the loopback provider gateway.

```sh
./zig-out/bin/ryk start
./zig-out/bin/ryk claude   # or: pi | codex | …
./zig-out/bin/ryk status
```

Notes:

- Prefer the agent host’s built-in login/session credentials when available; those do not depend on raw `*_API_KEY` env vars surviving the child filter.
- Raw model keys never enter an empty-backpack child; an allowed grant produces only a session-minted phantom.
- Plugin/hooks alone are not the secret boundary. Use a host alias or explicit `ryk run --secretless -- <agent-command>`.

## Advanced: generic / custom agents

Power users and automation can still scaffold and launch via `init` + `run`:

```sh
./zig-out/bin/ryk init --preset generic-agent
./zig-out/bin/ryk run -- <agent-command>
```

## MCP Development

```sh
./zig-out/bin/ryk run --policy policies/presets/mcp-dev.yaml -- <agent-command>
./zig-out/bin/ryk mcp inspect --name demo --command python3 -- fixtures/mcp/fake_server.py
```

## Strict Local Mode

```sh
./zig-out/bin/ryk run --policy policies/presets/strict-local.yaml --mode strict -- <agent-command>
```

## Trusted Local Mode

Use only for code and commands you already trust:

```sh
./zig-out/bin/ryk run --policy policies/presets/trusted-local.yaml --mode trusted -- <agent-command>
```

## No-network Mode

```sh
./zig-out/bin/ryk run --no-network -- <agent-command>
```

This updates ryk network policy decisions and environment metadata. It is not transparent network blocking unless `ryk doctor` reports an active backend.

## Secret Boundary Runtime (empty backpack)

Agent-primary aliases such as `ryk claude` and `ryk codex` default to **empty backpack**: public host env plus exact session phantoms for granted Anthropic/OpenAI keys, OS sandbox required, and workspace `.env` secret forms denied at the OS layer. A loopback gateway swaps only exact mints for fixed provider hosts. Generic commands opt in explicitly:

```sh
./zig-out/bin/ryk claude
./zig-out/bin/ryk run --secretless -- <command>
```

This constructs the boundary environment and requires OS FS isolation. The CONNECT policy proxy and provider gateway are separate; route-forced proxy plus gateway currently fails closed.

Prefer host login when the agent supports it. The explicit escape is loud:

```sh
./zig-out/bin/ryk run --with-host-secrets -- <command>
```

## CI Mode

```sh
./zig-out/bin/ryk run --mode ci -- zig build test
./zig-out/bin/ryk redteam --ci
```

## Staged Write Review

```sh
./zig-out/bin/ryk diff --session last
./zig-out/bin/ryk apply --session last
./zig-out/bin/ryk discard --session last
```

## Preset Notes

Presets exist for `claude-code`, `codex`, `cursor-agent`, `opencode`, `cline-roo`, `mcp-dev`, `github-actions`, `strict-local`, and `trusted-local`. They are local policy templates, not integrations with vendor services.
