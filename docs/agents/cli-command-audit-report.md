# ryk CLI full command analysis report

**Date:** 2026-08-03  
**Primary binary:** `/Users/chriskarani/.grok/worktrees/codingprojects-ryk/cli-ui/zig-out/bin/ryk` (workspace build, v1.2.9)  
**Comparison binary:** `~/.local/bin/ryk` (installed 2026-07-26, same semver, older surface)  
**Evidence:** `{SCRATCH}/runs/*.log`, `inventory.md`, `libvaxis-map.md`, `suggestions-smoke.log`  
**Method:** Registry + dispatcher inventory, then real process invocation per command (help + representative non-destructive argv). Interactive alt-screen paths covered by non-TUI fallbacks + source map.

**Follow-ups:**  
- Issues backlog → [`cli-ui-issues.md`](cli-ui-issues.md)  
- libvaxis UI plan (**doctor · packs · allowlist**, grill-scoped) → [`cli-ui-libvaxis-implementation-plan.md`](cli-ui-libvaxis-implementation-plan.md)

Axes per command: **Behavior** · **UI/UX** · **libvaxis** · **Suggestions / crypticness** · **Purpose / gaps**

---

## 0. Binary and help surface

| | Workspace | PATH install |
|--|-----------|--------------|
| Version banner | 1.2.9 | 1.2.9 |
| Public help | start, stop, 6 hosts, **doctor**, replay, **scan**, explain, **update** | start, stop, 6 hosts, **status**, replay, explain |
| `scan` / `update` | live | **unknown / not available** |
| `license` | unknown | listed in `help --all` |
| Daemon | unavailable (this tree) | incompatible protocol |

**Critical drift:** shipping PATH `ryk help` still teaches `status` and omits `doctor`/`scan`/`update`, while this tree’s Safe Launch set is the reverse. Analysis below is for the **workspace** binary unless noted.

---

## 1. Public Safe Launch commands

### `start`
- **Behavior:** `ryk start --help` OK. `ryk start --auto --skip-verify` exit 0: created/preserved policy, wired hosts (claude/codex/hermes/openclaw/pi/opencode), skip-verify warning. **Mutates host plugins** even with skip-verify.
- **UI/UX:** Strong guided onboarding tables; clear next-step messaging. Auto path skips interactive host multiSelect.
- **libvaxis:** Host multiSelect on TTY via `tui.prompt` (libvaxis); spinner on install steps.
- **Suggestions:** Help solid. No typo path exercised beyond dispatcher.
- **Purpose:** Primary door — high value. Gap: `--skip-verify` can still install plugins while saying “verification skipped,” which soft-claims setup without protection proof.

### `stop`
- **Behavior:** Help OK. Destructive `stop --yes` **not run** (no dry-run; would strip plugins). Alias `disable` shows same help text titled “Stop…”.
- **UI/UX:** Clear host list; confirm defaults to No (from help). No `--dry-run` unlike uninstall/plugin install.
- **libvaxis:** Confirm only on TTY.
- **Suggestions:** Good help remediation on bad flags.
- **Purpose:** Essential. Gap: no dry-run; `disable` alias undiscoverable from public help.

### Host aliases: `claude`, `codex`, `pi`, `opencode`, `openclaw`, `hermes`
- **Behavior:** Each launch rewrites to `run` with shield banner. Observed exits: claude 1 (agent sandbox EPERM noise), codex/pi/openclaw 5 (node/agent under seatbelt), opencode 1, hermes 0 (agent started with warnings). **`--help` is passed through as agent argv**, not ryk help — agents launch instead of printing ryk usage.
- **UI/UX:** Impressive SHIELD UP box + receipt + session grade. Agent failures dump raw Node stack traces after a polished banner → **jarring handoff**. stderr warns about redirected stdout under `/var/folders` (true for automation).
- **libvaxis:** No alt-screen; banner via `tui.render`; sandbox prepare spinner may use libvaxis sync.
- **Suggestions:** Missing agent → some hosts fail cryptically (exit 5 + native stack) rather than “install codex then: ryk codex”.
- **Purpose:** Core product path. Gap: host name does not support `ryk <host> --help` for ryk docs; only `ryk help <host>`.

### `doctor`
- **Behavior:** Default summary + capabilities matrix; `--json` readiness; exit 0. Reports policy valid after start, daemon unavailable, host wired table.
- **UI/UX:** Excellent tables; honest limited/unavailable caps; next steps (e.g. hermes fail-open fix). Verbose mode dense but useful.
- **libvaxis:** No interactive TUI — ANSI tables only.
- **Suggestions:** Unknown option `--verbse` → “Did you mean '--verbose'?” ✓
- **Purpose:** Correct replacement for status. Gap: still dual “daemon” framing while product is Zig-first; default is long for “am I protected?” glance.

### `replay`
- **Behavior:** `--list` / default: no sessions message with next steps (before sessions) or lists IDs. exit 0.
- **UI/UX:** Friendly empty state. `--tui` documented for alt-screen (not driven here).
- **libvaxis:** Optional `live_view` on `--tui` only.
- **Suggestions:** Help clear.
- **Purpose:** Core audit review. Gap: empty state good; no public pointer from doctor when sessions exist.

### `scan` (public on workspace only)
- **Behavior:** `--plain` / `--json` / non-TTY default all exit 0. Scored 255 sessions, 35 danger, 253 secret material findings. Clear host coverage (claude/codex/pi/opencode/grok/ryk).
- **UI/UX:** Plain scorecard is rich; findings actionable (“Do: / Why: / Next:”). Some Cmd lines truncated or “Value hidden”. Dense for 20 of 158 findings.
- **libvaxis:** **Primary consumer** — alt-screen TUI on interactive colour TTY (`scan/tui_view.zig`). Spinner uses vaxis sync seqs.
- **Suggestions:** Good help. Not on PATH install → users on old binary get “not available” with no “rebuild/upgrade” hint.
- **Purpose:** High value free forensics. Gap: PATH drift; secret-material count without severity triage can alarm without teaching.

### `explain`
- **Behavior:** `rm -rf /` → DENY tree with rule/pack/regex/span + safer alternatives. exit 0.
- **UI/UX:** Best-in-class decision tree; Suggestions section excellent. Distinct from `policy explain`.
- **libvaxis:** No — custom tree + colour, not alt-screen.
- **Suggestions:** N/A (command works). Typo at top-level: `docter` suggests doctor; shell-looking unknown tokens get explain tip.
- **Purpose:** Essential remediation. No gap beyond discoverability of vs `policy explain` (help text covers it).

### `update`
- **Behavior:** `update --check --json` → up_to_date 1.2.9. Help documents installer path / package-manager refusal.
- **UI/UX:** Clean machine + human paths.
- **libvaxis:** Confirm on real upgrade only.
- **Suggestions:** PATH binary: unknown command with no “upgrade ryk” self-hint.
- **Purpose:** Public self-update — good. Gap: not on installed PATH binary despite same version string.

### `help`
- **Behavior:** Progressive disclosure + `--all` full surface. exit 0.
- **UI/UX:** Brand banner, Common tasks, Next hints. Teaching order is coherent on workspace.
- **libvaxis:** Banner/theme only.
- **Suggestions:** Unknown help topic suggests closest command.
- **Purpose:** Essential. Gap: `help --all` still large; power users need categories (already present) but many advanced verbs lack “when to use” one-liners in root list.

---

## 2. Advanced / full-surface commands (`help --all`)

### `init`
- **Behavior:** Help OK. Creates `.orca/policy.yaml` + packs when used (start path already created policy).
- **UI/UX:** Clear presets list in help.
- **libvaxis:** No.
- **Purpose:** Needed for policy bootstrap without full start. Slight overlap with `start`.

### `env` / `--print-install-env`
- **Behavior:** Prints PATH + RYK_RESOURCE_ROOT exports. exit 0.
- **UI/UX:** Machine-only (no banner) — correct for `eval`.
- **libvaxis:** No.
- **Purpose:** Install/shell integration. Dual entry (`env` vs `--print-install-env`) is cryptic for humans but fine for installers.

### `completions`
- **Behavior:** bash/zsh scripts generated. exit 0.
- **UI/UX:** stdout-only machine.
- **Purpose:** Standard. Gap: does not complete host aliases’ agent flags (by design).

### `run`
- **Behavior:** `ryk run -- echo ok` exit 0 under OS sandbox; shield banner + “ok”. Many flags for network/secretless/OS sandbox.
- **UI/UX:** Same SHIELD UP as hosts. Flag surface is large/cryptic for day-1 (`--seatbelt-profile`, `--network-backend`).
- **libvaxis:** Spinner during prepare only.
- **Purpose:** Power entry for non-alias agents. Gap: defaults differ host-alias vs bare `run` (documented, still surprising).

### `test`
- **Behavior:** Evaluates shell_engine packs; exit 0 allow / 2 deny. Works offline.
- **UI/UX:** Minimal vs `explain` (less pedagogy).
- **Purpose:** Scriptable twin of explain. Mild **overlap** with `explain` and `decide command`.

### `allowlist` / `allow` / `unallow` / `allow-once`
- **Behavior:** list empty OK; help detailed. Permanent TOML store (Zig-native).
- **UI/UX:** Solid. Typo `allowlist ad` dumps full usage but **no “Did you mean 'add'?”**.
- **libvaxis:** No.
- **Purpose:** Day-2 policy loop. Gap: subcommand suggestions incomplete; relationship to pack rules is advanced.

### `policy`
- **Behavior:** `check` after init OK; `explain command` works; `packs` lists policy packs. Distinct from safety `packs`.
- **UI/UX:** Naming collision: `policy packs` vs `packs` confuses.
- **Purpose:** Core. Gap: **two “packs” concepts** (policy presets vs shell_engine packs).

### `diff` / `apply` / `discard`
- **Behavior:** No pending changes → friendly empty / dry-run summaries. exit 0 on workspace.
- **UI/UX:** Clear staged-change trio. Confirms danger on mutate.
- **libvaxis:** confirm widgets only.
- **Purpose:** Good if staged writes used; otherwise appear purposeless until first staged session.

### `packs`
- **Behavior:** Long paginated list of safety packs; `--json` large schema.
- **UI/UX:** Readable but **very long** first page; easy to miss enable/disable verbs.
- **libvaxis:** No browse TUI (missed opportunity vs scan).
- **Purpose:** High value for power users. Gap: not public; no libvaxis browser.

### `tools`
- **Behavior:** `classify send_email` / `packs` OK.
- **UI/UX:** Fine. Name collides with mental model of “agent tools” vs effect-class.
- **Purpose:** Effect-class discovery. Overlaps naming with removed `classify` shell classifier.

### `report`
- **Behavior:** `--session last` may exit 4 without sessions or produce report when present.
- **UI/UX:** Colour report when data exists. Overlaps `replay` purpose.
- **Purpose:** Export-oriented twin of replay. Mild **duplicate** surface.

### `version`
- **Behavior:** Human + `--json` rich (commit, daemon status, safety boundary text). exit 0.
- **UI/UX:** Clean.
- **Purpose:** Essential.

### `--version` (dispatch alias of `version`)
- **Behavior:** `ryk --version` exit 0 — same human banner as `ryk version` (v1.2.9 / stable / aarch64-macos / daemon unavailable). `ryk --version --json` exit 0 — same machine schema as `version --json` (product, version, safety_boundary, daemon block). Logs: `version-flag.log`, `version-flag-json.log`.
- **UI/UX:** Identical to `version` (branded table / JSON). No separate help surface; flag is a GNU-style synonym.
- **libvaxis:** No — same banner path as `version`.
- **Suggestions / crypticness:** Not a typo target (leading `--`). Discoverable only if users try common `--version` habit; public help lists `version` command, not the flag. Low risk.
- **Purpose:** Alias only — no independent product purpose; keep for CLI convention.

### `dashboard`
- **Behavior:** `dashboard --once` prints listen URL then **hangs until timeout** (exit 142) if no HTTP client completes the single request — smoke mode is easy to misuse.
- **UI/UX:** Minimal CLI; real UX is browser.
- **libvaxis:** No (HTTP UI).
- **Purpose:** Valid for local ops. Gap: `--once` without automatic self-request is a poor automation UX; no timeout default.

### `uninstall`
- **Behavior:** `--dry-run` exit 0, lists removals. Good safety.
- **UI/UX:** Clear steps. Contrast with `stop` lacking dry-run.
- **Purpose:** Essential.

### `plugin`
- **Behavior:** `list`, `doctor --json`, `install --dry-run` multi-host preview excellent.
- **UI/UX:** Dry-run is exemplary. Overlaps `start` wiring.
- **Suggestions:** `plugin instll` → install ✓
- **Purpose:** Power path for hosts. Gap: `start` already installs; dual paths.

### `evaluate`
- **Behavior:** Stable JSON stdin API for shell_command. exit 0 allow.
- **UI/UX:** Machine-only — correct.
- **Purpose:** Integration API (Pi etc.). Not human-facing.

### `credentials`
- **Behavior:** `check` reports brokers without secrets. exit 0.
- **UI/UX:** Sparse but safe.
- **Purpose:** Niche broker verify. Low day-1 value (advanced OK).

### `ci`
- **Behavior:** `ci check --format json` readiness. exit 0 after policy present.
- **UI/UX:** Machine-friendly.
- **Purpose:** CI gate. Overlaps doctor/redteam somewhat.

### `shutdown`
- **Behavior:** Stops daemon / cleans stale sockets when absent. exit 0.
- **UI/UX:** Quiet.
- **Purpose:** Daemon lifecycle. Less relevant if daemon unavailable by default — still valid cleanup.

### `mcp`
- **Behavior:** `list` / help for inspect|proxy|trust|manifest.
- **UI/UX:** Advanced surface; good structure.
- **Purpose:** MCP mediation. Power user only.

### `redteam`
- **Behavior:** Fixture engine self-tests; JSON provenance; high pass scores. Help warns **not workspace policy assurance**.
- **UI/UX:** Honest provenance messaging. Name “redteam” still sounds like attacking the user’s policy.
- **Purpose:** Engine QA. Gap: users may think 100% = “my project is safe.”

### `decide`
- **Behavior:** JSON policy decision API; host plugin backend. Observed exit 3 on some payloads (evaluator path). `--human` for badge UI.
- **UI/UX:** JSON default good for machines.
- **Purpose:** Plugin glue. Overlaps evaluate/explain for humans.

### `hook`
- **Behavior:** Host event JSON in/out. Empty SessionStart may fail validation (exit 2).
- **UI/UX:** Machine-only.
- **Purpose:** Integration only — not interactive CLI.

---

## 3. Hidden / removed / stub / internal / aliases

### `quickstart`, `setup` (removed-notice)
- **Behavior:** exit 2 → use `ryk start`. Clear.
- **UI/UX:** Good migration messages.
- **Purpose:** None (correctly retired). Keep for typo migration.

### `status` (removed-notice on workspace)
- **Behavior:** exit 2 → use `ryk doctor`.
- **UI/UX:** Clear on workspace.
- **Gap:** **PATH install still advertises status as live** — major UX lie for installed users.

### `history`, `precommit`, `classify`, `suggest-allowlist`, `simulate`, `rebase-recover`, `config` (stub-unavailable)
- **Behavior:** `ryk: command 'X' is not available.` exit 2. Even `--help` is unavailable.
- **UI/UX:** Honest short message — but **cryptic**: no “use replay/explain/packs instead,” no migration map.
- **libvaxis:** history had live_view code; **dead for users**.
- **Purpose:** **Serve no user purpose today** — zombie registry entries. Help registry still documents them as if they work (hidden, but `help history` may still describe daemon proxy).
- **Gap:** Highest “purposeless / gap-ridden” cluster.

### `shim` (internal)
- **Behavior:** Help describes session PATH shims. Live during `run`.
- **Purpose:** Internal — OK hidden.

### `disable` (alias of stop)
- **Behavior:** Same as stop; help uses `ryk stop` wording.
- **Purpose:** Backward compat. Undocumented on public help.

### `demo` (dispatch-only removed)
- **Behavior:** Points to `ryk explain "rm -rf /"`. Good.
- **Purpose:** Migration only.

### `license` (PATH drift only)
- **Behavior:** Workspace: unknown (no suggestion to remove from docs). PATH help still lists under Advanced.
- **Purpose:** None on this tree — **dead marketing surface on install**.

---

## 4. Cross-cutting findings

### Gaps
1. **Install vs tree drift:** PATH `ryk help` teaches `status`/`license`, omits `doctor`/`scan`/`update` that the tree considers Safe Launch. Same version number masks the gap.
2. **Hide-list stubs:** seven+ verbs return “not available” with **zero migration guidance** despite still having rich help.zig copy (hidden).
3. **`dashboard --once` hangs** without an HTTP client.
4. **Host aliases swallow `--help`** (agent argv) — no ryk usage path.
5. **`stop` lacks `--dry-run`** while uninstall/plugin have it.
6. **Daemon unavailable/incompatible** noise still appears in doctor/version for Zig-primary workflows.
7. **Dual packs** (`packs` vs `policy packs`) and dual classify (`tools classify` vs dead `classify`).

### Poor UI/UX patterns
1. Polished shield banner followed by **raw Node/Bun stack traces** on agent failure.
2. Long linear `packs` / doctor verbose without progressive collapse.
3. Scan secret-material counts can scare without prioritization.
4. `redteam` name overpromises security proof (mitigated by help text, not the name).
5. Automation under seatbelt: helpful stderr about `/var/folders` FD deny, but still exit 5 with stacks.

### No libvaxis where interactive TUI would help
| Expected browse UX | Reality |
|--------------------|---------|
| packs list/enable | Linear list only |
| doctor deep dive | Tables only |
| report / replay default | Linear; replay TUI opt-in only |
| allowlist management | Help text only |
| policy explain | Text only |

**Actual libvaxis TUI:** scan (default TTY), replay `--tui`, start multiSelect, confirms, spinners.

### Cryptic commands / missing suggestions
| Case | Result |
|------|--------|
| `docter` | Did you mean doctor? ✓ |
| `doctor --verbse` | Did you mean --verbose? ✓ |
| `policy explian` | Did you mean explain? ✓ |
| `plugin instll` | Did you mean install? ✓ |
| `packs shoe` | unknown option — **no suggestion** for subcommand `show` |
| `allowlist ad` | full usage dump — **no Did you mean add?** |
| `unknown-xyz` | no suggestion (correct) |
| `license` | unknown, no “removed” notice |
| hide-list verbs | not available — no alternatives |
| host missing binary | stack traces, not install hints |

### Commands that serve little or no user purpose (today)
| Command | Verdict |
|---------|---------|
| `history`, `precommit`, `classify`, `suggest-allowlist`, `simulate`, `rebase-recover`, `config` | **Dead stubs** — remove from registry or redirect |
| `quickstart`, `setup`, `status`, `demo` | Migration-only — OK if hidden |
| `license` (PATH) | **Advertised dead** |
| `disable` | Redundant alias |
| `report` vs `replay` | Partial duplicate |
| `test` vs `explain` | Partial duplicate for humans |
| `credentials` | Niche; fine advanced |
| `shutdown` | Niche without daemon |

---

## 5. Per-command scorecard (workspace binary)

| Command | Exit (rep.) | UX | libvaxis | Suggestions | Purpose |
|---------|-------------|-----|----------|-------------|---------|
| start | 0 | Strong | prompt/spinner | OK | Essential |
| stop | 0 help | Good | confirm | OK | Essential |
| claude…hermes | 0–5 | Banner good / agent fail poor | spinner | Weak on missing agent | Essential |
| doctor | 0 | Strong | no | Strong | Essential |
| replay | 0 | Good | opt `--tui` | OK | Essential |
| scan | 0 | Strong | **yes default** | OK | Essential |
| explain | 0 | Excellent | no | OK | Essential |
| update | 0 | Good | confirm | OK | Essential |
| help | 0 | Strong | banner | Strong | Essential |
| init | 0 | Good | no | OK | Useful |
| env | 0 | Machine | no | n/a | Useful |
| completions | 0 | Machine | no | n/a | Useful |
| run | 0 | Heavy flags | spinner | OK | Power |
| test | 0 | Minimal | no | OK | Script |
| allowlist/allow/unallow/allow-once | 0 | Good | no | Weak subcmd | Useful |
| policy | 0 | Good / name clash | no | Subcmd OK | Essential |
| diff/apply/discard | 0 | Good | confirm | OK | Niche until staged |
| packs | 0 | Long list | **no TUI** | Weak | Power |
| tools | 0 | OK | no | OK | Niche |
| report | 0/4 | OK | no | OK | Overlaps replay |
| version | 0 | Good | no | OK | Essential |
| **--version** | 0 | Same as version | no | n/a (flag alias) | Alias of version |
| dashboard | 142 timeout | Poor smoke | no | n/a | Useful if fixed |
| uninstall | 0 dry | Good | confirm | OK | Essential |
| plugin | 0 | Strong dry-run | no | Strong | Useful |
| evaluate | 0 | Machine | no | n/a | Integration |
| credentials | 0 | Sparse | no | OK | Niche |
| ci | 0 | OK | no | OK | CI |
| shutdown | 0 | Quiet | no | OK | Niche |
| mcp | 0 | Advanced | no | OK | Power |
| redteam | 0 | Honest but name | no | OK | Engine QA |
| decide | 0/3 | Machine | no | OK | Integration |
| hook | 2 empty | Machine | no | OK | Integration |
| quickstart/setup/status | 2 | Good redirect | no | n/a | Migration |
| history+hide-list | 2 | Cryptic stub | dead code | **None** | **None** |
| shim | 0 help | Internal | no | n/a | Internal |
| disable | 0 help | Alias | no | n/a | Redundant |
| demo | 2 | Good redirect | no | n/a | Migration |
| --print-install-env | 0 | Machine | no | n/a | Internal |
| license | 2 | Unknown | no | **None** | **None (drift)** |

---

## 6. Recommendations (analysis only — not implemented)

1. **Ship the workspace Safe Launch surface** (doctor/scan/update; drop status/license from install help) under a version users can trust.
2. **Replace hide-list stubs** with removed-notice redirects (`history` → `replay`, `classify` → `explain`/`tools`, etc.) or delete registry entries.
3. **Host launch:** treat `--help`/`-h` before rewrite as ryk help; improve missing-binary errors.
4. **Subcommand suggester** for packs/allowlist (show/add).
5. **libvaxis browse** for packs (and optionally replay default) to match scan investment.
6. **`dashboard --once`:** self-request or idle timeout with exit 0.
7. **`stop --dry-run`.**
8. Collapse or clearly hierarchy **report vs replay**, **test vs explain**, **packs vs policy packs**.

---

## 7. Evidence index

| Artifact | Path |
|----------|------|
| Inventory | `{SCRATCH}/inventory.md` |
| libvaxis map | `{SCRATCH}/libvaxis-map.md` |
| Suggestions smoke | `{SCRATCH}/suggestions-smoke.log` |
| Help / version | `{SCRATCH}/help-public.txt`, `help-all.txt`, `version.txt` |
| Per-command logs | `{SCRATCH}/runs/*.log` (≥100 captures) |
| Durable unit test | `src/cli/mod.zig` → `help registry inventory: unique names, public set, removed peers hidden` |
| Test log | `{SCRATCH}/test-inventory.log` |

---

*End of report. Every inventoried command was invoked on a real ryk process; interactive libvaxis alt-screen paths were non-TTY fallback + source-verified.*
