# redteam

Run ryk red-team fixtures and summarize results.

## When to use

Use this skill to run deterministic, local-only red-team tests that verify ryk policy behavior without requiring external network access or a real LLM.

## Commands

Run the red-team suite in CI mode:

```bash
ryk redteam --ci
```

For JSON output:

```bash
ryk redteam --json --ci
```

## What it does

The red-team suite runs synthetic fixtures against ryk policy to check:

- Command guard behavior (dangerous commands should be blocked)
- File access controls (protected paths should be denied)
- Secret redaction (synthetic secrets should be detected)
- Network policy decisions (suspicious destinations should be flagged)

## Requirements

- No external network access is required.
- No real LLM is required.
- A valid `.ryk/policy.yaml` is recommended but not strictly required; the suite can fall back to built-in presets.

## Interpreting results

- `PASS` — ryk handled the fixture as expected.
- `FAIL` — The fixture behavior differed from expectation. Review the policy or file an issue.
- `SKIP` — The fixture was skipped due to platform limitations or missing optional dependencies.

## Notes

- This skill does not modify host configuration.
- No telemetry is sent.
- Fixtures use synthetic data only; no real secrets are involved.
