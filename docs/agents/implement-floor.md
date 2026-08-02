# Implement floor (canonical)

**Priority: correctness and complete, working features over cost, speed, or agent-minute thrift.**  
Thin review, lite mode, soft PASS stubs, and incomplete-slice “green units” are process bugs — not optimizations.

Hard rules that live in [`AGENTS.md`](../../AGENTS.md) still win on stack conflict. This file **aligns** concurrent implement workflows so they enforce one floor.

## 1. Which path to use

| Work shape | Canonical path | Floor |
|------------|----------------|-------|
| Trivial / mechanical | Main agent direct | L0/L0.5 gate; no multi-lane review unless risk |
| Single-slice substantive | Main agent or one implement sub-agent + **end-of-task** review | [`work-and-review.md`](work-and-review.md) T1–T3 on full task diff |
| Multi-unit / orchestrated | **`orchestrate-implement`** (skill) **or** **`implementor`** workflow (`.grok/workflows/implementor.rhai`) | On-disk handoffs + dual (or min-4) code VERDICTs + dual/tri integration + end-of-task on integrated result |
| Hand-written planning prompts | Must cite this floor + hard VERDICT language | Same evidence as orchestrated path; no monologue “done” |

Do **not** invent a third soft path. Prefer the more complete gate when two conflict.

## 2. Correctness-first principles

1. **Features must be complete and working** for in-scope acceptance — not stubs, not “wired later,” not residual-by-default for product paths.
2. **Quality is what is forced on disk** (`test -s` + `VERDICT: PASS|FAIL`) — not chat paraphrase or SKILL prose.
3. **Never drop review lanes to save budget.** If budget is insufficient: escalate / pause / re-launch with higher `agent_budget`. Do not silently thin to one lane or invent PASS.
4. **Never choose lite/standard because it is cheaper.** Lite only when the user **explicitly** asks **and** the task is ≤2 small/non-security units. Security / multi-module / multi-unit defaults to **full** (or standard with full dual + integration, never lite).
5. **Sub-agent output is advisory** until the main agent (or orchestrator disk gate) re-checks tree, tests, and product rules.
6. **Narrowest verify gate for iteration**; still re-verify composition and integrated acceptance before complete.
7. **Incomplete wiring is a FAIL**, not a residual, when the unit’s acceptance or the overall task requires product loaders / monopath import / CLI↔store path contracts.

## 3. Hard complete gates (multi-unit)

Complete is **forbidden** unless all apply:

- [ ] Every in-scope unit has a **complete** handoff on disk (section gate)
- [ ] Every unit has **on-disk** review VERDICT PASS for the path’s required lanes (see §4)
- [ ] Path-scoped commits only; dirty policy honored
- [ ] Narrow verify green vs baseline after merge
- [ ] Integration review VERDICT PASS on disk (behavior + safety; security when security surface)
- [ ] Residuals cleared **or** explicitly accepted with honesty (no silent operator-visible gaps)
- [ ] End-of-task tiered review on the **integrated** diff (T1–T3 per work-and-review) — orchestrated dual does not erase this
- [ ] No rubber-stamp: missing VERDICT file ⇒ FAIL, not PASS

## 4. Review lane floors (aligned)

| Context | Minimum lanes (all on disk) |
|---------|----------------------------|
| **orchestrate-implement** unit (full/standard) | Behavior/TDD + Safety/Hardening |
| **orchestrate-implement** integration | Integration Behavior + Integration Safety |
| **implementor** unit (standard) | behavior, adversarial, security, memory |
| **implementor** unit (full — **default for multi-unit / security**) | + practices, thermo |
| **implementor** integration | integration-behavior, integration-safety, integration-security |
| **End-of-task** (always on integrated substantive work) | T1 Behavior+Style; **T2** if risk / multi-module / implement-subagent; **T3** if size/architecture |

**Mapping:** implementor’s four code lanes **satisfy and exceed** orchestrate-implement dual. End-of-task T1–T3 may **reuse** on-disk unit/integration artifacts when coverage matches; **top up** missing Style/Thermo/Safety angles rather than re-running everything blindly — but never claim done with zero VERDICT files.

## 5. Unit design (composition + fat)

### Fat (must re-split before implement)

Any of: acceptance bullets **> 3**; touch estimate **> 5** files or multi-package; multi-language; multiple independent outcomes without why-inseparable; open-ended discovery.

### Composition acceptance (required when the unit touches product surface)

At least one acceptance bullet (or integration acceptance) must lock:

- Workspace-root / project-path contracts (CLI write path == loader path; nested-cwd behavior)
- Monopath / package root / product loader wiring for new modules
- Cross-unit public contracts (API, env, wire format) exercised by a test dependents can rely on

`tests_touched: false` (no test delta) ⇒ unit incomplete. Hollow stubs as product path ⇒ Behavior **FAIL**.

## 6. Recurring defect checklist (Zig / security — hard-fail candidates)

Inject into implement + Safety/memory/security lanes. Any in-scope hit without fix or explicit residual = **FAIL**:

| Class | What to check |
|-------|----------------|
| **Ownership / `errdefer`** | One owner, one free path; no double-free on transfer; no free of shared argv/env before reap; `errdefer` matches every `try` alloc path |
| **Multi-process races** | load-modify-write of allowlist/allow-once/stores uses `flock` (or equivalent); no best-effort single-use that can double-grant under concurrency unless residual is **explicit and accepted** |
| **cwd / realpath form** | issue, redeem, evaluate, and grant tables use one normalized form (realpath); Darwin `/var` vs `/private/var`; null-cwd must not become inert `"."` grants |
| **Project-path contract** | Writers and loaders agree on workspace-root walk vs process cwd |
| **Fail-closed + honesty** | Evaluator/hook errors deny; corrupt permanent loads are operator-visible (not silent discard); live surfaces do not teach removed daemon paths |
| **Shell corpus** | Shell evaluator changes keep `./scripts/zig build test-shell-engine` and 100% corpus parity non-skippable |

## 7. Mode defaults

| Workflow | Default | Lite |
|----------|---------|------|
| orchestrate-implement | **full** if ≥3 units or security-sensitive; else **standard** | Only user-explicit + ≤2 small units |
| implementor.rhai | **full** when multi-unit or security keywords in task; else **standard** (still min 4 code lanes) | Only `mode=lite` **and** user intent clear; never auto |

Agent budget: prefer **512–1024** for implementor. Low budget → warn and **escalate**, do not drop required lanes.

## 8. Done definition (summary)

1. In-scope acceptance green with real tests (not checklist cosplay).  
2. Narrowest useful gate green; composition / integrated acceptance green.  
3. On-disk VERDICTs for required lanes; main agent re-verify.  
4. End-of-task tier satisfied or reused with evidence under `planning/reviews/`.  
5. Residuals honest; no fail-open; no fake complete.

## 9. Relationship table

| Artifact | Role |
|----------|------|
| This file | **Canonical floor** — alignment + correctness priority |
| `docs/agents/work-and-review.md` | Day-to-day work mode, skill resolution, T1–T3 end-of-task |
| `orchestrate-implement` skill | Multi-unit state machine + dual disk gates |
| `implementor.rhai` | Automated multi-unit TDD workflow (min 4 code lanes + integration) |
| Hand prompts under `planning/` | Must reference this floor; untracked |
| `docs/dev/phase-handoff-format.md` | Lighter phase template — does **not** replace unit handoff schema |
