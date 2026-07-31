# Residual knowledge packs

Human-authored **ambiguous** examples for ryk’s Mac `fm-steward` residual path.

These packs are compiled into `Fixtures/ambig-fewshot/seed.json`, loaded into a **text-mode Wax** store, and retrieved **only after** rules pre-pass returns nil. Foundation Models use the neighbors as **guidance**, not authority.

## Product law

| Rule | Meaning |
|------|---------|
| Residual only | Wax runs after `RulesPrePass` miss |
| Assist only | FM decides `continue` \| `ask` \| `ask_sticky_candidate` |
| Never deny/allow | Retrieved examples cannot unlock hard deny |
| Fail-open | Wax errors → empty few-shots |
| Ambiguous only | No `rm -rf /`, bare `curl\|bash` as gray |
| Original examples | DCG-style taxonomies may inspire families; **do not** vendor DCG packs |

## Authoring

1. Edit or add YAML under `shell/` or `containers/`.
2. Compile:

```bash
cd macos/fm-steward
python3 scripts/compile-residual-knowledge.py
python3 scripts/compile-residual-knowledge.py --check
```

3. Run tests: `swift test`.

### Pack schema (v1)

```yaml
schema_version: 1
id: residual.wipe_vs_clean
name: Project wipe vs artifact clean
domain: shell
description: |
  Author note (not necessarily stored in Wax).

hard_rule_exclusions:
  - "rm -rf /"

entries:
  - id: W_rm_data
    command: "rm -rf ./data"
    verdict: ask          # continue | ask | ask_sticky_candidate
    why: "Non-allowlist project data wipe; human should confirm."
    tags: [ambig, wipe, data]

contrasts:
  - safe: W_rm_build
    risk: W_rm_data
    note: "build vs data"
```

**Entry rules:** real command strings; short `why`; no secrets; valid soft verdicts only.

Compiler: **stdlib Python 3 only** (restricted YAML subset — no PyYAML required).

## Coding families (v1)

| Pack | Path |
|------|------|
| wipe vs clean | `shell/wipe_vs_clean.yaml` |
| install hygiene | `shell/install_hygiene.yaml` |
| git gray (residual-visible) | `shell/git_gray.yaml` |
| network out | `shell/network_out.yaml` |
| process | `shell/process.yaml` |
| docker/compose | `containers/docker_compose.yaml` |

**Git note:** `HardDangerRules` already force-ask on `git push …--force` / `-f` and `git reset --hard`. Prefer residual-visible grays (`git clean -fdx`, branch force-delete, etc.). Do not claim residual coverage for force-push commands.

**CommandShape note:** allowlisted `rm -rf ./build|node_modules|…` may skip FM entirely; keep them as continue **contrast labels** for neighbors.

## Multi-domain steward (employee later)

**One residual steward, many domains.** Coding agent uses `domain: shell` today.

| Domain dir | Status |
|------------|--------|
| `shell/`, `containers/` | Implemented packs |
| `email/` | Stub — not implemented |
| `pay/` | Stub — not implemented |
| `social/` | Stub — not implemented |

### Floors / sticky ownership (architecture only — not built here)

| Concern | Owner |
|---------|--------|
| High-stakes floors (pay / bulk·cold email / public social) | Host + steward both may enforce later; **host** owns product surfaces |
| Always-allow storage | **Host only** |
| Sticky allow storage | **Host only** (after user accepts) |
| `ask_sticky_candidate` offer | Steward FM may **offer**; user accepts; host enforces |

**Default floors (when employee surfaces exist):** pay / bulk·cold email / public social → always-ask.

**User always-allow (later):** social + normal email OK; **not** permanent always-allow for pay or bulk/cold email.

**Future risk-card fields (host fills):** `recipient_count`, `amount`, `public_post`.

### Explicit non-goals of this tree

- No host floors / always-allow UI code  
- No email/pay/social seed bodies  
- No Phase 4 Zig hook wiring  
- No raw DCG pack import into Wax  

## Pipeline

```text
YAML packs  →  compile-residual-knowledge.py  →  Fixtures/ambig-fewshot/seed.json
  →  WaxFewShotStore.seed (text mode)  →  residual retrieve k≤3
  →  LiveBackend.prompt few-shot block  →  FM soft verdict
```

Reseed when the `.wax` store is missing **or** seed content SHA-256 ≠ sidecar `*.wax.seedsha`.

## Neighbor filter (deferred — P2)

**Token / tag neighbor filtering is deferred** until `scripts/residual-stress-matrix.sh --live`
shows systematic **wrong-neighbor bias** (e.g. residual gray cards repeatedly pull
irrelevant pack families that degrade FM soft verdicts).

Until then:

| Rule | Meaning |
|------|---------|
| No forced verdict from score | Retrieval similarity **never** sets `continue` / `ask` / `ask_sticky_candidate` |
| Assist only | Neighbors are prompt guidance; **FM decides** the soft verdict |
| Measure first | Use residual-stress-matrix residual gray dump (`verdict_off` vs `verdict_auto`, hits) before adding filters |

Do **not** pre-emptively gate neighbors by token overlap or tags without matrix evidence.
If bias appears, design a narrow filter and re-run the matrix; still never promote
retrieval score into an authoritative verdict.
