# Work and review playbook

Hard rules live in [`AGENTS.md`](../../AGENTS.md). This file is the full SOP for how agents work, load Zig skills, and gate “done” with adversarial review.

**Implement floor (canonical alignment):** [`implement-floor.md`](implement-floor.md).  
**Priority:** correctness and **complete, working features** over cost. Never thin review, switch to lite, or soft-PASS to save agent-minutes.

## 1. Goals

1. **Act when you can** — clear tasks move without waiting for approval on local work.
2. **Use sub-agents** for non-trivial multi-step work, parallelism, isolation, and specialist Zig lanes.
3. **Load Zig skills** for implementation, style, and review — and force the same on sub-agents via prompts.
4. **End substantive code work** with a tiered adversarial multi-agent review before claiming complete.
5. **Ship complete acceptance** — product paths wired, tested, and fail-closed where required; hollow units that only pass isolated checks are not done.

## 2. Work mode

| Kind of work | How to execute |
|--------------|----------------|
| Trivial / mechanical (typo, one-liner, pure format, obvious rename) | Main agent acts **directly** |
| Non-trivial multi-step | **Prefer sub-agents** (implement, research, specialist) |
| Parallel independent slices | Sub-agents (worktrees when blast radius matters) |
| Explicit orchestration / large feature | Sub-agents + short internal plan (todos) |
| Ambiguous goal or architecture fork | **Pause** — short plan or clarifying question |
| Irreversible / shared remote action | **Always ask** (push, force-push, published PR review submit, unsolicited deletes, new deps, shared infra) |

Rules:

- Sub-agent output is **advisory until the main agent verifies** against the tree, the narrowest useful test gate, and Orca product rules in `AGENTS.md`.
- “Plan first” means **todos / a brief internal plan** for multi-step work — not “block on human go-ahead” by default.
- Preserve user-owned dirty changes.

## 3. Skill resolution

Resolve skills in this order (first hit wins):

1. Repo Grok links: `.grok/skills/<name>/SKILL.md`
2. Repo plugin pack: `.agents/plugins/orca/skills/<name>/SKILL.md`
3. User agents tree: `~/.agents/skills/<name>/SKILL.md`
4. User Grok skills: `~/.grok/skills/<name>/SKILL.md`

Known names used by this playbook:

| Name | Typical location(s) |
|------|---------------------|
| `zig` | `.grok/skills/zig` → `~/.agents/skills/zig` |
| `zig-best-practices` | `.grok/skills/zig-best-practices`, `.agents/plugins/orca/skills/zig-best-practices` |
| `zig-code-review` | `.grok/skills/zig-code-review` |
| `zig-memory-safety` | `.agents/plugins/orca/skills/zig-memory-safety` |
| `zig-abstractions` | `.agents/plugins/orca/skills/zig-abstractions` |
| `zig-build-system-complexity` | `.agents/plugins/orca/skills/zig-build-system-complexity` |
| `zig-ecosystem-tooling-gaps` | `.agents/plugins/orca/skills/zig-ecosystem-tooling-gaps` |
| `thermo-nuclear-code-quality-review` | `~/.grok/skills/thermo-nuclear-code-quality-review` |

If a required skill is missing: **fail the lane or pause implementation**, report the missing path, and do not improvise from training-data “Zig vibes.”

## 4. Zig skill packs by activity

When the task touches Zig (`.zig`, `build.zig`, `build.zig.zon`, Zig packages under `packages/` / `src/`):

| Activity | Must load before writing/reviewing |
|----------|------------------------------------|
| **Implement / fix** | `zig-best-practices` (core). Add `zig-memory-safety` if allocators, ownership, pointers, IO, lifetime, or concurrency. Add `zig-abstractions` if designing APIs, generics, or interfaces. Add `zig-build-system-complexity` if touching `build.zig` / zon / package graph. Prefer also loading `zig` when version-sensitive std APIs matter (0.16 pin). |
| **Style / idioms** | `zig-best-practices` language/style references (`language-patterns.md` and related). |
| **Review — behavior** | `zig-best-practices` + `zig-code-review` (+ `zig` if API drift risk). |
| **Review — style** | `zig-best-practices` style refs + `zig-code-review` as needed. |
| **Review — safety** | `zig-memory-safety` + `zig-best-practices` performance/security refs + Orca fail-closed rules from `AGENTS.md`. |
| **Review — thermo (T3)** | `thermo-nuclear-code-quality-review` (+ Zig packs above for Zig diffs). |

Non-Zig / mixed:

- **Non-Zig only:** do not force Zig skills; use project verify gates and language-appropriate review (scripts, TS plugins, docs).
- **Mixed:** load Zig packs only for Zig paths; never conflate shell evaluator authority with non-Zig code paths.

### Sub-agent prompt requirement

Every implement or review sub-agent prompt **must** include:

1. Absolute or repo-relative paths to the skill `SKILL.md` files to load first.
2. Which reference files inside the skill to open for this task (when known).
3. The lane charter (implement vs review-only; which adversarial lens).
4. Product constraints from `AGENTS.md` relevant to the slice (fail-closed shell, no cargo-from-zig, narrowest gate, etc.).

## 5. When end-of-task review is mandatory

**Mandatory** for substantive code-touching work, including any of:

- Behavior or security-surface changes
- Non-trivial multi-file / multi-module changes
- Work that used implement sub-agents or orchestration
- Anything the agent would call “ready to commit” / “done” on a real task

**Skip or optional** (unless the user asks for review):

- Pure docs / planning / `AGENTS.md` / playbook edits
- Mechanical renames, formatting, one-line obvious fixes
- Exploratory read-only investigation with no edits
- Explicit user “skip review” / “draft only”

## 6. Review tier ladder

Pick the **highest** tier that matches. Measure on the **task’s full final diff** (not per micro-commit).

### T1 — Standard (2 lanes)

**When:** default for substantive code that is not T2/T3.

| Lane | Charter | Zig skills |
|------|---------|------------|
| **Behavior / Correctness** | Spec match, tests prove claimed behavior, regressions, API contracts, fail-closed product rules, TDD honesty | `zig-best-practices`, `zig-code-review` |
| **Style / Idioms** | Zig/Rust/project style, explicitness, naming, dead code, local consistency | `zig-best-practices` (style/language refs) |

### T2 — Hardened (3 lanes)

**When:** any of:

- Security surface: hooks, shell evaluator, policy, sandbox, secrets, network, MCP, intercept, UDS, credentials, redteam
- Memory / alloc / lifetime / unsafe-ish FFI
- Multi-module Zig core work
- Implement sub-agents were used for the task
- Risk path keywords (non-exhaustive): `shell_engine`, `hook`, `policy`, `sandbox`, `secret`, `credential`, `network`, `mcp`, `intercept`, `uds`, `evaluator`, `fail closed`, `deny`, `allowlist`, `plugin`

| Lane | Charter | Zig skills |
|------|---------|------------|
| T1 lanes | as above | as above |
| **Safety / Hardening** | Memory lifetime, UB-ish patterns, secrets handling, security surface, fail-closed edges, adversarial inputs | `zig-memory-safety`, `zig-best-practices` (security/perf), `AGENTS.md` risk rules |

### T3 — Full (4 lanes)

**When:** any of:

- ≥ **8** files changed, or ≥ **3** top-level modules (`src/`, `packages/`, `integrations/<name>/`, `scripts/`, etc.)
- ≥ **~300** net LOC changed (insertions+deletions; ignore pure lockfile / pure format noise when obvious)
- Architecture: new public API, protocol/schema change, build-system change, migration phase work, new security control
- User asked for deep review / ship-ready / full gate / “thermo”

| Lane | Charter | Skills |
|------|---------|--------|
| T2 lanes | as above | as above |
| **Thermo-nuclear quality** | Maintainability, abstraction quality, spaghetti growth, ambitious simplify-preserving-behavior findings | `thermo-nuclear-code-quality-review` + Zig packs for Zig diffs |

Do **not** promote to T3 on generated/vendor noise alone, or pure bulk fixtures without product logic (unless security fixtures).

Small but security-critical → **T2**, not T3, unless architecture/size signals hit.

## 7. Review cadence

1. **Default:** one **end-of-task** tiered review on the **full task diff**. This is the mandatory done gate for substantive code.
2. **Orchestrated multi-unit work:** per-unit **hard** dual review (Behavior + Safety on disk; implementor: min four code lanes) so units do not merge garbage — **and** still run end-of-task tiered review on the integrated result. Promote T2/T3 from the **total** integrated diff. Prefer **more** review when risk is high; never drop required lanes for cost (see [`implement-floor.md`](implement-floor.md)).
3. **Do not** skip dual/integration disk gates on “small” multi-unit work. Full T3 on every tiny unit is optional only when that unit alone fails T3 size criteria — dual PASS is still required for orchestrated units.
4. Implementer self-checks (load Zig skills, run L0/L0.5) are not a substitute for the end gate.
5. **Reuse:** unit/integration VERDICT files may satisfy end-of-task lane coverage when they match the tier; **top up** missing lanes (e.g. Style, Thermo) rather than claiming done with soft monologue.

## 8. How to run lanes

1. Compute tier from §5–§6.
2. Spawn **real** review sub-agents (parallel when the harness allows). Self-review monologue does **not** satisfy the gate.
3. If sub-agents are unavailable: state the limitation, either fall back to a single thorough main-agent review **labeled as degraded**, or stop and ask — never fake multi-lane.
4. Each lane is **read-only / review-only**: no product code edits by reviewers.
5. Lanes are adversarial to the claim **“this is done”**, not to each other.
6. Main agent classifies findings:
   - **Blocking:** correctness broken; missing tests for claimed behavior; security/fail-closed regression; memory/UB risk; secrets; wrong architecture for the task; verification gate red for the change
   - **Non-blocking:** nits, pure preference, optional refactors, out-of-scope suggestions
7. **Fix loop:** main agent (or implement sub-agent) fixes **blockers**, re-runs failed lanes (or full tier if cross-cutting). Max **2** automatic fix→re-review loops, then escalate to the user with open blockers.
8. **Nits** do not block “done”; fix only if cheap and clearly in-scope (or the user asked for clean).
9. **Reuse:** if the user already ran `/multi-agent-code-review` (or equivalent) on the same diff in-session and coverage ≥ required tier, reuse it; otherwise top up missing lanes only.

## 9. Evidence and artifacts

Write an untracked note:

```text
planning/reviews/YYYY-MM-DD-<slug>-end-review.md
```

Minimum contents:

- Task summary
- Tier chosen and why (risk keywords, file/module/LOC counts, architecture flags)
- Lanes run and skill paths loaded
- Blockers vs nits
- Fix-loop count
- Final **PASS** / **FAIL** (or **WAIVED** with user quote)

Repo boundary: do **not** commit `planning/reviews/*` unless the user explicitly asks to publish.

User-facing summary: one line per lane (`PASS` / `FAIL` + top blockers). No novel.

## 10. Definition of done

All of the following:

1. Requested work is implemented **and works** for in-scope acceptance (or an explicit blocker is reported) — not stubs, not “residual later” for product paths.
2. Narrowest useful verification gate from `AGENTS.md` is green for the change; composition / cross-unit contracts are covered when the task spans units (see implement-floor §5–6).
3. If review was mandatory: all launched lanes report **no open blockers** (or the user waived them), with **on-disk** evidence when multi-unit / orchestrated.
4. Review evidence exists (§9) when review ran.
5. No irreversible/shared action was taken without approval.
6. Recurring defect classes (ownership/`errdefer`, flock, cwd/realpath, project-path contracts, fail-closed honesty) checked when in scope — see implement-floor §6.

## 11. Relationship to other skills

| Skill / flow | Relationship |
|--------------|--------------|
| [`implement-floor.md`](implement-floor.md) | **Canonical** multi-path alignment + correctness-first floor |
| `orchestrate-implement` | Multi-unit state machine: handoff → dual VERDICT → path commit → dual integration; this playbook still requires end-of-task tiered review on the integrated result |
| `implementor` (`.grok/workflows/implementor.rhai`) | Automated TDD multi-unit path; min 4 code lanes + integration security; same complete gates |
| Hand prompts in `planning/` | Must cite implement-floor; hard VERDICT language required for multi-unit claims |
| `multi-agent-code-review` / `multi-agent-pr-review` | Can satisfy or top up end-of-task tiers when coverage matches |
| `check-work` / `/verify` | Complements verification; does not replace adversarial lanes |
| `tdd` | Required for non-trivial implement; Behavior lane audits TDD honesty |
| Thermo-nuclear skill | T3 lane; also implementor `full` mode per-unit thermo |

## 12. Quick checklist (paste into sub-agent prompts)

```text
You are a REVIEW-ONLY adversarial lane: <Behavior|Style|Safety|Thermo>.
Do not edit product code.
First read these skills (in order):
  - <absolute path>/SKILL.md
  - ...
Scope: task diff for <summary>; paths: <list>.
Orca constraints: fail-closed shell evaluator errors; Zig 0.16 via ./scripts/zig; narrowest gate; no cargo from zig build.
Return: ## Lane: <name> with Blocking / Non-blocking / Verdict (PASS|FAIL).
```

```text
You are an IMPLEMENT lane for: <slice>.
First read these skills:
  - <paths>
Follow TDD for non-trivial changes. Verify with: <gate command>.
Output is advisory; main agent will verify.
```
