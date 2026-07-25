# Orca Agent Instructions

## Working Style

- Verify the real checkout and files before changing anything.
- Use TDD for non-trivial changes.
- Keep edits surgical and tied to the request.
- **Act by default** when the task is clear: local edits, tests, implement/fix loops, and sub-agent spawns do not need human approval. Pause only for ambiguity, architecture forks, or irreversible/shared actions (push, force-push, published PR reviews, deletes the user did not ask for, new dependencies, anything that changes shared remote state).
- **Direct work** for small or mechanical tasks (typos, one-liners, pure formatting, trivial renames).
- **Prefer sub-agents** for non-trivial multi-step work. Also use sub-agents for parallel independent work, blast-radius isolation (worktrees), Zig specialist lanes, or explicit orchestration.
- When multi-step, keep a short internal plan (todos). That is not a request for human go-ahead.
- Sub-agent output is **advisory until the main agent verifies** it against the tree, tests, and product rules.
- Full work + review SOP: [`docs/agents/work-and-review.md`](docs/agents/work-and-review.md).

## Repo Boundaries

- Treat this repository as public-facing by default.
- Keep local planning, handoffs, reviews, and task notes out of tracked docs unless the user explicitly asks to publish them.
- Keep session-local artifacts in `planning/`; only `planning/README.md` is tracked.
- Before staging or committing, run:

```bash
git ls-files | rg '(^planning/|^go_to_market/|^customer_pilot/|^tasks/|^reports/|^\\.orca-edge/|^\\.edge/|^dist/|^dist-dry-run/|^docs/release/|^docs/orca_opencode_openclaw_plan/|node_modules/)'
```

- Never commit generated release archives, SBOMs, checksums, dry-run package output, red-team replay output, customer-pilot templates, SOW/NDA notes, target-account templates, outreach copy, pricing guidance, or task-memory logs.

## Orca Context

- Zig is the primary (and sole) user-facing CLI and shell evaluator.
- Shell command security decisions are owned by the in-process Zig `shell_engine`. `ORCA_SHELL_EVAL=rust` is rejected (legacy Rust daemon Evaluate removed); production path is Zig only.
- Non-shell events (files, network, MCP/tools, effects) stay on the Zig policy path.
- Do not reintroduce a required Rust daemon for hook/run/shim shell gating.
- Shell evaluator internal errors fail closed with `deny`.

## Toolchain

- Use Zig **0.16.0** (`.zigversion`).
- Prefer `./scripts/zig` over bare `zig` / `zig build` / `zig build test`.
- If a Zig command fails and the version is wrong, fix the toolchain first:

```bash
./scripts/ensure-zig-toolchain.sh --install
eval "$(./scripts/ensure-zig-toolchain.sh --export)"   # or: direnv allow
./scripts/zig version   # must print 0.16.0
```

- The former `orca-rs/` Rust daemon crate has been removed from the product tree. Do not add Cargo to `zig build`.

## Verification gates (read this before every verify loop)

**Default: use the narrowest gate that can catch your change.**
“test-fast” means *fast relative to the full suite*, not “seconds.” The Zig lib unit binary alone is often **several minutes** (~1.1k tests via the monopath `src/root.zig` graph).

**One-shot path picker for agents:**

```bash
./scripts/agent-gate.sh                  # auto from git dirty paths
./scripts/agent-gate.sh --dry-run        # print selection only
./scripts/agent-gate.sh units            # force L1
./scripts/agent-gate.sh --paths src/cli/plugin.zig
./scripts/zig build test-shell-engine    # Zig shell evaluator + MVP corpus
```

### Tier ladder

| Tier | When | Command | Typical cost |
|------|------|---------|--------------|
| **L0 compile** | After every Zig edit; “does it compile?” | `./scripts/compile-fast.sh check` | ~seconds–tens of seconds |
| **L0.5 shell** | `src/shell_engine/**` | `./scripts/zig build test-shell-engine` | seconds |
| **L0.5 domain** | Edits confined to one domain | `./scripts/test-slice.sh sandbox\|policy\|intercept` | often **seconds–tens of seconds** |
| **L1 units** | Broad Zig logic needs unit confidence | `./scripts/test-fast.sh units` **or** monopath `test-lib` | **multi-minute** monopath |
| **L2 product** | Policy/CLI handoff, pre-PR light gate | `./scripts/test-fast.sh` (or `full`) | L1 + ~1s quick-install matrix |
| **L3 full Zig** | Pre-merge / full suite (single CI job) | `./scripts/zig build test` | full phase/plugin/fuzz suites |
| **L4 pre-merge** | Explicit pre-merge only | `./scripts/verify-pre-merge.sh` | L2 + L3 + install/uninstall regressions |

### Path → gate matrix

| Touched paths | Prefer |
|---------------|--------|
| `src/shell_engine/**` | **L0.5** `./scripts/zig build test-shell-engine` |
| Single Zig file, compile check only | **L0** `./scripts/compile-fast.sh check` |
| `src/sandbox/**` only | **L0.5** `./scripts/test-slice.sh sandbox` / `agent-gate.sh` |
| `src/policy/**` only | **L0.5** `./scripts/test-slice.sh policy` |
| `src/intercept/**` only | **L0.5** `./scripts/test-slice.sh intercept` |
| `src/**`, `packages/**`, `build.zig` (broad logic) | L0 → **L1** `test-fast.sh units` or `agent-gate.sh` |
| `scripts/**` only | `bash -n` + the script’s own smoke; avoid L3 unless the script is a gate itself |

### Pitfalls (do not)

1. **Do not** default every edit to `verify-pre-merge.sh` or `./scripts/zig build test`. Those are L3/L4.
2. **Do not** treat “test-fast” as a 10-second gate. Budget **minutes** for L1 monopath; prefer domain slices / filters when possible.
3. **Do not** invoke `cargo` from `zig build` (dual-stack rule retained as a build hygiene check).
4. **Do not** pipe long builds to `tail`, and do not background `./scripts/zig build test` unless you poll to completion.
5. **Do not** use `zig build test-lib -- --test-filter …` — that ABRTs under the terminal runner. Use **`-Dtest-filter=…`** or `./scripts/test-slice.sh … --filter …`.
6. **Do not** clear `.zig-cache` as a first response to a failure — fix the error; caches are large and cold rebuilds hurt.
7. **Do not** reintroduce a required Rust daemon for shell PreToolUse / PermissionRequest security decisions.

## Development Rules

- Preserve user-owned dirty changes.
- Verify before calling work complete (with the **narrowest** gate above).
- **Done gate (substantive code):** after implementation, run the tiered end-of-task adversarial review in [`docs/agents/work-and-review.md`](docs/agents/work-and-review.md). Do not call the work complete while blocking findings remain (unless the user waived them). Auto-fix blockers for at most **2** fix→re-review loops, then escalate.
- Use conventional commits.
- Do not add dependencies without documenting them in `docs/dev/dependencies.md`.
- Do not introduce SaaS, telemetry, monetization, or cloud dashboards unless the user asks for them.
- Do not persist raw secrets in logs, fixtures, reports, docs, tests, or snapshots.

## Code Style

- Zig: `zig fmt`, 4-space indent, 120 column limit.
- Follow `.editorconfig` for file-specific spacing.

## Risk Areas

- Shell security authority is the Zig `shell_engine` (85 oracle packs + 100% corpus gate). Keep `./scripts/zig build test-shell-engine` green; PCRE2 is linked via the Zig `pcre2` package (static `pcre2-8`).
- Fail closed on evaluator errors for shell hooks.
- The Zig **lib test monopath** (`src/root.zig` + `cli/mod.zig` test pulls) is the main local iteration bottleneck — compensate with L0-first discipline, not by skipping verification entirely.

## Agent skills

### Work, Zig skills, and end-of-task review

Mandatory control loop for non-trivial code work. Details: [`docs/agents/work-and-review.md`](docs/agents/work-and-review.md).

- **Zig skill packs (when touching Zig):** load before writing or reviewing. At minimum `zig-best-practices` for implement/style; add `zig-memory-safety` for alloc/IO/lifetime; `zig-abstractions` for API design; build-system skill for `build.zig` / `build.zig.zon`. Review lanes load code-review / memory-safety / thermo-nuclear as the tier requires.
- **Instruct every sub-agent** which skill paths to read first. Missing skill → fail/pause; do not improvise “Zig vibes.”
- **End-of-task review (substantive code only):** spawn real review sub-agents (no self-review cosplay). Tier ladder:
  - **T1 (default):** Behavior/Correctness + Style/Idioms
  - **T2 (risk / multi-module / implement-subagent work):** T1 + Safety/Hardening
  - **T3 (large or architectural):** T2 + Thermo-nuclear code quality
- Skip mandatory dual+ review for trivial, read-only, or pure docs unless the user asks.
- Write an untracked note under `planning/reviews/`; do not commit review artifacts unless asked.
- Reuse an in-session multi-agent review if it already covers the required tier; otherwise top up missing lanes.

### Issue tracker

Issues live in GitHub Issues for `christopherkarani/rykan` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`CONTEXT.md` + `docs/adr/` at repo root). See `docs/agents/domain.md`.
