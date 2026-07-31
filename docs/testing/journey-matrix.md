# Journey matrix

**owner:** christopherkarani  
**sweep:** Zig security test depth (2026-07)  
**plan:** `planning/100-percent-test-coverage-agent-plan.md` §3.2 / §6.4  

Only rows with `sweep: zig` count for this sweep’s progress claims.  
Rows with `sweep: out_of_sweep` must not be implemented as coverage work this sweep.  

Status: `todo` | `ci-green` (set `ci-green` only when the named job runs the filter/script and it passes).  
`last_run_url` is optional until a specific CI run is cited for a claim.

## Zig-owned journeys (`sweep: zig`)

| Journey | test_filter / script | Owning CI job | status | last_run_url | notes |
|---------|----------------------|---------------|--------|--------------|-------|
| Hook shell fail-closed when daemon cannot start | `phase2f shell hooks fail closed when daemon cannot start` | `test.yml` / `ci.yml` zig test | ci-green | | Integration; multi-host matrix in phase2f |
| Hook shell fail-closed on protocol mismatch | `phase2f shell hooks fail closed on protocol mismatch` | zig-test | ci-green | | |
| Hook malformed JSON fail-closed | `phase2f malformed hook JSON fails closed with block decision` | zig-test | ci-green | | |
| Hook missing/empty shell command fail-closed | `phase2f shell tool with missing command fails closed before daemon evaluation` (+ empty variant) | zig-test | ci-green | | |
| Hook unit: daemon unavailable | `hook daemon unavailable blocks shell command` | zig-test (lib) | ci-green | | See checklist for more unit rows |
| Run denies shell when daemon unavailable | `phase2f run denies shell commands when daemon is unavailable` | zig-test | ci-green | | CLI path |
| OS sandbox adversarial (linux) | `scripts/os-sandbox-adversarial-e2e.sh --case ci-linux` | `ci.yml` os-sandbox (ubuntu-latest matrix) | todo | | Job exists in CI with `--require-attach`; not yet proven on tip (`last_run_url` unset) |
| OS sandbox adversarial (macos) | `scripts/os-sandbox-adversarial-e2e.sh --case ci-macos` | `ci.yml` os-sandbox (macos-14 matrix) | todo | | Job exists in CI with `--require-attach`; not yet proven on tip (`last_run_url` unset) |
| MCP proxy fail-closed (unit set) | `proxy fails closed` / malformed transport filters in `src/mcp/proxy.zig` | zig-test | ci-green | | Expand residual via checklist |
| Policy presets validate | `ryk policy check` loop over `policies/presets` | `test.yml` | ci-green | | Already in test.yml |
| Per-host daemon-down wire residual (opencode/openclaw/hermes/claude shell) | checklist todos under `hook-residual-fail-closed` | zig-test | todo | | Z1 residual slice |

## Out of sweep (`sweep: out_of_sweep`)

Do **not** schedule these for Zig coverage-agent progress this sweep.

| Journey | test_filter / script | Owning CI job | status | notes |
|---------|----------------------|---------------|--------|-------|
| Plugin install matrix | `tests/phase3*` / plugin packages | various | — | Plugins % parked |
| Install/uninstall first-user | `scripts/install-first-user-regression-test.sh` | journey (if present) | — | Not Zig security checklist DoD |
| Redteam CI | `ryk redteam --ci` | `test.yml` / release | — | Keep green product-wide; not a coverage-agent work unit unless labeled |
| Rust protocol Decision Matrix | `docs/testing/protocol-decision-matrix.toml` | rust-test / future | — | Appendix R |
| Rust pack family matrix | `docs/testing/pack-family-matrix.toml` | future | — | Appendix R |
| Rust llvm-cov / rust-coverage job | `orca-rs/scripts/coverage.sh` | — | — | **deferred** this sweep |

## Rules

1. Stub rows with `status: todo` do not support “security-surface ready” claims.  
2. Module-done for hook/mcp/sandbox requires owned `sweep: zig` journey cells for that surface `ci-green` when the slice touches them (plus checklist rows).  
3. Never set `ci-green` from a planning checkbox alone.  
4. Owner handle must stay a real GitHub user (not TBD).  
