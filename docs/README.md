# ryk Documentation

Product package docs:

- `../packages/core/README.md`: ryk Core shared policy, decision, audit, replay, redaction, fixture, schema registry, experimental ABI skeleton, and capability contract.
- `../packages/cli/README.md`: ryk desktop and CI AI-agent mediation contract.

Launch docs:

- `install.md`: source builds, scripts, artifacts, checksums, and package templates.
- `quickstart.md`: first policy, doctor, run, replay, and red-team commands.
- `compatibility.md`: platform matrix, **protection grades** (canonical), and doctor / start vocabulary map.
- `dashboard.md`: localhost dashboard launch, fixed local actions, policy editing, sessions, and denied-action timeline.
- `threat-model.md`: assets, actors, trust boundaries, non-goals, and limitations.
- `shell-engine/rust-parity-backlog.md`: Zig `shell_engine` checklist to regain 100% Rust pack/corpus parity after the daemon cutover.
- `shell-engine/GOAL-parity-prompt.md`: pasteable `/goal` prompt for an agent to drive that parity to completion.
- `policy.md`: schema, modes, priorities, examples, and CI behavior.
- `mcp.md`: stdio MCP inspect/proxy, manifests, mediated methods, and limits.
- `redteam.md`: fixture categories, CI mode, JSON output, and adding fixtures.
- `agent-recipes.md`: generic local recipes and preset notes.
- `ci.md`: GitHub Actions and artifact guidance.
- `replay.md`: audit artifacts, hash-chain verification, and redaction behavior.
- `filesystem-staging.md`, `network.md`, and `commands.md`: enforcement surfaces and limitations.
- `compatibility.md`: consolidated platform matrix.
- `platform-linux.md`, `platform-macos.md`, and `platform-windows.md`: platform-specific capability notes.
- `troubleshooting.md`, `contributing-fixtures.md`, and `release.md`: operations and release references.

Developer docs:

- `presets.md`: supported policy presets and assumptions.
- `release/checklist.md`: Phase 19 release artifact, checksum, signing, SBOM, and install checklist.
- `dev/`: architecture contracts, security invariants, production gates, phase handoffs, and [Zig hardening plan](dev/zig-hardening-plan.md).

ryk reports platform capability limits through `ryk doctor`; docs should not claim transparent sandboxing where the backend reports wrapper-only, observe-only, limited, or unavailable.
