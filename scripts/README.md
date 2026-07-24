# Scripts

## Agent / developer iteration (read first)

Coding agents and humans should use the **narrowest** gate. Full details and path→gate matrix: **`Agents.md` → Verification gates**.

| Goal | Command |
|------|---------|
| Path-aware narrowest gate | `./scripts/agent-gate.sh` (`--dry-run` to preview) |
| Fastest Zig compile signal | `./scripts/compile-fast.sh` or `./scripts/compile-fast.sh check` |
| Domain units (sandbox/policy/intercept) | `./scripts/test-slice.sh sandbox` (etc.) |
| Filtered monopath tests | `./scripts/test-slice.sh lib --filter Spinner` or `-Dtest-filter=` |
| Compile lib / test-fast artifacts (no run) | `./scripts/compile-fast.sh test-lib` / `test-fast` |
| Run lib tests only | `./scripts/compile-fast.sh test-lib-run` or `./scripts/zig build test-lib` |
| Units only (no quick-install) | `./scripts/test-fast.sh units` |
| Default local product gate | `./scripts/test-fast.sh` (or `full`) |
| Compile-only product gate | `./scripts/test-fast.sh compile` |
| Local fast-PR mirror | `./scripts/ci-local-fast.sh` |
| Policy / init DX matrix only | `./scripts/quick-install-dx-verify.sh` (needs built `zig-out/bin/orca`) |
| Full Zig suite | `./scripts/zig build test` |
| Pre-merge kitchen sink | `./scripts/verify-pre-merge.sh` |
| Shell engine + MVP corpus | `./scripts/zig build test-shell-engine` or `./scripts/agent-gate.sh shell-engine` |
| Pinned Zig wrapper | `./scripts/zig …` (always prefer over bare `zig`) |

### Modes and flags

- **`compile-fast.sh`**: compile-only modes use incremental + default `-j`; run modes use `-j1` (serial tests; avoids host hangs).
- **`test-fast.sh`**: `compile` | `units` | `full` (default). Env override: `ORCA_TEST_FAST=units`. Uses incremental + `-j1`.
- **`agent-gate.sh`**: `auto` (default from git dirty paths) or forced `check|compile|units|full|core|sandbox|policy|intercept|shell-engine|dx|dashboard|plugin` (`rust` is a deprecated alias for `shell-engine`).
- **`test-slice.sh`**: domain gates + `--filter` → `-Dtest-filter` (Zig 0.16 compile-time; not runtime `-- --test-filter`).
- **`compile-test-fast`** (build.zig) matches **`test-fast`** membership (not the full suite).

### Pitfalls

- Do **not** use `build-all.sh` for mid-task iteration (full CLI build only when you need the binary).
- Do **not** default mid-task work to `verify-pre-merge.sh` or full `zig build test`.
- Zig L1 monopath is often **multi-minute**. Prefer domain slices / `-Dtest-filter` first.
- Never pass `-- --test-filter` to the terminal test runner (ABRTs). Use `-Dtest-filter=` / `test-slice.sh --filter`.
- Silence under a TTY is not always a hang (Progress UI). High CPU + climbing RSS → sample the test PID; see **Agents.md** “If test-fast hangs”.
- Never wrap full doctor/PATH collectors in `checkAllAllocationFailures`.
- Avoid clearing `.zig-cache` unless necessary.

---

## Release cutter (primary)

- **`cut-release.sh`**: Mac-local orchestrator — version bump, `verify-pre-merge`, multi-arch build (Linux via Docker), GitHub Release + assets, npm publish, Homebrew tap push. Default is dry-run (no publish); pass `--live` after confirm. Docs: `docs/dev/cut-release-shortcut.md`.
- **`build-linux-release-docker.sh`**: Stage `linux-{amd64,arm64}/ryk` for `build-release.sh` via `RYK_CLI_ARTIFACT_DIR` (keep outside `dist/`).

## Phase 19 release helpers

- `install.sh`: macOS/Linux installer with OS/arch detection, checksum verification, PATH/resource profile wiring, and a step-based TTY UI (banner, phases, activation hero). Set `ORCA_INSTALL_QUIET=1` for non-error silence; honors `NO_COLOR`.
- `install.ps1`: Windows installer with the shared core contracts (checksum, binaries, runtime assets, quiet mode, activation handoff). Subset of the Unix surface — no PATH management or dashboard soft-warn.
- `install-orca-plugin.sh`: one-command bootstrap for `orca` + plugin install + plugin doctor (`opencode`, `openclaw`, or `hermes`).
- `install-orca-plugin.ps1`: Windows one-command bootstrap for `orca` + plugin install + plugin doctor (`opencode`, `openclaw`, or `hermes`).
- `update-homebrew-formula.sh`: updates `packaging/homebrew/Formula/orca.rb` from `dist/checksums.txt`.
- `render-package-manifests.sh`: renders publishable Homebrew, npm, Scoop, and WinGet manifests under `dist/package-manifests/` from `dist/checksums.txt`.
- `build-release.sh`: builds cross-platform release archives into `dist/`.
- `build-release.ps1`: PowerShell archive smoke-test helper; pass `-ArchiveOnly`. Production release verification must use `build-release.sh` because the PowerShell helper does not emit `release-manifest.json` or rendered package manifests.
- `generate-checksums.sh`: writes `dist/checksums.txt`.
- `generate-sbom.sh`: writes the Phase 19 `dist/sbom.json` hook output.

Signing is optional and controlled by `ORCA_SIGNING_ENABLED=1` plus `ORCA_SIGNING_COMMAND`.
