# ryk CLI / UI issues catalog

**Status:** open backlog from 2026-08-03 full CLI audit  
**Evidence:** CLI inventory + implementation plan (audit session dump removed; durable issues live here)  
**UI implementation plan (scoped):** `docs/agents/cli-ui-libvaxis-implementation-plan.md`  
→ Focus: **doctor · packs · allowlist** only (grill freeze). Full-tier items remain backlog here until that plan is reopened.  

Severity: **P0** ship-blocker / honesty · **P1** high user pain · **P2** clear gap · **P3** polish / niche  

IDs are stable for planning (`ISS-*`); not GitHub numbers unless filed.

---

## Index by severity

| Sev | Count | Themes |
|-----|-------|--------|
| P0 | 3 | Help/binary drift, dead advertised commands, hide-list honesty |
| P1 | 10 | Agent failure UX, packs/doctor linear walls, replay TUI opt-in, dashboard hang, host --help, suggestions gaps |
| P2 | 12 | Dry-run parity, naming collisions, overlaps, daemon noise, scan triage |
| P3 | 8 | Redundant aliases, niche commands, name “redteam”, etc. |

---

## P0 — Honesty / ship trust

### ISS-DRIFT-01 — PATH install help surface drifts from tree Safe Launch
- **Symptom:** Installed `~/.local/bin/ryk` (same semver) public help still shows **`status`**, omits **`doctor` / `scan` / `update`**. `license` appears under Advanced; workspace tree has neither live `status` nor `license`.
- **Impact:** Users follow wrong verbs; scan/update look “missing.”
- **Repro:** `ryk help` on PATH vs workspace `zig-out/bin/ryk help`.
- **Fix direction:** Ship current help registry; version/channel honesty; drop status/license ads from install.
- **Plan link:** Wave X.6

### ISS-DEAD-01 — Hide-list commands return “not available” with no migration
- **Commands:** `history`, `precommit`, `classify`, `suggest-allowlist`, `simulate`, `rebase-recover`, `config`
- **Symptom:** Exit 2, short stub; even `--help` unavailable. Help.zig still holds rich (hidden) copy.
- **Impact:** Cryptic; dead weight; history had live_view code that users cannot reach.
- **Fix direction:** Removed-notice redirects (`history`→`replay`, `classify`→`explain`/`tools classify`, …) or delete registry entries.
- **Plan link:** Wave X.3

### ISS-DEAD-02 — `license` advertised on PATH, unknown on tree
- **Symptom:** PATH `help --all` lists license; workspace: `unknown command 'license'` with no removed notice.
- **Impact:** Trust / docs/install matrix lie.
- **Fix direction:** Explicit removed notice or remove from all published help; release notes.
- **Plan link:** Wave X.6

---

## P1 — High user pain / UI experience

### ISS-UX-01 — Agent launch: shield banner then raw Node/Bun stacks
- **Commands:** host aliases (`claude`, `codex`, `pi`, …), `run`
- **Symptom:** Excellent SHIELD UP UI; failure dumps multi-page native stacks (EPERM fstat, exit 5 after seatbelt).
- **Impact:** Looks broken; hides actionable causes (missing binary, /tmp FD under empty-backpack).
- **Fix direction:** Failure classifier + libvaxis/plain **error panel** with next steps; demote stacks to log.
- **Plan link:** T1-D

### ISS-UX-02 — `packs` is a long linear list with no browse TUI
- **Status:** **Shipped** (PR #101) — default dual-layer browse TUI on colour TTY; `--plain`/`--json`/`--no-rich` stay linear.
- **Symptom (historical):** Default list is a wall of pack IDs; enable/disable not discoverable in-session.
- **Impact:** Power feature underused; “no libvaxis where expected.”
- **Fix direction:** TTY list/detail/actions TUI; `--plain`/`--json` remain.
- **Plan link:** T1-A

### ISS-UX-03 — `doctor` deep output is tables-only (no progressive TUI)
- **Status:** **Shipped** (PR #101) — opt-in `ryk doctor --tui` four-pane deep-dive; linear doctor remains default.
- **Symptom (historical):** Useful but dense; hard to scan hosts vs capabilities vs next steps on small terminals.
- **Impact:** Primary diagnose verb less teachable than scan.
- **Fix direction:** Multi-pane doctor TUI on TTY; keep `--json`.
- **Plan link:** T1-C

### ISS-UX-04 — Host aliases swallow `--help` / `-h`
- **Symptom:** `ryk claude --help` launches agent with `--help` as agent argv.
- **Impact:** No ryk usage path without `ryk help claude`.
- **Fix direction:** Intercept help flags before `host_launch` rewrite.
- **Plan link:** T1-D / X.1

### ISS-UX-05 — `replay` TUI is opt-in only (`--tui`)
- **Symptom:** Core “review session” path stays linear by default; TUI buried.
- **Impact:** Inconsistent with scan’s default TTY investment.
- **Fix direction:** TTY default → live_view when sessions exist; keep `--list`/`--json`.
- **Plan link:** T1-B

### ISS-UX-06 — `dashboard --once` hangs without HTTP client
- **Symptom:** Prints listen URL then waits indefinitely (audit saw exit 142 under timeout).
- **Impact:** Broken smoke/automation story.
- **Fix direction:** Self-request or idle timeout → exit 0; document.
- **Plan link:** Wave X.5

### ISS-UX-07 — Missing / weak subcommand suggestions
- **Cases:** `packs shoe` (no → show); `allowlist ad` (full usage, no → add).
- **Contrast:** Top-level `docter`, `policy explian`, `plugin instll` work.
- **Fix direction:** Wire `suggestions.writeUnknownSubcommand` for packs/allowlist (and audit peers).
- **Plan link:** Wave X.2

### ISS-UX-08 — Hide-list and license give no “did you mean / use instead”
- **Related:** ISS-DEAD-01, ISS-DEAD-02
- **Fix direction:** Same as redirects with copy-paste next commands.

### ISS-UX-09 — Missing agent binary UX is cryptic
- **Symptom:** Exit 5 + stacks rather than “install codex then: ryk codex”.
- **Plan link:** T1-D

### ISS-UX-10 — Scan secret-material counts can alarm without triage
- **Symptom:** Large “secret material” counts without severity prioritization in plain/TUI.
- **Fix direction:** Severity filters / triage in scan TUI + plain summary.
- **Plan link:** T2-D

---

## P2 — Clear product gaps

### ISS-UX-11 — `stop` lacks `--dry-run`
- **Contrast:** `uninstall --dry-run`, `plugin install --dry-run` exist.
- **Impact:** Fear of running stop; no preview of plugin removals.
- **Plan link:** Wave X.4

### ISS-NAM-01 — Dual “packs” concepts
- **`ryk packs`** = shell_engine safety packs  
- **`ryk policy packs`** = policy presets  
- **Impact:** Confusion in help --all and day-2 workflows.
- **Fix direction:** Naming/help hierarchy; optional rename later (`safety-packs` alias).

### ISS-NAM-02 — Dual classify stories
- **Live:** `tools classify` (effect-class)  
- **Dead:** `classify` (shell)  
- **Impact:** Users hitting dead verb after docs/memory of old CLI.
- **Fix direction:** Redirect dead `classify` → explain/tools.

### ISS-DUP-01 — `report` vs `replay` overlap
- Both session review/export-ish; two mental models.
- **Fix direction:** Replay = interactive primary; report = export formats only.
- **Plan link:** T2-A

### ISS-DUP-02 — `test` vs `explain` overlap (humans)
- `test` minimal; `explain` pedagogical. Fine for scripts; confusing for humans.
- **Fix direction:** Help “when to use”; optional `test` advanced-only messaging.

### ISS-DUP-03 — `start` vs `plugin install` dual wiring paths
- Both configure hosts; dry-run excellent on plugin, start is primary door.
- **Fix direction:** Help: start = day-1; plugin = power/repair.

### ISS-DAE-01 — Daemon unavailable/incompatible noise in doctor/version
- Zig-first flows still center daemon status.
- **Fix direction:** Soft-deprioritize daemon when not required for local mediation story.

### ISS-RUN-01 — Seatbelt + redirected `/var/folders` stdout hurts automation
- Helpful warning exists; still exit 5 + stacks under capture.
- **Fix direction:** Failure panel class “redirected FD”; doc capture under workspace.

### ISS-RUN-02 — `run` flag surface is heavy for day-1
- Many advanced flags (`--seatbelt-profile`, `--network-backend`, …) visible in help.
- **Fix direction:** Progressive help (Safe Launch examples first); advanced section.

### ISS-ALLOW-01 — Allowlist TTY management is argv-only
- **Status (2026-08-03):** **Shipped** — bare `ryk allowlist` opens dual-layer browse TUI on colour TTY (`allowlist_browse` / U05). Argv add remains outside TUI (by design).
- **Polish:** ISS-ALLOW-02 empty-state / footer / counts shipped same day.
- **Plan link:** T2-B

### ISS-ALLOW-02 — Allowlist browse empty-state UX (manual TTY review 2026-08-03)
- **Status (2026-08-03):** **Shipped** — empty chrome + detail CTA + context footer + honest counts + mint selection.
- **Surface:** `ryk allowlist` alt-screen (screenshot review).
- **Shipped fixes:**
  1. List empty rows are short `(0 entries)` chrome (not truncated CLI).
  2. Single permanent-path teach block lives in **Detail** only (`ryk allow` / `add-command`).
  3. Chrome selection uses `·` (not actionable `›`); section headers painted with info token.
  4. Footer is context-sensitive: `r remove` only when selection is removable; Enter omitted.
  5. List range override: `0 permanent entries` / `N permanent entries` (not chrome-row counts).
  6. Write status abbreviated (`write: project · .ryk/allowlist.toml`); full path in Detail.
  7. Mint `selected_token = .success` (aligned with packs).
  8. No allow-once leakage in list or empty Detail CTA.
- **Residual (optional later):** in-TUI add wizard still out of scope (argv only by design).
- **Plan link:** post-U05 polish (allowlist browse)

### ISS-DENY-01 — Run deny block / replay denials UX can still level-up
- **Status (2026-08-03):** **Partially shipped** — progressive What → Why → Risk → Safer shape → What now.
- **Surfaces:** `run` `renderDenyBlock`; `formatDenyNextSteps` (shim + run); `replay` Denied actions callout.
- **Shipped fixes:**
  1. Hierarchy: blocked command (What) → Why/Rule/Policy → Risk (danger token) → Safer shape → numbered What now.
  2. What now CTAs: (1) Understand `ryk explain` → (2) Temporary `allow-once` → (3) Permanent advanced `allowlist`.
  3. Replay callout caps long lists and points at `ryk explain` for the first denied target.
- **Residual:** optional TTY “deny focus” mode in replay alt-screen; pack-specific next-step variants.
- **Plan link:** run/replay UX wave (partial)

### ISS-PLUG-01 — Plugin list/doctor not browsable on TTY
- Linear multi-host dumps; dry-run text is good but long.
- **Plan link:** T2-C

### ISS-HIST-01 — Dead `history` still has live_view code path
- Dead product surface; maintenance trap.
- **Fix direction:** Delete or gate code; redirect verb to replay.

---

## P3 — Polish / niche / low urgency

### ISS-ALIAS-01 — `disable` is undocumented stop alias
- Works; not on public help. Fine for compat; document or hide.

### ISS-NICHE-01 — `credentials` sparse output
- Correct for secrets; optional richer “configured/missing” matrix later.

### ISS-NICHE-02 — `shutdown` niche when daemon absent
- Still useful cleanup; quiet is OK.

### ISS-NAME-01 — `redteam` name overpromises
- Help correctly says engine self-test; name still sounds like “my policy is safe.”
- **Fix direction:** Rename later or banner “engine fixtures only.”

### ISS-INT-01 — `evaluate` / `hook` / `decide` are opaque to humans
- Correct as APIs; ensure help category stays Integrations/Advanced.

### ISS-INT-02 — `mcp` advanced surface steep
- Structure OK; no TUI planned (integration).

### ISS-STAGED-01 — `diff`/`apply`/`discard` feel purposeless until first staged write
- Expected; empty states OK. Optional TTY browser when pending exists (T3-C).

### ISS-POLISH-01 — `explain` already excellent; only colour/structure polish left
- Tier 3 only; do not force alt-screen.

---

## Issues explicitly out of scope for libvaxis program

| Issue | Why |
|-------|-----|
| Dashboard React redesign | Separate app; only CLI `--once` hang is in Wave X |
| Full multi-turn agent chat UX | Product agent, not ryk chrome |
| Exhaustive every-flag matrix | Not audit bar |
| Rebuilding Rust daemon history | Dead; redirect to Zig replay |

---

## Mapping: issue → implementation plan unit

| Issue ID | Plan unit |
|----------|-----------|
| ISS-UX-02 | T1-A packs TUI |
| ISS-UX-05 | T1-B replay default TUI |
| ISS-UX-03 | T1-C doctor TUI |
| ISS-UX-01, ISS-UX-09, ISS-UX-04, ISS-RUN-01 | T1-D failure panel + help intercept |
| ISS-DUP-01 | T2-A report/replay |
| ISS-ALLOW-01 | T2-B allowlist browser |
| ISS-PLUG-01 | T2-C plugin matrix |
| ISS-UX-10 | T2-D scan polish |
| ISS-POLISH-01 | T3-A |
| ISS-NAM-01 (help) | T3-B / naming |
| ISS-STAGED-01 | T3-C |
| ISS-DRIFT-01, ISS-DEAD-02 | X.6 |
| ISS-DEAD-01, ISS-UX-08, ISS-HIST-01 | X.3 |
| ISS-UX-07 | X.2 |
| ISS-UX-11 | X.4 |
| ISS-UX-06 | X.5 |

---

## Suggested GitHub filing batch (optional)

When filing to GitHub via `docs/agents/issue-tracker.md` conventions, prefer one issue per **P0/P1** ID above; group P3 into a single “CLI polish backlog” issue.

Suggested labels (if used): `area:cli`, `area:tui`, `ux`, `honesty`, `safe-launch`.

---

## Changelog

| Date | Note |
|------|------|
| 2026-08-03 | Initial catalog from full CLI command audit + libvaxis tiering discussion |
| 2026-08-03 | ISS-ALLOW-02 shipped (allowlist empty/footer/count/detail polish); ISS-DENY-01 progressive What now hierarchy (run + formatDenyNextSteps + replay callout) |
