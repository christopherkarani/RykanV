# CI

ryk has no hosted policy or enforcement service requirement. The `ryk ci` and machine-output paths do not emit telemetry; see [`telemetry.md`](telemetry.md) for the separate release-build CLI telemetry contract.

## GitHub Actions Example

```yaml
name: ryk
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        run: |
          echo "Install Zig 0.16.0 using your pinned toolchain action or cache"
      - name: Build
        run: zig build
      - name: Test
        run: zig build test
      - name: ryk CI check
        run: ./zig-out/bin/ryk ci check --format markdown
      # Fixture engine self-test (builtin:redteam); not workspace policy assurance.
      - name: ryk red-team
        run: ./zig-out/bin/ryk redteam --ci --json > ryk-redteam.json
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: ryk-audit
          path: |
            .ryk/**
            ryk-redteam.json
```

See `docs/ci/github-actions.md` and `examples/ci/github-actions.yml`.

## Non-interactive Mode

Use `--mode ci` for commands and `--ci` for red-team. In CI, ask becomes deny.

## ryk CI Check

`ryk ci check` is the focused local gate for repository readiness:

```sh
ryk ci check --format markdown
ryk ci check --format json
ryk ci check --github-summary "$GITHUB_STEP_SUMMARY"
```

It checks that `.ryk/policy.yaml` exists and validates, rejects dangerous obvious defaults such as open command/network policy or direct writes, and invokes a focused red-team fixture in CI mode. It does not contact a hosted service.

Installed/package builds can run the same check outside the repository root. ryk looks for red-team fixtures in the workspace first, then under `RYK_RESOURCE_ROOT` when package managers install resources beside the binary.

## Audit Artifacts

Upload `.ryk/sessions/**`, `events.jsonl`, `summary.json`, and `summary.md` only if they contain synthetic or approved data. Redaction is applied before persistence, but audit artifacts can still reveal file names and command shapes.
