# Red-team Fixtures

Fixtures under this directory are deterministic local evidence for `ryk redteam`.
They must use fake local inputs and synthetic data only.

Required structure:

```text
fixtures/<category>/<fixture-id>/
  fixture.yaml
  README.md
  input/      # optional files copied into an isolated temp workspace
  expected/   # optional notes or golden files
```

`fixture.yaml` supports:

- `version: 1`
- `id`, `name`, `category`, `description`
- `mode: strict|ci|redteam`
- `command.argv` for the deterministic fake-agent command label
- `attempts`, using `file.read:`, `command.exec:`, `network.connect:`, `mcp.tool:`, `mcp.metadata:`, or `filesystem.symlink-read:`
- `expected.blocked`, `expected.redacted`, and `expected.no_log_contains`
- `score.points`

Rules:

- Do not add real credentials, real LLM calls, or external services.
- Do not reference real user secret paths in setup.
- Use fake/synthetic values only.
- Keep fixture inputs bounded and local.
- If a capability is observe-only or unsupported, the runner must report skipped/unsupported rather than claiming a pass.
