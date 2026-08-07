# ryk Production-Readiness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every confirmed dashboard, secret-redaction, CLI-polish, and merge-state defect from the 2026-07-12 audit without weakening fail-closed behavior or machine-output contracts.

**Architecture:** Repair the repository state first, then implement three independent vertical slices: durable/trusted dashboard backend plus its canonical Next UI, presentation-safe structured redaction, and consistent responsive CLI UX. Each slice owns focused regression tests and commits; a final integration task verifies source, packages, installed assets, and frozen contracts together.

**Tech Stack:** Zig 0.16.0 through `./scripts/zig`, TypeScript/React/Next.js 15, Node test runner, shell release scripts, Git.

## Global Constraints

- Use TDD: observe each new regression test fail before production changes, then make the minimum change and rerun it to green.
- Preserve the existing oversized Codex `PreToolUse` fix and its test.
- Resolve both conflicted plugin lockfiles to version `1.2.8`, matching their package manifests.
- Keep security-sensitive persistence unconditionally redacted and preserve hook/evaluate fail-closed semantics.
- Preserve raw, JSON, hook-protocol, generated-output, and daemon passthrough bytes unless a regression fixture explicitly changes the defective contract.
- Use no new dependencies.
- Keep session-local orchestration in `tasks/todo.md`; do not stage unrelated planning or generated artifacts.

---

### Task 1: Repair Merge State and Establish a Clean Baseline

**Files:**
- Modify: `integrations/openclaw-plugin/package-lock.json:1-18`
- Modify: `integrations/opencode-plugin/package-lock.json:1-18`
- Modify: `docs/superpowers/specs/2026-07-12-production-readiness-fixes-design.md:8-12`
- Add: `docs/superpowers/plans/2026-07-12-production-readiness-fixes.md`

**Interfaces:**
- Consumes: plugin package manifests whose root version is `1.2.8`.
- Produces: parseable lockfiles with both root version fields set to `1.2.8` and a repository that Git can commit.

- [ ] **Step 1: Record the failing merge-state check**

Run:

```bash
git diff --check
```

Expected: FAIL and report conflict markers in both plugin lockfiles.

- [ ] **Step 2: Resolve only the version conflicts**

Make the beginning of the OpenClaw lockfile exactly:

```json
{
  "name": "ryk-openclaw-plugin",
  "version": "1.2.8",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "ryk-openclaw-plugin",
      "version": "1.2.8",
```

Keep all dependency resolutions unchanged.

Make the OpenCode lockfile identical in shape with both name fields set to `ryk-opencode-plugin` and both version fields set to `1.2.8`.

- [ ] **Step 3: Verify lockfiles and package parity**

Run:

```bash
jq -e '.version == "1.2.8" and .packages[""].version == "1.2.8"' integrations/openclaw-plugin/package-lock.json integrations/opencode-plugin/package-lock.json
npm test --prefix integrations/openclaw-plugin
npm test --prefix integrations/opencode-plugin
```

Expected: both `jq` checks and both plugin test suites exit 0.

- [ ] **Step 4: Commit the repaired baseline and approved planning artifacts**

```bash
git add integrations/openclaw-plugin/package-lock.json integrations/opencode-plugin/package-lock.json docs/superpowers/specs/2026-07-12-production-readiness-fixes-design.md docs/superpowers/plans/2026-07-12-production-readiness-fixes.md
git commit -m "chore: resolve plugin release lockfiles"
```

### Task 2: Make Dashboard Resources Trusted and Aggregation Durable

**Files:**
- Modify: `src/cli/dashboard.zig`
- Modify: `src/cli/feed_writer.zig`
- Modify: `src/dashboard/aggregate.zig`
- Modify: `src/dashboard/mod.zig`
- Modify: `src/core/limits.zig` only if a named feed-size constant is required
- Test: inline Zig tests in the files above and `tests/phase2510_gui_audit_feed.zig`

**Interfaces:**
- Consumes: `RYK_RESOURCE_ROOT`, executable/install resource discovery, global `events.jsonl`, workspace registry, audit sessions.
- Produces: `resolveDashboardDistDirTrusted(...)`, bounded tolerant feed loading with health metadata, correctly limited/sorted/enriched dashboard JSON.

- [ ] **Step 1: Add failing trusted-resource tests**

Add tests proving a workspace-local `ryk-dashboard-ui/dist` is ignored unless it is the explicit trusted resource root, while an explicit installed resource root remains loadable. Run:

```bash
./scripts/zig build test-fast
```

Expected: new resolver assertion fails because workspace assets currently win.

- [ ] **Step 2: Implement trusted resolution**

Replace workspace-first resolution with a helper shaped as:

```zig
fn resolveDashboardDistDirTrusted(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const root = try resource_root.resolveTrustedResourceRoot(io, allocator);
    defer allocator.free(root);
    return requireDashboardIndex(io, allocator, root, installed_ui_dir);
}
```

Use the existing explicit `RYK_RESOURCE_ROOT` and executable-relative install mechanisms; do not accept selected workspace/current-directory fallback for served code.

- [ ] **Step 3: Add failing malformed, oversized, and limit tests**

Cover a truncated final line, a malformed middle line, history larger than the previous 64 MiB whole-file read, `denied_only` with `max_count = 2`, more session directories than the limit, and a filesystem session enriched by a matching feed record. Expected failures: empty/error feeds, excess blocked actions, missing newest session, and `host:null`.

- [ ] **Step 4: Implement bounded tolerant reads and rotation**

Introduce explicit results:

```zig
pub const FeedLoadHealth = enum { healthy, degraded };
pub const FeedLoadResult = struct {
    records: []LoadedFeedRecord,
    health: FeedLoadHealth,
    skipped_lines: usize,
};
```

Read a bounded tail, skip invalid individual records, rotate under the existing global write lock when the active file exceeds a named cap, retain one rotated generation, and preserve newest records. Ensure all allocations and skipped records are freed.

- [ ] **Step 5: Correct aggregation order and enrichment**

Gather session candidates across each workspace, merge feed metadata by `(workspace_root, session_id)`, sort newest-first, then truncate. Stop `writeGlobalFeedJson` once `written == max_count`, including denied-only paths. Add feed health and skipped-line counts to machine status JSON.

- [ ] **Step 6: Run focused and broad Zig gates**

```bash
./scripts/zig build
./scripts/zig build test-fast
```

Expected: exit 0, including all new dashboard/feed tests.

- [ ] **Step 7: Commit**

```bash
git add src/cli/dashboard.zig src/cli/feed_writer.zig src/dashboard/aggregate.zig src/dashboard/mod.zig src/core/limits.zig tests/phase2510_gui_audit_feed.zig
git commit -m "fix(dashboard): trust assets and harden aggregation"
```

### Task 3: Bring the Shipped Next Dashboard to Machine-Wide Parity

**Files:**
- Modify: `ryk-dashboard-ui/app/lib/types.ts`
- Modify: `ryk-dashboard-ui/app/lib/nav.ts`
- Modify: `ryk-dashboard-ui/app/page.tsx`
- Modify: `ryk-dashboard-ui/app/activity/page.tsx`
- Modify: `ryk-dashboard-ui/app/components/TopNav.tsx`
- Modify or create: dashboard UI tests under `ryk-dashboard-ui/`
- Modify: `scripts/install-layout-smoke-test.sh`

**Interfaces:**
- Consumes: status fields `mode`, `workspace_root`, `workspaces`, `sessions`, `blocked_actions`, `feed_health`, and `feed_skipped_lines`.
- Produces: `sessionKey(session) = workspace_root + "\u0000" + id`, mode-aware navigation, workspace/host activity rendering, packaged Next artifact assertions.

- [ ] **Step 1: Add failing UI contract tests**

Tests must assert:

```ts
expect(sessionKey({ id: "same", workspace_root: "/a" })).not.toBe(
  sessionKey({ id: "same", workspace_root: "/b" }),
);
expect(visibleNavigation("machine")).not.toContain("Policy");
```

Also assert workspace/host fields render and degraded-feed messaging is visible. Run `npm test` or the repository's declared UI test command and observe failures.

- [ ] **Step 2: Extend types and pure mode helpers**

Define session fields `workspace_root`, `host`, `timestamp`, `latest_decision`, and `feed_only`; blocked actions include `workspace_root` and `host`; status includes `mode`, workspace registry, and feed health. Keep mode/identity logic in exported pure helpers for deterministic tests.

- [ ] **Step 3: Implement mode-aware overview, activity, and navigation**

Machine mode renders workspace count/cards, workspace and host in session/timeline rows, composite selection keys, and only global-safe navigation. Workspace pages render an actionable “select a workspace” state if reached without a workspace. Workspace mode preserves policy and secretless functionality.

- [ ] **Step 4: Verify built and installed artifacts**

```bash
npm run build --prefix ryk-dashboard-ui
RYK_RELEASE_PRODUCT=host RYK_DIST_DIR=/tmp/ryk-production-readiness-release ./scripts/build-release.sh
RYK_DIST_DIR=/tmp/ryk-production-readiness-release ./scripts/install-layout-smoke-test.sh
```

Expected: build and smoke exit 0; the packaged `ryk-dashboard-ui/dist` contains machine-mode workspace and composite-session markers.

- [ ] **Step 5: Commit**

```bash
git add ryk-dashboard-ui scripts/install-layout-smoke-test.sh
git commit -m "fix(dashboard): ship machine-wide operator UI"
```

### Task 4: Redact Presentation Boundaries and Structured Secrets

**Files:**
- Modify: `src/audit/redact_bridge.zig`
- Modify: `src/cli/hook.zig`
- Modify: `src/cli/run.zig`
- Modify: `src/intercept/commands.zig`
- Modify: `src/policy/validate.zig`
- Modify: `docs/policy.md` or the existing audit-policy documentation owning `audit.redact_secrets`
- Test: inline Zig tests and `tests/phase38_plugin_security_and_compatibility.zig`

**Interfaces:**
- Consumes: untrusted daemon strings and original argv.
- Produces: `redactAlloc(allocator, value) ![]u8`, `displayArgvRedactedAlloc(...) ![]u8`, and policy validation that rejects `audit.redact_secrets: false`.

- [ ] **Step 1: Add failing structured-redaction tests**

Cover authorization headers, `--password value`, `--token=value`, JSON `{"password":"correct horse battery staple"}`, case-varied provider prefixes, single/double percent encodings, bounded base64, and bounded hex. Assert raw sentinel values never appear and benign strings remain unchanged.

- [ ] **Step 2: Implement bounded structured redaction**

Use case-insensitive sensitive-key classification, bounded token scanning, and at most two decode passes. Return owned output only when partial replacement is needed; never log decoder failures or raw input. Do not recursively decode without explicit depth and byte limits.

- [ ] **Step 3: Add failing hook and human-output leak tests**

Inject daemon explanation/reason/error strings and argv containing unique sentinel secrets. Assert hook JSON, approval prompt, denial panel, and remediation text exclude each sentinel while evaluation receives the original argv.

- [ ] **Step 4: Apply redaction only at presentation boundaries**

Redact daemon-derived hook fields before `writeHookResponse`. Build one redacted display command for prompt/deny/remediation rendering, while passing the original argv to classification, hashing, approval, and process execution.

- [ ] **Step 5: Make policy semantics explicit**

Add a failing policy test for `audit.redact_secrets: false`, then reject it with `error.InvalidPolicy` and document that persisted secrets cannot be enabled. Existing omitted/true values must remain valid.

- [ ] **Step 6: Verify and commit**

```bash
./scripts/zig build
./scripts/zig build test-fast
git add src/audit/redact_bridge.zig src/cli/hook.zig src/cli/run.zig src/intercept/commands.zig src/policy/validate.zig tests/phase38_plugin_security_and_compatibility.zig docs
git commit -m "fix(security): redact all presentation boundaries"
```

### Task 5: Finish CLI Help, Responsiveness, Accessibility, and Completions

**Files:**
- Modify: `src/cli/mod.zig`
- Modify: `src/cli/packs.zig`
- Modify: `src/cli/dashboard.zig`
- Modify: `src/cli/help.zig`
- Modify: `src/cli/completions.zig`
- Modify: `src/tui/theme.zig`
- Modify: `src/tui/render.zig`
- Add or modify: focused inline tests and human-output fixtures under `src/cli/test-fixtures/`

**Interfaces:**
- Produces: normalized global args preserving post-`--` argv, `terminalWidth(...)` bounded to a usable range, explicit Unicode capability, command-specific completion metadata, Zig-owned packs help.

- [ ] **Step 1: Add failing CLI regression tests**

Assert `packs --help` equals canonical help and contains friendly flags; `version --no-rich` works; `run -- echo --no-rich` preserves the child argument; `COLUMNS=40` caps human output; ASCII mode contains no emoji/box glyphs; dashboard typo errors suggest `--host` and `ryk help dashboard`; launch output states machine/workspace mode; completions hide `shim` and include dashboard/packs flags.

- [ ] **Step 2: Normalize global options safely**

Build a small normalized argv that removes `--no-rich` only before a literal `--`, never from raw/generated invocations or child payloads. Keep machine-output detection on the normalized command argv.

- [ ] **Step 3: Implement width and Unicode capabilities**

Parse `COLUMNS` defensively, clamp to a minimum/maximum, and pass width into banner/wrapping primitives. Model Unicode separately from color and emit ASCII brand/borders/glyphs when disabled, including non-TTY and `TERM=dumb` paths.

- [ ] **Step 4: Unify help and dashboard diagnostics**

Route packs help through `help.writeCommand`, use `suggestions.writeUnknownOption` or equivalent shared remediation for dashboard parsing, and print the selected dashboard mode after successful bind without changing `--once` or server behavior.

- [ ] **Step 5: Generate command-specific completions**

Replace the generic flag bag with public command metadata. Exclude `shim`; include `--no-rich` globally and dashboard `--machine/--workspace/--host/--port`, plus packs `--filter/--installed/--page/--page-size`.

- [ ] **Step 6: Verify frozen contracts and commit**

```bash
./scripts/zig build
./scripts/zig build test-fast
git add src/cli src/tui
git commit -m "fix(cli): complete polished human interface"
```

### Task 6: Integrate, Package, and Review the Complete Fix

**Files:**
- Modify: `tasks/todo.md` review section only
- Inspect: every file changed since the repaired baseline

**Interfaces:**
- Consumes: all preceding slices.
- Produces: verified source and release artifacts with no unresolved conflicts or identified audit regressions.

- [ ] **Step 1: Run format and repository hygiene checks**

```bash
./scripts/zig fmt --check src tests
git diff --check
git status --short
git ls-files | rg '(^planning/|^go_to_market/|^customer_pilot/|^tasks/|^reports/|^\.ryk-edge/|^\.edge/|^dist/|^dist-dry-run/|^docs/release/|^docs/orca_opencode_openclaw_plan/|node_modules/)'
```

Expected: formatting/diff checks exit 0, no unmerged entries, and only explicitly permitted tracked planning file `planning/README.md` appears in the hygiene query.

- [ ] **Step 2: Run the complete verification ladder**

```bash
./scripts/zig build
./scripts/zig build test-fast
./scripts/zig build test
npm test --prefix integrations/openclaw-plugin
npm test --prefix integrations/opencode-plugin
npm run build --prefix ryk-dashboard-ui
RYK_RELEASE_PRODUCT=host RYK_DIST_DIR=/tmp/ryk-production-readiness-release ./scripts/build-release.sh
RYK_DIST_DIR=/tmp/ryk-production-readiness-release ./scripts/install-layout-smoke-test.sh
```

Expected: every command exits 0. If the managed sandbox blocks localhost tests, rerun the identical gate with approved escalation before classifying it as environmental.

- [ ] **Step 3: Inspect the shipped artifact and requirements**

Confirm the release tar contains `ryk-dashboard-ui/dist/index.html`, machine-wide UI markers, no source-map secrets, and plugin lockfiles at `1.2.8`. Re-read the design requirement by requirement and map each one to a passing test or artifact check.

- [ ] **Step 4: Review the complete diff**

Check for raw secret fixtures, weakened fail-closed paths, unbounded allocations, resource-root regressions, stale legacy UI assertions, machine-output byte changes, unrelated edits, and generated files. Correct any finding with another RED/GREEN cycle.

- [ ] **Step 5: Record results and final commit**

Update the local `tasks/todo.md` review with exact commands, counts, and blockers. Commit only tracked production/test/docs changes:

```bash
git commit -am "chore: complete production readiness hardening"
```
