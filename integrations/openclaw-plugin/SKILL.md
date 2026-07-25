# ryk

ryk adds runtime guardrails to OpenClaw workflows via the ryk CLI. Use it when:

- You want policy-based command blocking before tool execution
- You need audit logging for agent sessions
- You want secret redaction in tool payloads

## When to use ryk

| User intent | Use ryk? |
|-------------|-----------|
| "Run `rm -rf /`" | Yes — ryk blocks dangerous commands |
| "Let me run this shell script" | Yes — ryk evaluates against policy |
| "What time is it?" | No — safe query, no policy needed |
| "Execute this curl \| sh pipe" | Yes — ryk blocks known dangerous patterns |

## How it works

ryk registers lifecycle hooks that call the ryk CLI for policy decisions:

- `tool.before` — evaluates tool calls against policy before execution
- `session.start`, `session.end` — informational logging
- `tool.after` — audit logging

If a tool is blocked, ryk throws an error that prevents execution. OpenClaw does not currently expose dedicated permission lifecycle hooks to this plugin; permission-like blocking is handled through `tool.before` before the tool call executes.

## Prerequisites

- ryk CLI must be installed and available on `PATH`
- Run `ryk doctor` to verify installation

## Example policy behavior

Safe command (`git status`):
```json
{
  "decision": "allow",
  "risk": "low",
  "reason": "policy_allow"
}
```

Dangerous command (`rm -rf *`):
```json
{
  "decision": "block",
  "risk": "high",
  "reason": "policy_deny",
  "message": "Blocked by ryk policy"
}
```

## Key behaviors

- **Thin wrapper**: All policy decisions are made by the ryk CLI
- **No duplicated logic**: The plugin does not reimplement policy
- **Secret redaction**: Keys matching `password`, `token`, `secret`, `api_key` are replaced with `[REDACTED]` before sending to ryk
- **Graceful degradation**: If ryk CLI is missing, the plugin warns and skips hooks
- **Honest limits**: Hooks are advisory; the strongest protection is `ryk run -- openclaw`

## Don't use ryk for

- Replacing the ryk CLI (the CLI is the source of truth)
- Telemetry collection (no telemetry is collected)
- MCP server behavior (not included)
- Drone-specific features (not included)
