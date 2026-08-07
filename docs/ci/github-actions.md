# GitHub Actions

This integration is local-only. It does not assume a hosted ryk service, policy sync, telemetry, or model-provider secrets.

Use a CI policy:

```bash
ryk init --preset github-actions
ryk policy check .ryk/policy.yaml
```

Example workflow:

```yaml
name: Agent Task

on:
  workflow_dispatch:

jobs:
  agent:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install ryk
        run: ./scripts/install.sh
      - name: Check ryk policy
        run: ryk policy check .ryk/policy.yaml
      - name: Run agent safely
        run: ryk run --mode ci -- ./scripts/agent-task.sh
      - name: Run red-team fixtures
        run: ryk redteam --ci
      - name: Upload ryk audit logs
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: ryk-audit
          path: .ryk/sessions
```

You can also wrap a command with the repository-local composite action:

```yaml
- uses: ./.github/actions/ryk-run
  with:
    command: ./scripts/agent-task.sh
```

Security notes:

- CI mode never prompts. Ask decisions become denies unless policy explicitly allows the action.
- Do not put tokens or secrets in policy files, workflow examples, or audit artifacts.
- ryk audit logs are redacted before persistence, but avoid running commands that intentionally print secrets.
- Platform sandbox capability depends on the runner OS. Use `ryk doctor` for the actual capability report.
