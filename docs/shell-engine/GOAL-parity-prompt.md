# /goal — Zig shell_engine 100% Rust parity

Paste the block below into a coding agent as `/goal` (or as the standing
session objective). The agent must keep working until the Done criteria are
met — not stop at MVP.

**Reference oracle (temporary local repo):**
`/Users/chriskarani/CodingProjects/ryk-rs-parity-ref`  
(tag `baseline-eec9446f702d`, frozen from ryk `main` `orca-rs/**`)

**Backlog:** `docs/shell-engine/rust-parity-backlog.md`

---

## Goal prompt (copy from here)

```text
/goal Achieve 100% Zig shell_engine parity with the frozen Rust orca-rs command guard.

## Mission
Port and harden ryk’s in-process Zig `src/shell_engine/` until it has:
1. **100% command-guard parity** with the Rust pack engine in the temporary reference repo, and
2. **100% test parity** with the Rust shell/corpus/regression surface that defines allow/deny behavior.

Do not stop at the current MVP (~6 partial packs, ~47 corpus lines, ≥95% match). The goal is complete only when Done criteria below are all true.

## Workspaces
- **Product (edit here):** `/Users/chriskarani/CodingProjects/orca`
- **Oracle (read-only reference):** `/Users/chriskarani/CodingProjects/ryk-rs-parity-ref`
  - Packs: `src/packs/**`
  - Corpora: `tests/corpus/**`
  - Related regressions/repros under `tests/repro_*.rs`, `tests/security_regressions*.rs`, fixtures
  - Tag: `baseline-eec9446f702d`
- **Backlog (update as you go):** `docs/shell-engine/rust-parity-backlog.md`

Never reintroduce a required Rust daemon into the product path. Zig owns shell Evaluate for hook/run/shim. Keep Zig fail-closed on evaluator errors (do not copy Rust hook fail-open transport behavior).

## Done criteria (ALL required)
### A. Command-guard parity
- All **85** Rust pack IDs from the oracle are implemented in Zig (status `done` in the backlog).
- For every oracle `destructive_pattern!` / `safe_pattern!` intent: Zig returns the same allow/deny decision and the same pack_id + pattern family (exact `pattern_name` preferred; documented aliases only).
- Engine parity for bypass classes covered by oracle corpora:
  - multi-segment (`;`, `&&`, `||`, `|`)
  - wrappers (`sudo`, `env`, `command`, …)
  - quoting / escapes
  - command substitution / backticks
  - heredoc / here-string / `bash -c` / `python -c` embeds
  - obfuscation / unicode / boundary cases in oracle corpus
- Safe-prefix short-circuit must NOT allow destructive compounds (e.g. `git status; rm -rf /` → deny).
- Unmatched commands may allow only after the full pack set is loaded (same as Rust pack miss), not because packs are missing.

### B. Test parity
- Port oracle `tests/corpus/**` (≥355 cases) into Zig-runnable fixtures.
- Zig corpus gate requires **100%** decision match (not ≥95%).
- Port or re-express oracle true-positive / false-positive / bypass / security regression cases that assert allow/deny (or document an explicit exclusion list with rationale — empty by default).
- `zig build test-shell-engine` is wired into `zig build test` and CI (fast + full) so parity cannot be skipped.
- Narrow gates while iterating: `./scripts/zig build test-shell-engine` and `./scripts/agent-gate.sh`; do not claim Done without the full shell corpus green.

### C. Tracking / hygiene
- Backlog pack table statuses updated (`missing` → `partial` → `done`).
- Threat-model / AGENTS / help text describe Zig as shell authority; no stale “required Rust daemon” for Evaluate.
- Do not commit `planning/` notes, secrets, `dist/`, or the temporary oracle repo into ryk.

## Execution loop (persist until Done)
1. Fix P0 engine gaps first (backlog E1–E10), especially safe-before-destructive ordering and compound/wrapper parsing.
2. Complete partial packs: `core.filesystem`, `core.git`, `strict_git`, `system.*`.
3. Port remaining packs by tier P1 → P2 → P3; prefer pack-per-file under `src/shell_engine/packs/`.
4. After each pack or engine slice:
   - add/adjust tests (TDD)
   - run `./scripts/zig build test-shell-engine`
   - update backlog statuses
5. When all packs `done`, raise corpus gate to 100% and run full shell + relevant L1/L2 gates.
6. If blocked, write the blocker into the backlog and continue with the next unblocked pack — do not idle.

## Non-goals
- Rebuilding the Rust daemon, TUI, or ExecuteCli surfaces as a product dependency.
- Bit-identical regex source; structured Zig matching is fine if decisions/IDs match.
- Graduated-response UX / suggestion copy (optional after decision parity).

## Definition of finished
Reply with a short completion report only when A+B+C are satisfied, including:
- pack count done/85
- corpus case count and 100% match proof command
- confirmation `test-shell-engine` is on the full `test` step / CI
- any intentional exclusions (must be empty or explicitly approved)

Until then: keep implementing.
```

---

## Operator notes

1. Start the agent in the **ryk** product repo, not only the oracle.
2. Keep `/Users/chriskarani/CodingProjects/ryk-rs-parity-ref` around until Done; it is the frozen oracle.
3. There may also be a looser copy at `CodingProjects/ryk-rs` (no git) and an untracked leftover `orca/ryk-rs/` with build `target/` — **prefer the parity-ref repo** as canonical.
4. Pair with `/loop` if you want periodic progress checks, e.g. `/loop 30m continue the shell_engine parity goal; report packs done/85 and corpus %`.
