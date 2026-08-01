# Threat Model

## Assets Protected

- Local environment variables passed to agent processes.
- Secret-like values before persistent logging.
- Protected paths such as `.env`, SSH keys, cloud credentials, and browser credential stores.
- Orca-mediated writes before they reach the workspace.
- MCP tool calls, resource reads, prompt gets, and sampling requests that pass through the stdio proxy.
- Host and MCP tool calls classified into effect classes (e.g. `comms.message`) when policy includes an `effects:` section — by tool name catalog, structural argument shapes, network host tags, and Zig-side shell bypass patterns (e.g. `open mailto:`). Host shell PreToolUse / Evaluate is owned by the in-process Zig `shell_engine` (85 oracle packs; default enablement matches Rust `core.*` + `system.disk`; full set available). Corpus decision parity is gated by `zig build test-shell-engine` (100% match). Residual gap: effect-class classification via Zig `shell_bypass` is separate from pack allow/deny — see [shell-engine Rust parity backlog](shell-engine/rust-parity-backlog.md).
- **Phase 1 hard fence (default shell Evaluate):** Mode A packs only (`core.*` + `system.disk`) with structure smart checks (compound segments, wrappers, assignment/quote data masking, shell/interpreter embeds). Catastrophe classes (`rm -rf` root/home, `git reset --hard` / force-push, `mkfs` / `dd` of devices) deny with stable `rule_id`. Non-executed text (`VAR='rm -rf /'`, `echo 'rm -rf /'`) is not treated as execution. YOLO/Strict policy UX and Foundation Models steward are out of scope for this fence.
- Audit integrity for Orca-managed sessions.

## Threat Actors

- Prompt-injected coding agents.
- Malicious repository content that instructs an agent to read or expose secrets.
- Untrusted MCP servers or tool metadata.
- Local automation scripts launched through Orca.

## Trust Boundaries

- The user and local OS are trusted to launch Orca intentionally.
- Child processes are untrusted.
- Policy files are trusted only after validation.
- MCP protocol messages and manifests are untrusted inputs.
- Audit artifacts are verified as untrusted local files during replay.

## Assumptions

- The protected process is launched through Orca.
- The user does not approve unsafe actions deliberately.
- Orca can write audit artifacts in the workspace.
- Platform backend claims are checked with `orca doctor`.

## Non-goals

Orca does not promise perfect sandboxing, protection outside Orca-launched sessions, defense against root/admin/kernel compromise, or universal transparent filesystem/network interception.

## Platform Limitations

Wrapper and proxy controls are not the same as OS-level enforcement. macOS and Windows currently report transparent file and network enforcement as limited. Linux capability depends on kernel and host settings.

Protection is **graded** (`hook` | `wrapper` | `proxy` | `OS-enforced`). Canonical definitions and the map from doctor / platform reports (and the public `orca start` **Ask on risk** default) live in [compatibility.md](compatibility.md#protection-grades-canonical).

## Fail-closed Behavior

Strict and CI modes deny invalid policies, missing required backend features, unsupported ask prompts in CI, and malformed untrusted inputs where enforcement is required.

## Known Unsupported Cases

- Agents launched outside Orca.
- Real network blocking when traffic bypasses Orca and no active OS/backend enforcement exists.
- Transparent blocking of arbitrary filesystem calls on platforms where `doctor` reports limited or unavailable support.
- Privileged users who intentionally bypass wrappers, shims, or audit paths.

## Host-config launch identity (F-02)

Host-config RW trees (e.g. `~/.codex`), empty-backpack defaults for agent aliases, and agent network mediation require a **trusted resolved launch binary** (realpath under an install allowlist + host-config table basename). A workspace file named `codex` / `claude` does **not** receive host login grants. Residuals: user-writable `~/.local/bin` over-trust; installs outside the allowlist get no host-config.

## Host-config hardlink smuggle (F-03)

On macOS session-attach, Seatbelt denies `file-link` then re-allows under the workspace with control-root `require-not` (same class as write carve-outs), so a child cannot hard-link host-config grant files into the workspace or plant hardlinks under `.git`/`.orca`. Residuals: `cp` while auth is readable; same-tree host hardlinks denied; no Landlock `file-link` twin on Linux; secretless still exposes raw login files for trusted hosts until S1C/gateway (F-04).
