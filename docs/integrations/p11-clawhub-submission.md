# P11 — OpenClaw ClawHub Submission Deliverable

## Summary

This phase prepared and published the Orca OpenClaw plugin to ClawHub. All metadata, documentation, validation, and safety checks are complete. The plugin is now live on ClawHub as `orca-openclaw-plugin@1.1.3`.

**ClawHub submission is complete. The plugin is published.**

## Docs Added

| File | Purpose |
|------|---------|
| `docs/integrations/openclaw-clawhub.md` | ClawHub submission documentation — prerequisites, publish commands, verification, known limitations |
| `docs/integrations/openclaw-clawhub-checklist.md` | Complete readiness checklist with checkboxes for metadata, build, npm package, safety, docs, CLI, and regression |
| `docs/integrations/p11-clawhub-submission.md` | This deliverable document |

## Docs Updated

| File | Change |
|------|--------|
| `docs/integrations/openclaw.md` | Updated ClawHub section to show published status and install command |
| `integrations/openclaw-plugin/README.md` | Updated ClawHub section to show published status and install command |
| `PLUGIN_RELEASE_NOTES.md` | Updated wording: "ClawHub submission is complete" |
| `LAUNCH_PLUGINS.md` | Updated wording: "ClawHub submission is complete in P11" |
| `PLUGIN_CHANGELOG.md` | Updated OpenClaw version to 1.1.3, updated status to "published in P11" |
| `docs/integrations/plugin-compatibility.md` | Updated marketplace table: "published in P11" |

## Checklist Status

All checklist items are complete:

- [x] Metadata validation (`openclaw.plugin.json`, `package.json`)
- [x] Build validation (`npm run build` succeeds)
- [x] npm package validation (`npm pack --dry-run` succeeds)
- [x] Safety checks (no secrets, no unsafe scripts, no MCP/drone fields)
- [x] Orca CLI checks (`plugin doctor`, `manifest`, `install --dry-run`)
- [x] Hook smoke tests (safe fixture returns `allow`, dangerous returns `block`)
- [x] Cross-plugin regression tests (Codex, Claude Code, OpenCode all pass)
- [x] Release notes are honest
- [x] ClawHub CLI dry-run (succeeded with v0.12.3)
- [x] Real ClawHub publication (completed)

## npm Package Validation Status

**Result: Passed**

```bash
npm run build --prefix integrations/openclaw-plugin
npm pack --dry-run ./integrations/openclaw-plugin
```

Output:
- `dist/index.js` — 6.0 kB ✓
- `dist/index.d.ts` — 654 B ✓
- `dist/index.d.ts.map` — 814 B ✓
- `package.json` — 1.0 kB ✓
- `openclaw.plugin.json` — 242 B ✓
- `README.md` — 4.6 kB ✓
- Package size: 4.6 kB (tarball)
- Unpacked size: 13.3 kB
- Total files: 6

Package excludes:
- `node_modules` ✓
- `src/` (source not shipped) ✓
- Planning files ✓
- Drone files ✓
- `.mcp.json` ✓
- Secrets ✓
- Temporary files ✓
- Zig build artifacts ✓

## ClawHub Dry-Run Status

**Result: Passed (after upgrading CLI from v0.7.0 to v0.12.3)**

The initial installed ClawHub CLI (v0.7.0) did not support `--dry-run` or `--family` flags. After upgrading to v0.12.3:

```bash
clawhub package publish ./integrations/openclaw-plugin --family code-plugin --dry-run --json
```

Output:
```json
{
  "source": "github:christopherkarani/rykan@p11-clawhub-submission-prep:integrations/openclaw-plugin",
  "name": "orca-openclaw-plugin",
  "displayName": "Orca",
  "family": "code-plugin",
  "version": "1.1.3",
  "commit": "fb3828b0475dfe3847a7d429e962eb396e247d51",
  "files": 6,
  "totalBytes": 4732
}
```

## Publish Status

**Published.**

The plugin was published with:

```bash
clawhub package publish \
  ./integrations/openclaw-plugin \
  --family code-plugin \
  --name "orca-openclaw-plugin" \
  --display-name "Orca" \
  --version "1.1.3" \
  --changelog "Initial ClawHub submission..." \
  --tags "security,guardrails,ai-agents,policy,audit,latest"
```

Result: `✔ OK. Published orca-openclaw-plugin@1.1.3 (rd793zsj39hs3983na8h3pgv0s86f1yk)`

The install command is:

```bash
openclaw plugins install clawhub:orca-openclaw-plugin
```

**Note:** The `clawhub:` install protocol requires a recent OpenClaw version. Older versions may fall back to local path or npm install.

## OpenClaw Local Validation Result

**Attempted: Yes**

```bash
openclaw plugins install ./integrations/openclaw-plugin
```

Result: Install succeeded (plugin copied to `~/.openclaw/extensions/orca/`).

```bash
openclaw plugins list --json
```

Result: Plugin appears in list with `id: "orca"`, `version: "1.1.3"`, `enabled: true`.

**Note:** ~~A runtime error was observed during plugin registration: `TypeError: Cannot read properties of undefined (reading 'on')`. This appears to be due to OpenClaw loading the TypeScript source directly from the local path install, and the context shape may differ from the compiled runtime expectations. This is a known limitation of local path installs and does not affect the npm package or ClawHub distribution, which use the compiled `dist/index.js`.~~

**Fixed:** The plugin entrypoint was updated to use the correct OpenClaw SDK pattern (`api.on(...)` instead of `context.hooks.on(...)`). Local install validation confirms the plugin now loads successfully with `status: "loaded"`.

## Tests Run

### Zig tests

```bash
zig build test
```

Result: **All tests pass.**

### Plugin smoke tests

```bash
cat tests/plugin-fixtures/openclaw/tool_command_safe.json | ./zig-out/bin/orca hook openclaw tool.before
# Result: allow ✓

cat tests/plugin-fixtures/openclaw/tool_command_dangerous.json | ./zig-out/bin/orca hook openclaw tool.before
# Result: block ✓
```

### Cross-plugin regression tests

```bash
cat tests/plugin-fixtures/codex/pre_tool_use_command_dangerous.json | ./zig-out/bin/orca hook codex PreToolUse
# Result: block ✓

cat tests/plugin-fixtures/claude/pre_tool_use_command_dangerous.json | ./zig-out/bin/orca hook claude PreToolUse
# Result: block ✓

cat tests/plugin-fixtures/opencode/tool_execute_before_command_dangerous.json | ./zig-out/bin/orca hook opencode tool.execute.before
# Result: block ✓
```

### Redteam

```bash
./zig-out/bin/orca redteam --ci
```

Result: **10/10 fixtures passed (100%)** ✓

### Orca plugin commands

```bash
./zig-out/bin/orca plugin doctor openclaw      # passed ✓
./zig-out/bin/orca plugin manifest openclaw    # passed ✓
./zig-out/bin/orca plugin install openclaw --dry-run  # passed ✓
```

## Known Limitations

1. **ClawHub CLI v0.7.0 lacked `--dry-run`.** Upgrading to v0.12.3+ is required for dry-run validation.
2. **`clawhub:` install protocol requires recent OpenClaw.** Older OpenClaw versions may not support `clawhub:` installs. Use local path or npm install as fallback.
3. **Local path install may show runtime warnings.** OpenClaw loads TypeScript source directly from local paths, which may cause context-shape mismatches. The npm/ClawHub distribution uses compiled `dist/index.js`.
4. **Hooks are advisory for informational events.** Blocking depends on OpenClaw honoring thrown errors.
5. **The strongest protection remains `orca openclaw`.**

## Manual Actions Already Completed

1. ✅ **Authenticated with ClawHub:** `clawhub login` completed as @christopherkarani.
2. ✅ **Upgraded ClawHub CLI:** `npm install -g clawhub@latest` (v0.7.0 → v0.12.3).
3. ✅ **Added compatibility metadata:** `openclaw.compat` and `openclaw.build` fields added to `package.json`.
4. ✅ **Added SKILL.md:** Required by ClawHub for skill descriptions.
5. ✅ **Ran dry-run:** `clawhub package publish ... --dry-run --json` succeeded.
6. ✅ **Published:** `clawhub package publish ...` completed successfully.

## Remaining Manual Actions

- **Monitor scan status:** ClawHub scan is currently `pending`. Check `clawhub package inspect orca-openclaw-plugin` for updates.
- **Verify install on newer OpenClaw:** The `clawhub:` protocol requires a recent OpenClaw version. Test `openclaw plugins install clawhub:orca-openclaw-plugin` when a compatible version is available.

## Whether ClawHub Submission Is Complete

**Yes.** The Orca OpenClaw plugin has been successfully published to ClawHub:

- All metadata validates (`openclaw.plugin.json`, `package.json`).
- Build output exists (`dist/index.js`, `dist/index.d.ts`).
- npm package is clean and minimal (`npm pack --dry-run` passes).
- No secrets, no unsafe scripts, no MCP behavior, no drone behavior.
- Orca CLI integration works (doctor, manifest, install dry-run, hooks).
- All existing tests pass (Zig tests, smoke tests, redteam).
- ClawHub dry-run passed (after CLI upgrade).
- ClawHub publication confirmed: `orca-openclaw-plugin@1.1.3`.
- Documentation is complete and updated to reflect published status.

## Files Changed

- `docs/integrations/openclaw-clawhub.md` — **new**
- `docs/integrations/openclaw-clawhub-checklist.md` — **new**
- `docs/integrations/p11-clawhub-submission.md` — **new**
- `docs/integrations/openclaw.md` — updated ClawHub section to show published status
- `integrations/openclaw-plugin/README.md` — updated ClawHub section to show published status
- `integrations/openclaw-plugin/SKILL.md` — **new** (required by ClawHub)
- `integrations/openclaw-plugin/package.json` — added `openclaw.compat` and `openclaw.build` metadata
- `PLUGIN_RELEASE_NOTES.md` — updated ClawHub status wording
- `LAUNCH_PLUGINS.md` — updated ClawHub status wording
- `PLUGIN_CHANGELOG.md` — updated OpenClaw version and status
- `docs/integrations/plugin-compatibility.md` — updated marketplace status
