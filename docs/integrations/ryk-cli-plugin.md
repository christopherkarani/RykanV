# ryk CLI plugin surface

The `ryk plugin` namespace gives host integrations one local interface for status, manifests, installation previews, and policy decisions. The CLI remains the source of truth.

## Inspect a host integration

```sh
ryk plugin doctor
ryk plugin doctor codex --json
ryk plugin manifest codex --json
```

`doctor` reports local readiness without printing raw environment values or secrets. `manifest` reports the expected path and whether the checked-in manifest exists.

Supported host names include `codex`, `claude`, `opencode`, `openclaw`, and `hermes`. The exact host capabilities still come from the host itself, so a detected package does not mean that enforcement is active.

## Preview or install a plugin

```sh
ryk plugin install codex --dry-run
ryk plugin install claude --dry-run
ryk plugin install all --dry-run
```

Installation defaults to a dry run. A real host mutation requires `--yes` and must not silently overwrite user configuration.

## Ask for a decision

```sh
ryk decide command --json '{"version":1,"host":"codex","command":"git status"}'
ryk decide file --json '{"version":1,"host":"codex","path":"/etc/passwd","operation":"write"}'
ryk decide prompt --json '{"version":1,"host":"claude","prompt":"hello"}'
ryk decide tool --json '{"version":1,"host":"codex","tool":"shell","command":"ls"}'
```

Use `--stdin` when the host already has a JSON payload. Add `--ci` when an `ask` result must become a non-interactive block.

## Process host hook input

```sh
echo '{"version":1,"host":"codex","event":"PreToolUse","payload":{"tool":"shell","command":"git status"}}' \
  | ryk hook codex PreToolUse
```

Hook stdout is machine-readable. Human diagnostics belong on stderr.

## Packaging

`scripts/package-plugins.sh` and `scripts/package-plugins.ps1` create local plugin archives under `dist/plugins/`. Archives contain the host manifest, skills or hooks, and README files. They do not contain credentials, MCP server configuration, or build caches.

## Limits

Plugins can evaluate only events the host sends them. They do not sandbox the host process. For process-level supervision, use:

```sh
ryk run -- <agent-command>
```

See [the security model](plugin-security-model.md), [compatibility](plugin-compatibility.md), and [troubleshooting](plugin-troubleshooting.md).
