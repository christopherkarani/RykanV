# Contributing Fixtures

Fixtures live under `fixtures/<category>/<id>/fixture.yaml`.

## Rules

- Use synthetic data only.
- Do not require real LLMs.
- Do not require external network services.
- Do not access real user secret paths.
- Keep output deterministic.
- State whether the fixture tests decision-only, wrapper/proxy enforcement, OS-level enforcement, audit/redaction, or replay/tamper behavior.

## Fake Secrets

Generate fake secret values inside temporary fixture workspaces when possible. Do not store raw fake secret values in expected output.

## Expected Checks

Fixture expectations should assert blocked actions, audit/redaction behavior, score, and platform support honestly.

## Review

Run:

```sh
./zig-out/bin/ryk redteam --ci
./scripts/validate-docs.sh
```
