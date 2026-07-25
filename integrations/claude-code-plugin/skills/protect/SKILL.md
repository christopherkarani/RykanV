# protect

Explain how to run the current Claude Code workflow under ryk protection.

## When to use

Use this skill when you want to ensure the current Claude Code session or command runs inside ryk supervision.

## Strongest protection

The strongest local protection is running the Claude Code process itself through ryk:

```bash
ryk run -- <claude-code-command>
```

If the exact Claude Code invocation is unknown, run the Claude Code CLI through ryk using the command you normally use to start Claude Code.

## What the plugin provides

The Claude Code plugin adds:

- Native skills for doctor, init, protect, redteam, and replay.
- Lifecycle hooks that call `ryk hook claude <event>` for safety checks.

## Important limitation

> The Claude Code plugin adds native skills and lifecycle hooks. The strongest protection remains running the agent process through `ryk run`.

Hooks are advisory and additive. They do not replace the supervision that `ryk run` provides over the child process.

## Quick check

Verify ryk is ready:

```bash
ryk plugin doctor claude
```

## Notes

- This skill does not modify host configuration.
- No telemetry is sent.
- Hooks call the ryk CLI; they do not duplicate policy logic.
