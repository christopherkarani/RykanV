# Plan: doctor · packs · allowlist UI (libvaxis)

**Status:** ready to implement (scoped via grill 2026-08-03)  
**Supersedes:** broad “all tiers” program — **out of scope** unless reopened  
**Source:** CLI audit + grill decisions  
**Related:** [`cli-ui-issues.md`](cli-ui-issues.md)

---

## 0. Decision freeze (grill)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Program focus | **doctor**, **packs**, **allowlist** only |
| 2 | TTY defaults | **C:** packs + allowlist → **default TUI** on colour TTY; doctor → **linear default**, deep-dive via **`--tui`** |
| 3 | Mutations in TUI | **B:** enable/disable/remove with **confirm default No**; add-with-reason stays **argv** (not full CRUD) |
| 4 | Safe Launch visibility | **B:** promote **packs** and **allowlist** to **public** |
| 5 | Architecture | **A:** **one shared browse kit** (scan-compatible keys) |
| 6 | allow-once | **A:** **out of TUI** — argv only |
| 7 | Ship order | **W0 kit → packs → allowlist → doctor** |
| 8 | Public help order | **A+D:** … **doctor → packs → allowlist** …; **`allow` / `unallow` stay advanced** |
| 9 | Packs first screen | **B:** **enabled + baseline** first; toggle to all / search |
| 10 | Definition of done | **B:** TUI + help + **on-verb DX** (subcommand suggestions; doctor next-steps → packs/allowlist) |
| 11 | Doctor TUI content | **A + data parity:** panes Summary · Hosts · Capabilities · Next steps; same facts as linear; packs status as **summary line**, not 5th pane |
| 12 | Keys | **A:** match **scan** nav (`↑↓/jk`, `g/G`, `q/Esc`); domain actions on free keys; footer shows context |
| 13 | Allowlist empty / layers | **D:** show **project + user** layers; empty teaches `ryk allow …`; status line = write target |
| 14 | Success (default) | Manual TTY checklist + JSON/plain regressions green; public help lists packs/allowlist; suggestions work for packs/allowlist |

**Post-ship note (PR #101 tip):** packs TUI matches freeze #3/#9 (enabled+baseline first; disable confirms default No / baseline danger gate). Prefer code + this freeze over session diaries in issues.

**Explicitly out of this program:** replay default TUI, host failure panel, scan polish, plugin matrix, report merge, dashboard `--once`, install-channel drift ship, hide-list redirects (except if required for help inventory tests), Tier 3 explain/policy TUIs, allow-once TUI, `allow`/`unallow` public promotion.

---

## 1. Goal

Make the **day-2 protection loop** feel like one product:

1. **`ryk doctor`** — am I set up? (glance linear; deep-dive TUI)  
2. **`ryk packs`** — what’s on / turn packs on or off (default browse TUI)  
3. **`ryk allowlist`** — permanent exceptions (default browse TUI)

Machine and script paths stay frozen (`--json`, pipes, non-TTY → linear).

---

## 2. Principles

1. **TTY-first, machine-frozen** — no alt-screen on non-TTY, `--json`, `--plain`, `--no-rich`, CI pipes.  
2. **One browse kit** — list / detail / actions; doctor is sections on the same chassis.  
3. **Scan key parity** — navigation matches `scan` TUI; action keys documented in footer.  
4. **Confirm default No** for any TUI mutation.  
5. **No raw secrets** in any detail pane.  
6. **Shared builders** — TUI lines and `--json` come from the same data, not two truths.  
7. **Test floor** — pure frame/list tests; Tty loops comptime-gated; no flaky alt-screen unit tests.

---

## 3. Wave 0 — Shared browse kit

**Paths:** `src/tui/*`, extract from `src/scan/tui_view.zig` without behaviour change to scan  
**Outcome:** reusable kit used by packs → allowlist → doctor

| ID | Work | Acceptance |
|----|------|------------|
| W0.1 | Document browse contract (keys, TTY-only, footer actions, Esc/q restore) | Docs in `tui/mod.zig` or `browse.zig` |
| W0.2 | `tui/browse.zig` (or deepen `live_view`): list + detail + action bar + optional filter mode | Unit tests for frame layout / selection index |
| W0.3 | `shouldEnterTui(io, argv)` — central gate for non-TTY / json / plain / no-rich | Used by packs, allowlist, doctor |
| W0.4 | Scan still green: `scan --plain` / `--json` / existing tests | No user-visible scan regression |

**Verify:** `./scripts/zig build test-lib` filters for tui/scan; manual scan TTY smoke optional.

---

## 4. Wave 1 — Packs (first product TUI)

**Paths:** `src/cli/packs.zig`, `src/cli/help.zig`, browse kit, suggestions  
**User story:** On colour TTY, bare `ryk packs` opens browse: **enabled + baseline first**; `/` search; `a` (or documented key) show all; Enter detail; **e/d** (or footer-bound keys) enable/disable with **confirm default No**; status line = project `.orca.toml` vs user config write target.

| ID | Work | Acceptance |
|----|------|------------|
| P1 | Default TUI on TTY; `--plain` linear; `--json` frozen | Non-TTY = linear list as today |
| P2 | Default filter: enabled + baseline | Toggle all; search works with ~85 packs |
| P3 | Mutate enable/disable via same code paths as CLI subcommands | Confirm cancel leaves config unchanged |
| P4 | `public = true` + Safe Launch order after doctor | Inventory/help tests updated |
| P5 | Subcommand suggestions (`show`, `enable`, …) | `packs shoe` → Did you mean `show`? |
| P6 | Help details: TUI keys, `--plain`, project vs user write | `ryk help packs` |

**Tests:** packs JSON golden; filter pure tests; enable/disable with fixture config; help public set includes packs.

---

## 5. Wave 2 — Allowlist (permanent only)

**Paths:** `src/cli/allowlist_cmd.zig`, help, browse kit, suggestions  
**User story:** On colour TTY, `ryk allowlist` / `allowlist list` opens browse with **project section then user section**; empty sections show teaching line for `ryk allow <rule> -r "…"` / `allowlist add-command`; select entry → detail; **remove** with confirm default No. **No allow-once** in TUI. **No add wizard** in v1.

| ID | Work | Acceptance |
|----|------|------------|
| A1 | Default TUI on TTY for list; `--json` frozen; `--plain` linear | |
| A2 | Dual-layer list + write-target status line | Matches existing project/user resolution |
| A3 | Remove with confirm | Cancel = no write |
| A4 | `public = true`; order after packs; **allow/unallow not public** | Help + inventory tests |
| A5 | Subcommand suggestions (`add`, `remove`, …) | `allowlist ad` → add |
| A6 | Empty-state copy only points at permanent allow path, not allow-once | |

**Tests:** list builders for dual layer; remove fixture; JSON list unchanged; public help has allowlist not allow/unallow.

---

## 6. Wave 3 — Doctor (opt-in TUI)

**Paths:** `src/cli/doctor.zig`, help, browse kit  
**User story:** Default `ryk doctor` stays **linear** (fast glance). `ryk doctor --tui` (name fixed in help) opens four panes: **Summary · Hosts · Capabilities · Next steps**. Summary includes packs/status one-liner. Next steps include **`ryk packs`** and **`ryk allowlist`**. Same facts as linear default; verbose detail via key or deeper rows without becoming a second verbose wall.

| ID | Work | Acceptance |
|----|------|------------|
| D1 | Linear default unchanged; `--json` frozen | |
| D2 | `--tui` fail-closed on non-TTY (message + use linear) | |
| D3 | Four panes; data parity with linear facts | No silent drop of fail-closed host stance |
| D4 | Next steps deep-link packs + allowlist | |
| D5 | Help documents `--tui` | |

**Tests:** doctor JSON unchanged; pane builders pure tests; “would enter tui” decision test without Tty.

---

## 7. Dependency graph

```
W0 shared browse kit (+ shouldEnterTui)
  └── W1 packs (default TUI, public, suggestions, mutate+confirm)
        └── W2 allowlist (default TUI, public, dual-layer, remove+confirm)
              └── W3 doctor --tui (linear default, 4 panes, next-steps links)
```

**PR stack:** W0 → W1 → W2 → W3  

---

## 8. Safe Launch help changes

**Public teaching suffix (illustrative):**  
`… doctor → packs → allowlist → replay → scan → explain → update`  
(Exact array: update `public_help_suffix` / `public` flags in `help.zig` + inventory unit test.)

**Common tasks:** optional one line e.g. “Tune packs / exceptions → `ryk packs` · `ryk allowlist`” — implement if root help stays scannable.

**Not public:** `allow`, `unallow`, `allow-once`.

---

## 9. Keybinding contract (shared)

| Key | Action |
|-----|--------|
| ↑↓ / j k | Move |
| g / G | Top / bottom |
| Enter | Detail / activate section |
| q / Esc | Quit (restore terminal) |
| / | Search/filter (packs; allowlist if useful) |
| Domain | Footer-defined: e.g. enable/disable/remove; doctor pane next/prev |
| c / o | Reserved scan semantics; no silent steal — hint or no-op outside scan |

---

## 10. Verification (program done)

| Gate | Check |
|------|--------|
| Unit | test-lib for tui, packs, allowlist, doctor, help inventory |
| Machine | `packs --json`, `allowlist list --json` (or existing flags), `doctor --json` unchanged contracts |
| Non-TTY | bare packs/allowlist/doctor never alt-screen; no hang |
| Manual TTY | Packs: open enabled-first, search, cancel enable, quit restore · Allowlist: dual layer empty teaching, cancel remove · Doctor: linear default, `--tui` four panes, next steps show packs/allowlist |
| Suggestions | `packs shoe`, `allowlist ad` smoke |
| Public help | `ryk help` lists packs + allowlist after doctor; not allow/unallow |

---

## 11. Risks

| Risk | Mitigation |
|------|------------|
| Safe Launch clutter | Strict one-line summaries; shortcuts stay advanced |
| Pack enable wrong layer | Status line always shows write path; confirm message repeats it |
| Browse kit breaks scan | W0 requires scan regression green before packs |
| Doctor TUI vs linear drift | Single fact builders feed both |
| Scope creep back to full tier plan | This doc is source of truth; reopen only by editing decision freeze |

---

## 12. Success definition

Program is **done** when:

1. Colour TTY: `ryk packs` and `ryk allowlist` open shared-kit TUIs with confirmed mutation model.  
2. `ryk doctor` remains excellent linear; `doctor --tui` deep-dives with next steps into packs/allowlist.  
3. Both verbs are public in the agreed order; allow/unallow remain advanced.  
4. On-verb suggestions work; JSON/plain/non-TTY paths do not regress.  
5. Manual TTY checklist in §10 passes.

---

## 13. Issue mapping (in-scope only)

| Issue | Unit |
|-------|------|
| ISS-UX-02 packs linear wall | W1 |
| ISS-UX-03 doctor no TUI | W3 |
| ISS-ALLOW-01 allowlist argv-only browse | W2 |
| ISS-UX-07 packs/allowlist suggestions | W1 P5, W2 A5 |
| ISS-NAM-01 (help clarity only, light) | help text while promoting packs |

Broader issues (drift, dead stubs, host stacks, replay, dashboard) stay in [`cli-ui-issues.md`](cli-ui-issues.md) **outside** this program.
