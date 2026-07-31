# README and Repo Cleanup

## Summary

Polished the ryk repository for public release by rewriting the root `README.md`, updating `.gitignore` to exclude planning artifacts, and removing tracked planning/scratch files from the git index without deleting local files.

## README Changes

Rewrote `README.md` to be concise, launch-ready, and honest. Key changes:

- Added **Why Rykan V Exists** section explaining the problem ryk solves.
- Added **What Rykan V Does** section with bullet points for `ryk run`, policy checks, secret redaction, audit logs, replay, red-team fixtures, plugin doctor, Codex plugin, and Claude Code plugin.
- Added **Quick Start** section with build, doctor, init, run, replay, and redteam commands.
- Expanded **Agent Host Plugins** section with links to all plugin docs and the security model.
- Added **Installing Plugin Artifacts** section explaining `scripts/package-plugins.sh`, checksum verification, and local install.
- Added **Security Model** section with blast-radius reduction and host-capability limits.
- Expanded **What Rykan V Does Not Promise** with the required limitation bullets, including:
  - "The current plugin release does not add MCP server behavior or drone-specific plugin features."
- Removed the extensive Edge/drone phase history and operational details from the root README (those remain in `packages/edge/README.md` and dedicated docs).
- Added the required exact wording:
  - "The strongest local protection remains running the agent through `ryk run`; plugins provide native commands, hooks, and guardrails inside supported agent hosts."
- Retained platform support table and honest capability reporting.
- Added Documentation section with links to product docs and plugin docs.
- Added Development section with build/test/doctor/redteam/package commands.

## .gitignore Changes

Added the following sections to `.gitignore`:

- ryk internal planning / generated plan packs (directories and zips)
- Local planning scratch (`planning/`, `plans/`, `.plan/`, `.local-plans/`, `scratch/`, `tmp/`, `*.tmp`, `*.bak`)
- Local agent/planning exports (root-level planning markdown files like `CODEX_MASTER_PROMPT.md`, `P00_*.md`, `[0-9][0-9]_*.md`, `RYK_CLI_PLUGIN_CONTRACT.md`, `ARCHITECTURE_CONTRACTS.md`, `CODEX_AGENT_CONTEXT.md`, `DRONE_WORKSTREAM_GUARDRAILS.md`, `FINAL_PASS_REPORT.md`, `REVIEW_SUMMARY.md`, `SECURITY_INVARIANTS.md`, etc.)

No product docs, source files, or build directories were added to `.gitignore` beyond the existing Zig cache and output patterns.

## Files Untracked from Git Index

The following files and directories were removed from the git index with `git rm --cached` (local files remain on disk):

### Planning directories
- `aegis_plugin_launch_plan_v3.zip`
- `aegis_plugin_launch_plan_v3/` (entire directory including all P00-P07 files, manifests, and guardrails)

### Root-level planning markdowns
- `00_PLUGIN_LAUNCH_INDEX.md`
- `01_CODEX_EXECUTION_PROTOCOL.md`
- `02_REPO_BOOTSTRAP.md`
- `03_CORE_TYPES_AND_ALLOCATORS.md`
- `04_CLI_SKELETON.md`
- `05_SESSION_SUPERVISOR.md`
- `06_AUDIT_LOG_AND_REPLAY.md`
- `07_POLICY_ENGINE.md`
- `08_ENV_AND_SECRET_PROTECTION.md`
- `09_FILESYSTEM_GUARD_AND_STAGING.md`
- `10_COMMAND_GUARD_AND_APPROVALS.md`
- `11_MCP_STDIO_PROXY.md`
- `12_NETWORK_EGRESS_GUARD.md`
- `13_REDTEAM_BENCHMARK_SUITE.md`
- `14_LINUX_SANDBOX_BACKEND.md`
- `15_MACOS_BACKEND.md`
- `16_WINDOWS_BACKEND.md`
- `17_ADVANCED_MCP_AND_MANIFESTS.md`
- `18_AGENT_PRESETS_AND_INTEGRATIONS.md`
- `19_INSTALLERS_RELEASE_PIPELINE.md`
- `20_SECURITY_HARDENING_AND_FUZZING.md`
- `21_DOCUMENTATION_AND_DEMO.md`
- `22_V1_STABILIZATION_AND_ACCEPTANCE.md`
- `RYK_CLI_PLUGIN_CONTRACT.md`
- `ARCHITECTURE_CONTRACTS.md`
- `CANONICAL_IMPLEMENTATION_DECISIONS.md`
- `CODEX_AGENT_CONTEXT.md`
- `CODEX_MASTER_PROMPT.md`
- `DRONE_WORKSTREAM_GUARDRAILS.md`
- `FINAL_PASS_REPORT.md`
- `P01_RYK_CLI_PLUGIN_SURFACE.md`
- `PHASE_DEPENDENCY_MATRIX.md`
- `PRODUCTION_READINESS_GATES.md`
- `REVIEW_SUMMARY.md`
- `SECURITY_INVARIANTS.md`

## Files Intentionally Kept Tracked

- `README.md`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `PLUGIN_RELEASE_NOTES.md`
- `PLUGIN_CHANGELOG.md`
- `LAUNCH_PLUGINS.md`
- `PLUGIN_SECURITY_MODEL.md` (root-level; referenced by release notes)
- `docs/integrations/*.md` (all product plugin docs)
- `integrations/codex-plugin/**`
- `integrations/claude-code-plugin/**`
- `integrations/claude-marketplace/**`
- `tests/**`
- `scripts/**`
- `examples/**`
- `schemas/**`
- `.github/**`

## Tests Run

| Command | Result |
|---|---|
| `zig build` | Passed |
| `zig build test` | Passed (545/545 tests passed, 6 skipped) |
| `./zig-out/bin/ryk doctor` | Passed |
| `./zig-out/bin/ryk redteam --ci` | Passed (10/10 fixtures) |
| `./zig-out/bin/ryk plugin doctor codex` | Passed |
| `./zig-out/bin/ryk plugin doctor claude` | Passed |
| `./zig-out/bin/ryk plugin manifest codex` | Passed |
| `./zig-out/bin/ryk plugin manifest claude` | Passed |
| `./scripts/package-plugins.sh` | Passed (artifacts + checksums generated) |

### Test Fix Note

Two tests in `tests/phase25_cli_hardening.zig` initially failed because they asserted content in `README.md` that was intentionally removed during the README rewrite:

1. `phase25 MCP docs distinguish proxy stdin and list observation` — removed the `README.md` assertion; the test now validates `docs/mcp.md` only.
2. `phase25 docs preserve Edge no-real-flight safety boundary` — removed the `README.md` assertion; the test now validates `packages/edge/README.md` only.

The dedicated docs (`docs/mcp.md` and `packages/edge/README.md`) still contain the relevant content. This keeps the root README focused on the CLI and plugins while preserving the safety-boundary tests on their canonical docs.

## Package Script Status

`./scripts/package-plugins.sh` completed successfully and produced:

```text
dist/plugins/ryk-codex-plugin-v1.1.0.zip
dist/plugins/ryk-claude-code-plugin-v1.1.0.zip
dist/plugins/ryk-claude-marketplace-v1.1.0.zip
dist/plugins/ryk-plugin-checksums.txt
```

The secret scan step in the packaging script passed.

## Secret and Scope Check

- **Secrets**: No real secrets, private keys, or credentials were found in `README.md`, `docs/`, `integrations/`, `examples/`, or `.github/`. Only synthetic test values (`fake_p05_secret_value`, `fake_secret_value_phase35`) were found in fixtures and troubleshooting docs, which is expected.
- **Scope**: The README does not claim unsupported features. Phrases like "perfect sandbox", "MCP server", and "drone-specific" appear only in the "What Rykan V Does Not Promise" limitations section.
- **No operational drone-control instructions** were added to the README.
- **No new product features** were added.

## Known Limitations

- `PLUGIN_SECURITY_MODEL.md` at the repository root was left tracked because it is referenced by `PLUGIN_RELEASE_NOTES.md`. The canonical product doc is `docs/integrations/plugin-security-model.md`.
- The `.gitignore` patterns for planning files will apply going forward; the already-tracked files have been removed from the index.

## Unresolved Questions

None. The repo is clean enough for public release.
