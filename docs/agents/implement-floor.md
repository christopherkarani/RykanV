# Implement floor (canonical)

**Priority: correctness and complete, working features over cost, speed, or agent-minute thrift.**  
Thin review, lite mode, soft PASS stubs, and incomplete-slice “green units” are process bugs — not optimizations.

Hard rules that live in [`AGENTS.md`](../../AGENTS.md) still win on stack conflict. This file **aligns** concurrent implement workflows so they enforce one floor.

## 1. Which path to use

| Work shape | Canonical path | Floor |
|------------|----------------|-------|
| Trivial / mechanical | Main agent direct | L0/L0.5 gate; no multi-lane review unless risk |
| Single-slice substantive | Main agent or one implement sub-agent + **end-of-task** review | [`work-and-review.md`](work-and-review.md) T1–T3 on full task diff |
| Multi-unit / orchestrated | **`orchestrate-implement`** (skill) **or** **`implementor`** workflow (`.grok/workflows/implementor.rhai`) | **PlanHarden Phase 0** (`PLAN_READY` + `scripts/plan-harden-gate.sh`) before Units; on-disk handoffs + dual (or min-4) code VERDICTs + dual/tri integration + end-of-task on integrated result; **draft stacked PRs** via native `gh stack` (one layer per unit) only after unit live smoke PASS — not suite-green alone |
| Plan-only harden | **`plan-harden`** workflow (`.grok/workflows/plan-harden.rhai`) | Same architect + dual-decompose + adversarial plan lanes + host gate; no implement |
| Hand-written planning prompts | Must cite this floor + hard VERDICT language | Same evidence as orchestrated path; no monologue “done” |

Do **not** invent a third soft path. Prefer the more complete gate when two conflict.

## 2. Correctness-first principles

1. **Features must be complete and working** for in-scope acceptance — not stubs, not “wired later,” not residual-by-default for product paths.
2. **Quality is what is forced on disk** (`test -s` + `VERDICT: PASS|FAIL`) — not chat paraphrase or SKILL prose. Prefer **host-native** parse via [`scripts/implementor-disk-gate.sh`](../../scripts/implementor-disk-gate.sh) over agent-only `ok` booleans.
3. **Never drop review lanes to save budget.** If budget is insufficient: escalate / pause / re-launch with higher `agent_budget`. Do not silently thin to one lane or invent PASS.
4. **Never choose lite/standard because it is cheaper.** Lite only when the user **explicitly** asks **and** the task is ≤2 small/non-security units. Security / multi-module / multi-unit defaults to **full** (or standard with full dual + integration, never lite).
5. **Sub-agent output is advisory** until the main agent (or orchestrator disk gate) re-checks tree, tests, and product rules.
6. **Narrowest verify gate for iteration**; still re-verify composition and integrated acceptance before complete.
7. **Incomplete wiring is a FAIL**, not a residual, when the unit’s acceptance or the overall task requires product loaders / monopath import / CLI↔store path contracts.
8. **Live product verify is mandatory for feature work** (see §3a). Unit gates green while the user-facing command still fails ⇒ incomplete, not done.

## 3. Hard complete gates (multi-unit)

Complete is **forbidden** unless **all** apply (conjunctive — no partial green):

- [ ] **PLAN_READY** on disk for the run (`PLAN_READY.md` with `VERDICT: PASS`) after PlanHarden Phase 0 — see **§3b**. Units must not start without it (except explicit `skip_plan_harden` only when an already-hardened plan passes `scripts/plan-harden-gate.sh`)
- [ ] Every in-scope unit has a **complete** handoff on disk (required section headers **and** non-empty body evidence — not headers alone)
- [ ] Every unit has **on-disk** review VERDICT PASS for the path’s required lanes (see §4)
- [ ] **Missing VERDICT file ⇒ FAIL** (not PASS, not “skip this lane”). Zero of N code-lane files is a hard fail for that unit
- [ ] Path-scoped commits only; dirty policy honored
- [ ] Narrow verify green vs baseline after merge
- [ ] **All** integration review lanes VERDICT PASS on disk (behavior + safety; security when security surface). **Never complete with split integration** (some lanes PASS, any lane FAIL/missing)
- [ ] Residuals cleared **or** explicitly accepted with honesty (no silent operator-visible gaps; no silent minor carry-forward for §6 classes)
- [ ] End-of-task tiered review on the **integrated** diff (T1–T3 per work-and-review) — orchestrated dual does not erase this. Coverage map: required Style/Safety/Thermo angles present or reused with evidence — never zero VERDICT files
- [ ] **Host-native disk gate** green on the full required path set:
  `./scripts/implementor-disk-gate.sh PATH…` (or `--paths-file`) — exit 0 only when every path is non-empty and has exactly one `VERDICT: PASS` (optional `**` bold wrappers accepted; missing/multi/FAIL ⇒ exit 1)
- [ ] **Product-surface composition** acceptance exercised (see §5): nested-cwd writer↔loader (or monopath/loader) test evidence when CLI/store/loaders are in scope
- [ ] **Live product verify PASS** on disk (`product-oracle.md` / live-smoke evidence) — see §3a
- [ ] Local **`metrics.md`** written under the run dir (`./scripts/implementor-metrics.sh RUN_DIR --write`) — residual-class rollup, not SaaS telemetry
- [ ] No rubber-stamp: agent schema `ok=true` without host-native gate green is **invalid**

**Thrash-as-done is blocked:** repeated identical blocking fingerprints ⇒ unit `blocked` / escalate — not complete.

### 3b. PlanHarden before Units (mandatory for multi-unit)

Planning quality is **forced on disk** before any implementer spawns — not a single decomposer writing `plan.md` “for audit” while the pipeline continues.

**Canonical path:** `implementor` workflow Phase **PlanHarden** (inline). Standalone: `.grok/workflows/plan-harden.rhai` → same host gate.

| Step | Agents / authority | On-disk |
|------|--------------------|---------|
| Architect panel | systems, security, composition (parallel) | `reviews/plan-harden/architect-*.md` + `VERDICT` |
| Dual decompose + gates | primary decomposer, adversarial decomposer, gate-author | `decompose-*.md`, `gate-author.md`, then `plan.json` / `plan.md` / `ownership.md` / `forks.md` |
| Adversarial plan lanes | structure, ownership, verifiability (+ grounding/FP/FN/feasibility/invariants unless lite) | `reviews/plan-harden/plan-*.md` + `VERDICT` |
| Auto-revise | reviser until thrash or pass | rewrites plan artifacts; never invents PASS |
| **Host gate** | `./scripts/plan-harden-gate.sh RUN_DIR --mode MODE` | sole authority — exit 0 required |
| Stamp | — | `PLAN_READY.md` with `VERDICT: PASS` |

**Hard rules:**

1. **Missing VERDICT file ⇒ FAIL** (same as unit code lanes).
2. **Auto-revise until PASS or thrash** (identical blocker fingerprint ≥ `thrash_threshold`) — no mid-run human pause (UI pause bugs). On thrash: fail closed; do not start Units.
3. **Structural checks in the host script:** non-empty plan artifacts; no remaining `fat:true`; no exclusive path overlaps among `parallel_safe` units; product-ish units need live_smoke / command-bearing acceptance; `forks.md` must not contain OPEN forks.
4. **`skip_plan_harden=true`** is only for an already-hardened plan that still passes the host script — never a budget shortcut.
5. Resume with existing `PLAN_READY` + valid `plan.json` may skip re-hardening **if** host gate still passes.

Recommended launch budget: PlanHarden alone ~40–80 agent slots; full implementor **1024**.

### 3a. Live product verify (features — mandatory)

After unit+integration gates, the implementor **must run the real product entrypoint** the feature claims to improve (agent acts as operator — not “manual human pause”, not unit-filter-only).

| Task shape | Required live evidence (transcript in `product-oracle.md`) |
|------------|--------------------------------------------------------------|
| CLI / host launch (`ryk pi`, `opencode`, `run`, …) | Build binary; run that command (timeout OK); assert startup/success criteria from acceptance. Known crash stacks / shield-fail / non-zero without accepted residual ⇒ **FAIL** |
| Other CLI surface | Build; run the command path with smoke args; expected exit + strings |
| Library-only (no user CLI) | Run the **focused test binary** that encodes acceptance (still real execution) |
| Docs / process-only | Explicit N/A in oracle with reason; no product binary claim |

**Hard rules:**

- Unit tests, greps, and “call site exists” checks are **not enough** when the task is a user-facing feature.
- On FAIL: **fix on main tree → re-run live verify** (implementor: capped oracle fix loop). Do not complete on unit green alone.
- `product_oracle_cmds` (if provided) are **required additional** checks, not a way to skip live defaults.
- Skip live verify only when user sets `skip_live_verify=true` **and** task is non-feature (docs/process) — never for CLI/host/feature work.

## 4. Review lane floors (aligned)

| Context | Minimum lanes (all on disk) |
|---------|----------------------------|
| **orchestrate-implement** unit (full/standard) | Behavior/TDD + Safety/Hardening |
| **orchestrate-implement** integration | Integration Behavior + Integration Safety |
| **implementor** unit (standard) | behavior, adversarial, security, memory |
| **implementor** unit (full — **default for multi-unit / security**) | + practices, thermo |
| **implementor** unit (test lock) | test-behavior, test-coverage |
| **implementor** integration | integration-behavior, integration-safety, integration-security |
| **End-of-task** (always on integrated substantive work) | T1 Behavior+Style; **T2** if risk / multi-module / implement-subagent; **T3** if size/architecture |

**Mapping:** implementor’s four code lanes **satisfy and exceed** orchestrate-implement dual. End-of-task T1–T3 may **reuse** on-disk unit/integration artifacts when coverage matches; **top up** missing Style/Thermo/Safety angles rather than re-running everything blindly — but never claim done with zero VERDICT files.

## 5. Unit design (composition + fat)

### Fat (must re-split before implement)

Any of: acceptance bullets **> 3**; touch estimate **> 5** files or multi-package; multi-language; multiple independent outcomes without why-inseparable; open-ended discovery.

### Composition acceptance (required when the unit touches product surface)

At least one acceptance bullet (or integration acceptance) must lock:

- Workspace-root / project-path contracts (CLI write path == loader path; **nested-cwd** write then product-load from workspace root)
- Monopath / package root / product loader wiring for new modules
- Cross-unit public contracts (API, env, wire format) exercised by a test dependents can rely on

**Hard rules:**

- Product-surface units that touch CLI writers **and** product loaders **must** include nested-cwd writer↔loader acceptance (or an explicit integration test that is a required complete gate) — unit-local CRUD alone is insufficient
- `tests_touched: false` (no test delta) ⇒ unit incomplete
- Hollow stubs as product path ⇒ Behavior **FAIL**
- Incomplete monopath/loader/CLI↔store path contracts ⇒ **FAIL**, not residual-by-default when acceptance requires product surface

## 6. Recurring defect checklist (Zig / security — hard-fail at complete)

Inject into implement + Safety/memory/security lanes. Any **in-scope** hit without **fix** or **explicit accepted residual** at complete = **FAIL**. Silent minor carry-forward of these classes is forbidden.

| Class | What to check | Complete gate |
|-------|----------------|---------------|
| **Ownership / `errdefer`** | One owner, one free path; no double-free on transfer; no free of shared argv/env before reap; `errdefer` matches every `try` alloc path | Memory-lane disk VERDICT must **FAIL** on post-transfer double-free |
| **Multi-process races** | load-modify-write of allowlist/allow-once/stores uses `flock` (or equivalent); no best-effort single-use that can double-grant under concurrency | **flock (or equivalent) or explicit accepted residual** required at complete — not silent minor |
| **cwd / realpath form** | issue, redeem, evaluate, and grant tables use **one** normalized form (realpath); Darwin `/var` vs `/private/var`; null-cwd must not become inert `"."` grants | Single normalized realpath across issue/redeem/evaluate (incl. Darwin) or explicit residual |
| **Project-path contract** | Writers and loaders agree on workspace-root walk vs process cwd; nested-cwd parity | FAIL if product path dead while unit green |
| **Fail-closed + honesty** | Evaluator/hook errors deny; **corrupt permanent loads are operator-visible** (not silent discard); live surfaces do not teach removed daemon paths | Corrupt load must warn/surface or explicit accepted residual |
| **Shell corpus** | Shell evaluator changes keep `./scripts/zig build test-shell-engine` and 100% corpus parity non-skippable | Non-skippable when `shell_engine` touched |

## 7. Mode defaults

| Workflow | Default | Lite |
|----------|---------|------|
| orchestrate-implement | **full** if ≥3 units or security-sensitive; else **standard** | Only user-explicit + ≤2 small units |
| implementor.rhai | **full** when multi-unit or security keywords in task; else **standard** (still min 4 code lanes) | Only `mode=lite` **and** user intent clear; never auto |

Agent budget: prefer **512–1024** for implementor. Low budget → warn and **escalate**, do not drop required lanes.

## 8. Done definition (summary)

1. In-scope acceptance green with real tests (not checklist cosplay).  
2. Narrowest useful gate green; composition / integrated acceptance green.  
3. On-disk VERDICTs for **all** required lanes; **host-native** gate green; main agent re-verify.  
4. End-of-task tier satisfied or reused with evidence under `planning/reviews/` (coverage map, not empty).  
5. Residuals honest; no fail-open; no fake complete; no split integration.  
6. `metrics.md` present for the run (local residual-class rollup).  
7. **Live product verify PASS** for feature work (§3a) — unit green alone is incomplete.

## 9. Relationship table

| Artifact | Role |
|----------|------|
| This file | **Canonical floor** — alignment + correctness priority |
| `docs/agents/work-and-review.md` | Day-to-day work mode, skill resolution, T1–T3 end-of-task |
| `orchestrate-implement` skill | Multi-unit state machine + dual disk gates |
| `implementor.rhai` | Automated multi-unit TDD workflow (min 4 code lanes + integration); **per-unit unit live smoke + draft `gh stack` PR** (default `submit_stack=true`) |
| `scripts/implementor-disk-gate.sh` | **Host-native** conjunctive VERDICT gate (missing/FAIL ⇒ exit 1) |
| `scripts/implementor-metrics.sh` | Local per-run residual-class + VERDICT inventory → `metrics.md` |
| Hand prompts under `planning/` | Must reference this floor; untracked |
| `docs/dev/phase-handoff-format.md` | Lighter phase template — does **not** replace unit handoff schema |

### Stacked draft PRs (delivery)

- Prefer **native GitHub stacked PRs** (`gh stack` extension; public preview 2026-07) over Graphite.
- **One draft PR per unit**, only after: dual/min-4 PASS → path-scoped merge → **build OK** → **unit live product smoke PASS** (operator role). Suite-green alone is not enough.
- Commands: `gh extension install github/gh-stack`, then `gh stack init/add` + `gh stack submit --auto` (drafts). Requires `gh` ≥2.90 ideally.
- Opt out: `submit_stack=false`. Never merge from the implementor.
