# ryk-protect

Explain how to run the current Codex workflow under ryk protection.

## When to use

Use this skill when you want to ensure the current Codex session or command runs inside ryk supervision.

## Strongest protection

The strongest local protection is running the Codex process itself through ryk:

```bash
ryk run -- <codex-command>
```

If the exact Codex invocation is unknown, run the Codex CLI through ryk using the command you normally use to start Codex.

## What the plugin provides

The Codex plugin adds:

- Native skills for doctor, init, protect, redteam, and replay.
- Lifecycle hooks that call `ryk hook codex <event>` for safety checks.

## Important limitation

> The Codex plugin adds native skills and lifecycle hooks. The strongest protection remains running the agent process through `ryk run`.

Hooks are advisory and additive. They do not replace the supervision that `ryk run` provides over the child process.

## Quick check

Verify ryk is ready:

```bash
ryk plugin doctor codex
```

## Notes

- This skill does not modify host configuration.
- The plugin does not collect telemetry. A user-invoked `ryk run` wrapper may record only fixed anonymous CLI metadata; see [`docs/telemetry.md`](../../../../docs/telemetry.md).
- Hooks call the ryk CLI; they do not duplicate policy logic.
