# ryk CLI Command Reference

> Aligned with Safe Launch product surface (`src/cli/help.zig`, `src/cli/mod.zig`, command modules).
> Version: 1.2.8 (from `VERSION`)
> Product: **ryk** (formerly Orca) — Graded policy mediation for AI agent actions (Codex, Claude Code, OpenCode, OpenClaw, Hermes, Pi)
> Dual-name: primary binary **`ryk`**; **`orca`** is a PATH alias of the same product for ≥1 major.
> Workspace paths still use `.orca/` in Phase 5a (migration is Phase 5b).

ryk ships **one** product CLI (two PATH names):
- **`ryk`** — primary Desktop/CI policy mediation binary (grades: hook | wrapper | proxy | OS-enforced)
- **`orca`** — compatibility alias of the same binary for one major

**Safe Launch (taught path):**

```text
ryk start
ryk claude | codex | pi | opencode | openclaw | hermes
ryk doctor
ryk replay
ryk stop
# or: ryk start …  (compat alias)
```

Default `ryk help` lists only public verbs. Full surface: `ryk help --all`.

---

## `ryk` — Top-Level Commands

Invocation: `ryk <command> [options]` (or `ryk <command> …`)

### Public (Safe Launch)

| Command | Summary | Source File |
|---------|---------|-------------|
| `start` | Get protected: policy, hosts, Ask on risk, verify | `src/cli/start.zig` |
| `stop` | Stop ryk protection for host agents | `src/cli/disable.zig` |
| `claude` / `codex` / `pi` / `opencode` / `openclaw` / `hermes` | Launch host under ryk (alias → run engine) | `src/cli/host_launch.zig` |
| `doctor` | Diagnose readiness and platform capabilities | `src/cli/doctor.zig` |
| `replay` | Replay last session (denials dominant) | `src/cli/replay.zig` |
| `explain` | Why a shell command is blocked or allowed (Zig shell_engine) | `src/cli/shell_explain.zig` |
| `help` | Show help (`help --all` = full surface) | `src/cli/help.zig` |

### Advanced / integration (via `ryk help --all`)

| Command | Summary | Source File |
|---------|---------|-------------|
| `run` | Run engine / custom agents / CI | `src/cli/run.zig` |
| `init` | Create an Orca policy (power/CI scaffold) | `src/cli/init.zig` |
| `policy` | Validate, explain, and apply policies | `src/cli/policy.zig` |
| `credentials` | Check Secretless credential brokers | `src/cli/credentials.zig` |
| `report` | Export a local safety report (free) | `src/cli/report.zig` |
| `test` | Test a shell command with Zig shell_engine packs | `src/cli/shell_test.zig` |
| `packs` | Browse / enable / disable safety packs (oracle + pack_config) | `src/cli/packs.zig` |
| `allowlist` | Permanent pack-exception allowlist (rule id / exact command) | `src/cli/allowlist_cmd.zig` |
| `allow` / `unallow` | Shortcuts for allowlist add / remove | `src/cli/allowlist_cmd.zig` |
| `allow-once` | Redeem / manage one-time shell exceptions | `src/cli/allow_once.zig` |
| `diff` / `apply` / `discard` | Staged writes | `src/cli/*.zig` |
| `mcp` | MCP proxy and inspection | `src/cli/mcp.zig` |
| `redteam` | Run red-team fixtures | `src/cli/redteam.zig` |
| `completions` | Generate shell completions | `src/cli/completions.zig` |
| `shim` | Internal PATH shim callback | `src/cli/shim.zig` |
| `version` | Print version | `src/cli/version.zig` |
| `plugin` | Plugin management and diagnostics | `src/cli/plugin.zig` |
| `decide` / `hook` / `evaluate` | Integration APIs | `src/cli/*.zig` |
| `dashboard` | Local Orca dashboard | `src/cli/dashboard.zig` |
| `ci` | Local CI readiness checks | `src/cli/ci.zig` |
| `shutdown` | Stop the background ryk daemon (live Zig) | `src/cli/shutdown.zig` |
| `uninstall` | Uninstall ryk from this machine | `src/cli/uninstall.zig` |
| `env` | Print install environment for shell activation | `src/cli/mod.zig` |
| `--print-install-env` | Hidden flag (same as `env`) | `src/cli/mod.zig` |

### Removed as public peers

| Command | Status |
|---------|--------|
| `quickstart` | Hard-removed from dispatcher — use `ryk start` |
| `setup` | Hard-removed from dispatcher — use `ryk start` (library retained internally) |
| `status` | Hard-removed from dispatcher — use `ryk doctor` |
| `license` | Hard-removed — report export is free; no license CLI |

### Not available (hidden; typing yields short notice)

Unavailable former daemon ports are **not** listed by `ryk help` / `ryk help --all` or shell completions. Typing them prints a short “not available” message and exits with usage (2). **`shutdown` remains live** and is listed under Advanced. P0 shell-ops verbs (`packs`, `allowlist`, `allow`, `unallow`, `allow-once`) are live Zig surfaces.

| Command | Status |
|---------|--------|
| `scan`, `precommit`, `simulate`, `classify`, `suggest-allowlist`, `history`, `rebase-recover`, `config` | Hide-list (unavailable daemon ports) |

### Exit Codes (`src/cli/exit_codes.zig`)

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `success` | OK |
| 1 | `general` | General error |
| 2 | `usage` | Usage error |
| 3 | `denial` | Action denied |
| 4 | `unsupported` | Unsupported feature |
| 5 | `child_failure` | Child process failed |
| 6 | `redteam_failure` | Red-team fixture failure |
| 7 | `ask` | Decision asks (non-interactive hosts read JSON) |
| 8 | `warn` | Decision warn/redact outcome |

---

## Command Details

### `ryk start`

Single public onboarding door. Creates policy when missing, wires hosts, defaults to **Ask on risk**, verifies readiness. No public `--protection` grade menu.

**Usage:** `ryk start [--auto|--yes|--no-interact] [--hosts <list>] [--preset <name>] [--skip-verify]`

**Examples:** `ryk start` · `ryk start --auto` · `ryk start --auto --hosts codex,claude`

---

### `ryk doctor`

Diagnose protection readiness: policy, hosts, capabilities, packs, and recommended next steps.

**Usage:** `ryk doctor [-v|--verbose] [--check] [--json]`

---

### `ryk stop`

Disable Orca plugins from host agents (binary and policy remain). Restart with `ryk start`.

**Usage:** `ryk stop [codex|claude|cursor|opencode|openclaw|hermes|all] [--yes]`

---

### `ryk run`

**Advanced / engine.** Run a command under ryk supervision — filters environment through policy, checks the command through Command Guard, writes audit artifacts, and mirrors the child exit code. Day-1 launch uses host aliases (`ryk claude`, …) instead of teaching `ryk run`.

**Usage:** `ryk run [options] -- <command> [args...]`

**Default mode:** `observe` (from `RunOptions.mode = .observe`)

**Flags:**
| Flag | Description |
|------|-------------|
| `--workspace <path>` | Workspace root directory |
| `--mode <mode>` | Policy mode: `observe`, `ask`, `strict`, or `ci` |
| `--ci` | Shorthand for `--mode ci` |
| `--policy <path>` | Path to policy file |
| `--session-name <name>` | Session name for audit trail |
| `--no-secrets` | Strip secrets from child environment |
| `--secretless` | Replace secrets with broker references |
| `--inherit-env` | Inherit current environment (must be allowed by policy) |
| `--no-network` | Disable all network access (`--network off`) |
| `--allow-network <domain>` | Allow specific network destination (repeatable) |
| `--network <mode>` | Network mode: `observe`, `ask`, `allowlist`, `open`, `off` |
| `--network-backend <backend>` | Backend: `decision-only` or `proxy` |
| `--require-backend <capability>` | Require sandbox capability (repeatable) |
| `--help`, `-h` | Show help |

**Default network backend:** `decision-only`
**Default child environment:** Secrets stripped in `strict`/`ci` modes

---

### `ryk init`

**Advanced.** Create an Orca policy file (`.orca/policy.yaml`) in the current directory. Day-1 users should prefer `ryk start`, which creates a policy when missing.

**Usage:** `ryk init [--preset <name>] [--mode <mode>] [--ci] [--force] [--quiet]`

**Default preset:** `generic-agent`

**Flags:**
| Flag | Description |
|------|-------------|
| `--preset <name>` | Policy preset name |
| `--mode <mode>` | Override the preset's mode: `strict`, `ask`, `observe`, `ci`, `trusted` |
| `--ci` | Shorthand for `--mode ci` |
| `--force` | Overwrite existing `.orca/policy.yaml` |
| `--quiet` | Suppress informational output |
| `--help`, `-h` | Show help |

**Available presets** (from `orca_policy.presets.AgentPreset`):
`generic-agent`, `claude-code`, `codex`, `cursor-agent`, `opencode`, `cline-roo`, `mcp-dev`, `github-actions`, `solo-dev`, `strict-local`, `team-ci`, `openclaw-hermes`, `trusted-local`

---

### `ryk setup` / `ryk quickstart` (removed)

Public dispatcher peers are **hard-removed**. Invoking them exits with a usage error pointing at `ryk start`. Internal library entry points may remain for tests/composition.

---

### `ryk doctor`

Show platform capabilities — reports sandbox backend features, network policy engine status, and platform limitations honestly.

**Usage:** `ryk doctor [--help]`

No persistent flags.

---

### `ryk policy`

Validate, explain, and apply policy files.

**Usage:** `ryk policy <subcommand> [...]`

**Subcommands:**
| Subcommand | Usage | Description |
|------------|-------|-------------|
| `check` | `ryk policy check <policy-path>` | Validate a policy file |
| `explain` | `ryk policy explain [--policy <path>] <kind> <target> [--method <METHOD>]` | Explain a policy decision |
| `packs` | `ryk policy packs` | List available policy packs |
| `apply-pack` | `ryk policy apply-pack <name> [--force]` | Apply a policy pack |

**Available packs:** `solo-dev`, `strict-local`, `team-ci`, `openclaw-hermes`

**Explanation kinds:** `file.read`, `file.write`, `env`, `command`, `network`, `mcp`

---

### `ryk credentials`

Check Secretless credential broker configuration.

**Usage:** `ryk credentials check [credential-ref]`

**Supported brokers:** `local-dummy`, `env-file-dev`, `1password-cli`, `macos-keychain`, `infisical-agent-vault`

---

### `ryk report`

Export a local safety report. Free for all users — no license required.

**Usage:** `ryk report --session <id|last> --format <format>`

**Flags:**
| Flag | Description |
|------|-------------|
| `--session <id\|last>` | Session ID or `last` |
| `--format markdown\|json` | Output format |

---

### `ryk replay`

Replay an audit session — renders a timeline and can verify the event hash chain. **Bare `ryk replay`** loads the last session and emphasizes denied actions. Empty sessions print a Safe Launch hint (`ryk start` then `ryk <agent>`).

**Usage:** `ryk replay [--list] [--session <id|last>] [--json] [--only denied] [--verify] [--tui]`

**Flags:**
| Flag | Description |
|------|-------------|
| (none) | Load last session timeline |
| `--list` | List sessions |
| `--session <id\|last>` | Session ID (default: `last`) |
| `--json` | JSON output |
| `--only denied` | Show only denied actions |
| `--verify` | Verify hash chain |
| `--tui` | Interactive alt-screen timeline |

---

### `ryk diff`

Show unified diffs for Orca-mediated staged writes.

**Usage:** `ryk diff [--session <id|last>] [--file <path>]`

---

### `ryk apply`

Apply reviewed staged writes.

**Usage:** `ryk apply [--session <id|last>] [--file <path>]`

---

### `ryk discard`

Discard staged writes without changing workspace files.

**Usage:** `ryk discard [--session <id|last>] [--file <path>]`

---

### `ryk mcp`

MCP proxy and inspection commands.

**Usage:** `ryk mcp <subcommand> [options]`

**Subcommands:**
| Subcommand | Usage | Description |
|------------|-------|-------------|
| `inspect` | `ryk mcp inspect --command <server> [--name <name>] [--policy <path>]` | Inspect an MCP server |
| `proxy` | `ryk mcp proxy --command <server> [options]` | Start an MCP proxy |
| `list` | `ryk mcp list` | List configured MCP servers |
| `trust` | `ryk mcp trust <server> --tool <tool>` | Trust an MCP tool |
| `manifest check` | `ryk mcp manifest check <manifest.yaml>` | Validate a manifest |
| `manifest generate` | `ryk mcp manifest generate --command <cmd> \| --server <name>` | Generate a manifest |

**Proxy options:** `--name <name>`, `--policy <path>`, `--manifest <path>`, `--mode observe|ask|strict|ci`

---

### `ryk redteam`

Run red-team test fixtures against Orca controls and report a scorecard.

**Usage:** `ryk redteam [path] [--json] [--ci] [--fixture <id>]`

**Default fixture path:** `./fixtures`

**Flags:**
| Flag | Description |
|------|-------------|
| `--json` | Machine-readable JSON report |
| `--ci` | Non-interactive; exits non-zero if any required fixture fails |
| `--fixture <id>` | Run a specific fixture by ID |

---

### `ryk completions`

Generate shell completion scripts.

**Usage:** `ryk completions <bash|zsh|fish|powershell>`

Prints a completion script to stdout.

---

### `ryk shim`

Internal callback used by session-local PATH shims.

**Usage:** `ryk shim exec -- <command> [args...]`

Automatically removes the session shim directory from PATH before resolving the real binary.

---

### `ryk version`

Print the current version.

**Usage:** `ryk version [--json] [--help]`

**Flags:**
| Flag | Description |
|------|-------------|
| `--json` | JSON output (version, commit, target, build_date) |
| `--help`, `-h` | Show help |

---

### `ryk plugin`

Plugin management and diagnostics for host agent integrations.

**Usage:** `ryk plugin <subcommand> [options]`

**Subcommands:**
| Subcommand | Usage | Description |
|------------|-------|-------------|
| `doctor` | `ryk plugin doctor [codex\|claude\|opencode\|openclaw\|hermes] [--json]` | Check plugin status |
| `manifest` | `ryk plugin manifest [codex\|claude\|opencode\|openclaw\|hermes\|all] [--json]` | Show plugin manifests |
| `install` | `ryk plugin install [<host>\|all] [--dry-run] [--path <path>] [--yes]` | Install a plugin |
| `mcp-server` | `ryk plugin mcp-server [--help]` | MCP server stub |

**Supported hosts:** `codex`, `claude`, `opencode`, `openclaw`, `hermes`

**Default install behavior:** `--dry-run` is default (no changes without explicit opt-in)

---

### `ryk decide`

Evaluate a policy decision for host plugin integration. Returns JSON result.

**Usage:** `ryk decide <kind> --json <payload>|--stdin [--ci]`

**Decision kinds:** `command`, `file`, `prompt`, `tool`

**Flags:**
| Flag | Description |
|------|-------------|
| `--json <payload>` | Inline JSON payload |
| `--stdin` | Read JSON payload from stdin |
| `--ci` | Non-interactive mode (ask → block) |

---

### `ryk hook`

Host-specific hook adapter — normalizes host-specific events to Orca policy decisions.

**Usage:** `ryk hook <host> <event> [--ci]`

**Supported hosts:** `codex`, `claude`, `opencode`, `openclaw`, `hermes`

**Events per host:**

| Host | Events |
|------|--------|
| **codex** | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` |
| **claude** | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `SessionEnd` |
| **opencode** | `session.created`, `tool.execute.before`, `tool.execute.after`, `permission.asked`, `permission.replied`, `file.edited`, `command.executed`, `session.updated`, `session.idle`, `session.error`, `shell.env` |
| **openclaw** | `session.start`, `tool.before`, `tool.after`, `permission.before`, `permission.after`, `session.end` |
| **hermes** | `on_session_start`, `pre_tool_call`, `post_tool_call`, `pre_llm_call`, `post_llm_call`, `subagent_stop`, `on_session_end` |

Reads JSON payload from stdin, emits host-valid JSON response to stdout.

---

### `ryk dashboard`

Start the local web dashboard.

**Usage:** `ryk dashboard [--host <ip>] [--port <n>]`

**Defaults:** `--host 127.0.0.1 --port 7742`

---

### `ryk ci`

Run local CI readiness checks — validates policy, rejects dangerous defaults, runs a CI-safe redteam fixture.

**Usage:** `ryk ci check [--format markdown|json] [--github-summary <path>]`

**Subcommand:** `check` (required)

**Flags:**
| Flag | Description |
|------|-------------|
| `--format markdown\|json` | Output format (default: text) |
| `--github-summary <path>` | Append to GitHub Actions step summary |

---

### `ryk explain`

Explain why a shell command would be allowed or denied (pretty decision tree). Does not execute the command.

**Usage:** `ryk explain [--format json] [--] <command>`

**Examples:**
- `ryk explain "rm -rf /"`
- `ryk explain --format json "git reset --hard"`

---

### `ryk disable`

Disable Orca plugins from host agents without removing the ryk binary or policy files.

**Usage:** `ryk disable [codex|claude|opencode|openclaw|hermes|all] [--yes]`

**Default:** disables all hosts

**Flags:**
| Flag | Description |
|------|-------------|
| `--yes` | Skip confirmation prompt |

---

### `ryk uninstall`

Completely remove ryk and its integrations from the machine (plugins, binaries, runtime, shell activation, config, and local data).

**Usage:** `ryk uninstall [--plugins-only] [--keep-config] [--dry-run] [--yes]`

**Flags:**
| Flag | Description |
|------|-------------|
| `--plugins-only` | Only remove plugins; keep binary and config |
| `--keep-config` | Keep `~/.config/orca/` and allow-once data; still remove runtime + binary |
| `--dry-run` | Print what would be removed without changing anything |
| `--yes` | Skip confirmation prompt |

Does **not** remove project workspace `.orca/` dirs. Package-manager installs (brew/scoop/winget) must be uninstalled with those tools.

---

### `ryk help`

Show top-level or command-specific help.

**Usage:** `ryk help [command]`

---

### `ryk env`

Print shell activation commands for installing Orca into PATH.

**Usage:** `ryk env`

Prints platform-appropriate `export PATH=...` (Unix) or `set PATH=...` (Windows) lines. Detects the actual binary location via `selfExePath` for correct paths.

**Also available as hidden flag:** `ryk --print-install-env`

---

