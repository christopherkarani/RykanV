> **⚠️ Historical Baseline:** This document captures the state at Phase 35 (2026-05-09). The CLI surface has since evolved significantly (`ryk hook`, `ryk plugin`, `ryk decide` now exist; the C ABI skeleton was never used). See the current command map in `src/cli/mod.zig` and `docs/commands.md`. For merge architecture, see `../plans/MERGE_RYK_RS_INTO_RYK_CLI_v2.md`.

---

# ryk Integration Baseline — P00

> Generated: 2026-05-09  
> Branch: `phase-35-edge-network-telemetry-data-guard`  
> Commit: `5b271b9` (Phase 35 committed)  
> Zig version: 0.15.2  
> Version: 1.1.0

---

## 1. Repo Summary

ryk is a local, policy-driven runtime firewall for AI agents, written in Zig.
It is **not** a SaaS product, hosted dashboard, monetization layer, or telemetry service.

The repo is organized as a monorepo with two products:

| Product | Path | Binary | Role |
|---------|------|--------|------|
| ryk Core | `packages/core/` | (library) | Shared policy, audit, replay, redaction, schema, decision engine |
| ryk | `packages/cli/` + `src/cli/` | `ryk` | Desktop / CI AI-agent runtime firewall |

---

## 2. Current CLI Map (`ryk` binary)

### Top-Level Commands

| Command | Namespace | File | Status | Notes |
|---------|-----------|------|--------|-------|
| `run` | — | `src/cli/run.zig` | Complete | Direct-child supervision, env filtering, command guard, audit |
| `init` | — | `src/cli/init.zig` | Complete | Creates `.ryk/policy.yaml` from presets |
| `doctor` | — | `src/cli/doctor.zig` | Complete | Platform capability report |
| `policy` | `check` | `src/cli/policy.zig` | Complete | Validate policy file |
| `policy` | `explain` | `src/cli/policy.zig` | Complete | Explain decision for action/target |
| `replay` | — | `src/cli/replay.zig` | Complete | Replay audit session, verify hash chain |
| `diff` | — | `src/cli/diff.zig` | Complete | Show staged writes |
| `apply` | — | `src/cli/apply.zig` | Complete | Apply staged writes |
| `discard` | — | `src/cli/discard.zig` | Complete | Discard staged writes |
| `mcp` | `inspect` | `src/cli/mcp.zig` | Complete | Inspect MCP server |
| `mcp` | `proxy` | `src/cli/mcp.zig` | Complete | Stdio MCP proxy |
| `mcp` | `list` | `src/cli/mcp.zig` | Complete | List known MCP servers |
| `mcp` | `trust` | `src/cli/mcp.zig` | Guidance-only | Prints snippet; does **not** mutate policy |
| `mcp` | `manifest check` | `src/cli/mcp.zig` | Complete | Validate manifest YAML |
| `mcp` | `manifest generate` | `src/cli/mcp.zig` | Partial | `--server` preset unsupported; `--command` works |
| `redteam` | — | `src/cli/redteam.zig` | Complete | Deterministic local red-team fixtures |
| `completions` | — | `src/cli/completions.zig` | Complete | Shell completion scripts |
| `shim` | — | `src/cli/shim.zig` | Internal | PATH shim callback; not user-facing |
| `version` | — | `src/cli/version.zig` | Complete | Plain + `--json` output |
| `help` | — | `src/cli/help.zig` | Complete | Top-level and per-command help |

### Commands NOT Present

| Missing Command | Implication |
|-----------------|-------------|
| `ryk plugin` | No plugin namespace exists |
| `ryk decide` | No decide command exists |
| `ryk hook` | No hook command exists |
| `ryk mcp` (server mode) | No persistent MCP server mode for plugin tools |

### Incomplete / Stubbed Areas

- `ryk mcp --server <preset>` → explicitly unsupported (error: "Phase 11; use --command")
- `ryk mcp trust` → guidance-only; does not write policy
- `src/cli/args.zig` → placeholder/skeleton; not wired into dispatch

---

## 3. Current Module Map

### Core Modules (`src/`)

| Module | Path | Description |
|--------|------|-------------|
| Policy engine | `src/policy/` | load, validate, evaluate, explain, schema, presets |
| Audit / replay | `src/audit/` | writer, replay, hash_chain, redact_bridge, summary |
| Guards | `src/intercept/` | commands, files, network, env, approvals |
| MCP | `src/mcp/` | jsonrpc, proxy, manifests, tools, resources, prompts, sampling, transport, stdio |
| Sandbox / platform | `src/sandbox/` | backend, linux, macos, windows, observe-only stub |
| Core types | `src/core/` | api, types, decision, event, session, platform, supervisor, util |
| Redteam | `src/redteam/` | fixtures, runner, reports, scorecard |
| Release | `src/release/` | Release metadata helpers |

### Package Facades

| Package | Path | Re-exports |
|---------|------|------------|
| `orca_core` | `packages/core/src/root.zig` | api, actions, schemas, abi (experimental), redteam |
| `orca_cli` | `packages/cli/src/root.zig` | CLI surface + intercept/MCP/sandbox wrappers |

---

## 4. Current Tests

### Test Organization

| Layer | Location | Description |
|-------|----------|-------------|
| Inline tests | `src/**/*.zig` | Behavioral tests embedded in source |
| Package contracts | `packages/*/tests/contract.zig` | Core, CLI package API contracts |
| Phase integration | `tests/phase{23..35}_*.zig` | Feature-phase integration tests |
| Fuzz regression | `tests/fuzz/security_mutation.zig` | Deterministic mutation tests |

### Test Files

- `tests/phase23_contract.zig` — Core contract tests
- `tests/phase25_cli_hardening.zig` — CLI hardening

### Test Results (P00 Run)

| Suite | Result |
|-------|--------|
| `zig build` | Pass (no errors) |
| `zig build test` | Pass |
| `ryk --help` | Pass |
| `ryk version` | Pass (`1.1.0`) |
| `ryk version --json` | Pass |
| `ryk doctor` | Pass |
| `ryk redteam --ci` | **10/10 passed, 100%** |

---

## 5. Current Plugin Readiness

### What Exists

| Item | Status | Location |
|------|--------|----------|
| Integration planning doc | Exists | `18_AGENT_PRESETS_AND_INTEGRATIONS.md` |
| Plugin launch plan artifact | Exists | `aegis_plugin_launch_plan_v2.zip` |
| MCP stdio proxy | Active | `src/mcp/proxy.zig` |
| MCP manifest parsing | Active | `src/mcp/manifests.zig` |
| Policy presets (agent-specific) | Active | `src/policy/presets.zig` |
| Schema registry | Active | `packages/core/src/schemas.zig` |
| Experimental C ABI | Skeleton | `packages/core/src/abi.zig` |

### What Is Missing (Prerequisites for P01)

| Item | Why Needed | Risk if Missing |
|------|------------|-----------------|
| `ryk plugin` command namespace | Entry point for plugin management | No user-facing plugin surface |
| Plugin manifest schema | Validate plugin metadata before load | Cannot safely load third-party plugins |
| Hook schema / registry | Define plugin hook points | No structured extension mechanism |
| `integrations/` directory | Home for plugin code, manifests, docs | Ad-hoc plugin layout |
| Codex plugin directory | Codex-specific plugin implementation | No Codex integration |
| Claude Code plugin directory | Claude Code-specific plugin implementation | No Claude Code integration |
| MCP server mode for ryk tools | Expose ryk capabilities as MCP tools | Plugins cannot use ryk as MCP backend |
| Plugin tests | Validate plugin loading, isolation, teardown | Silent breakage on plugin changes |
| Plugin security model doc | Define trust boundaries, sandbox expectations | Unsafe plugin defaults |
| ryk plugin contract doc | Define what the CLI promises to plugins | Plugin compatibility drift |

---

## 6. Missing Prerequisites for P01

1. **Plugin infrastructure directory** — Create `integrations/` or `plugins/` with clear subdirectories per target (codex, claude-code, generic-mcp).
2. **Plugin manifest schema** — JSON/YAML schema for plugin metadata (name, version, hooks, permissions, sandbox requirements).
3. **`ryk plugin` CLI namespace** — Minimum viable: `list`, `install`, `uninstall`, `doctor`.
4. **Hook registry** — Define hook points in the CLI lifecycle where plugins can register callbacks.
5. **Security model documentation** — Before any plugin loads code, document the trust model, permission levels, and isolation expectations.
6. **MCP server mode** — Allow ryk to expose its own capabilities (policy check, audit query, redteam) as MCP tools.
7. **Plugin test harness** — A way to load a plugin in a test and verify it does not crash or corrupt state.

---

## 7. Recommended Next Steps

1. **Create `docs/integrations/` directory** (done as part of P00).
2. **Write `RYK_CLI_PLUGIN_CONTRACT.md`** — Define the CLI-to-plugin contract.
3. **Write `PLUGIN_SECURITY_MODEL.md`** — Define trust boundaries, sandbox levels, permission model.
4. **Create `integrations/` directory** with subdirs: `codex/`, `claude-code/`, `generic-mcp/`, `schemas/`.
5. **Design plugin manifest schema** — Start with a minimal JSON schema.
6. **Stub `ryk plugin` command** — Add namespace + help text; defer implementation.
7. **Stub hook registry** — Define hook types without wiring them.
8. **Add plugin baseline smoke tests** — Verify `ryk plugin --help` etc.

---

## 8. Blockers

| Blocker | Severity | Mitigation |
|---------|----------|------------|
| No plugin directory or schema | Medium | Create in P01; not blocking P00 |
| No `ryk plugin` command | Medium | Stub in P01; not blocking P00 |
| Experimental C ABI | Low | Not required for plugin work; use Zig modules |
| `src/` vs `packages/` split incomplete | Low | Continue using `src/` for CLI; packages are facades |

---

## 9. Known Limitations

- Most implementation lives in `src/`; `packages/` are primarily facades/re-exports.
- `src/sandbox/observe.zig` is a stub (`implemented = false`).
- `src/mcp/transport.zig` defers HTTP MCP transport.
- `tests/README.md` is outdated relative to the phase test layout.
- `aegis_plugin_launch_plan_v2.zip` is present but its contents are not unpacked/integrated.
- No plugin loading, sandboxing, or lifecycle management exists yet.

---

*End of P00 baseline. No plugin implementation has started.*
