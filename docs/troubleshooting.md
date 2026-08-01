# Troubleshooting

## Build Issues

Confirm Zig **0.16.0** (this repo pins that version):

```sh
./scripts/zig version   # must show 0.16.0
./scripts/zig build
```

If `./scripts/zig version` is not `0.16.0`, the failure is usually a **toolchain mismatch**, not a source bug.

```sh
./scripts/ensure-zig-toolchain.sh --install
eval "$(./scripts/ensure-zig-toolchain.sh --export)"   # or: direnv allow
./scripts/zig version
./scripts/zig build
```

Day-to-day verification after policy/CLI changes:

```sh
./scripts/compile-fast.sh       # fastest compile check (iteration)
./scripts/test-fast.sh          # full local gate (build + units + quick-install)
./scripts/test-fast.sh units    # units only (no quick-install)
./scripts/zig build test        # full suite before merge/CI
```

Coding agents must follow `AGENTS.md` → **Zig toolchain** and **Fast iteration**.

## Command Not Found

Build first or put the release binary on `PATH`:

```sh
./zig-out/bin/orca version --json
```

## Policy Validation Errors

```sh
./zig-out/bin/orca policy check .orca/policy.yaml
```

Unknown keys, missing `version: 1`, invalid modes, and malformed rule lists fail validation.

## Denied Commands

Use:

```sh
./zig-out/bin/orca policy explain command <command> [args...]
./zig-out/bin/orca replay --session last --only denied
```

## Missing Backend Features

Run `orca doctor`. If a feature is `limited`, `wrapper-only`, `observe-only`, or `unavailable`, docs and policies must treat it as weaker than active enforcement.

## Tool not found vs EPERM under OS sandbox

Under attached sessions (`ryk pi`, `ryk claude`, `ryk run --os-sandbox on`, …):

| Symptom | Likely cause | What to do |
|---|---|---|
| `command not found` for `rg` / `fd` / `jq` | Tool not on host, or PATH honesty dropped an ungranted package dir | Install the tool, or use a system path; pack only grants files that exist. Set `ORCA_TOOL_PACK=essentials` (default under attach). |
| `command not found` but tool lives under Homebrew | PATH denylist removed `/opt/homebrew/bin` so the agent does not see a lie | Either install into a kept prefix, rely on essentials pack file grant (pack re-adds the parent of a granted file), or accept absence |
| EPERM on absolute `/opt/homebrew/bin/...` | Absolute path bypasses shims; OS did not grant that file | Expected — no broad brew tree grants. Use essentials pack or do not invoke absolute brew paths |
| EPERM on `~/.ssh` / bare `$HOME` | Empty-backpack FS fence | Expected; do not request bare home grants |
| Shim name works but absolute path differs | Shims are **wrapper-only** | Absolute paths skip PATH shims; OS still enforces FS/network |

Inspect child labels when debugging: `ORCA_PATH_FILTER=denylist`, `ORCA_TOOL_PACK=essentials|none`.

## MCP Protocol Issues

Ensure server stdout is only newline-delimited JSON-RPC. Send human logs to stderr.

## Redaction Questions

Orca redacts before persistence. If you find a raw secret in `events.jsonl`, `summary.json`, `summary.md`, replay output, or red-team output, treat it as a security issue.

## Red-team Failures

Run a focused fixture:

```sh
./zig-out/bin/orca redteam fixtures --fixture prompt-injection/readme-env-read --ci
```

Unsupported means the host lacks the required backend; it is not proof that the feature works.
