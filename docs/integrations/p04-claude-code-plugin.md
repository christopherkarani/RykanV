# P04 — Claude Code Plugin Handoff

> Phase: P04
> Date: 2026-05-09
> Status: Complete

---

## Summary

Built the ryk Claude Code plugin package under `integrations/claude-code-plugin/` and the local marketplace catalog under `integrations/claude-marketplace/`. The plugin includes a manifest, five skills, a hooks configuration, README, marketplace files, integration documentation, and tests. All verification commands pass.

---

## Files Added

```text
integrations/claude-code-plugin/
  .claude-plugin/plugin.json
  skills/doctor/SKILL.md
  skills/init/SKILL.md
  skills/protect/SKILL.md
  skills/redteam/SKILL.md
  skills/replay/SKILL.md
  hooks/hooks.json
  README.md

integrations/claude-marketplace/
  .claude-plugin/marketplace.json
  README.md

docs/integrations/claude-code.md
tests/phase37_claude_plugin.zig
```

## Files Modified

```text
src/cli/plugin.zig
  - Updated test "plugin manifest claude reports expected path" to expect "exists"
    instead of "missing" now that the manifest file is present.

build.zig
  - Added phase36_codex_plugin_tests and phase37_claude_plugin_tests to the test suite.
```

---

## Skills Added

| Skill | Purpose |
|-------|---------|
| `doctor` | Check ryk installation, policy status, host integration status, and plugin readiness |
| `init` | Create or repair a ryk policy for the current repository |
| `protect` | Explain how to run the current Claude Code workflow under ryk protection |
| `redteam` | Run ryk red-team fixtures and summarize results |
| `replay` | Show and explain the latest ryk session replay |

No drone skills were added.
No MCP skills were added.

---

## Hooks Added

`integrations/claude-code-plugin/hooks/hooks.json` registers hooks for:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `SessionEnd`

Each hook calls `ryk hook claude <event>` with a JSON payload on stdin.

Note: Claude Code uses `SessionEnd` instead of Codex's `Stop` event.

---

## Marketplace Status

A local marketplace catalog was added at:

```text
integrations/claude-marketplace/.claude-plugin/marketplace.json
```

This is a documented example only. Official marketplace availability is not yet implemented.

---

## Tests Run

### Plugin Structure Tests

```bash
zig test tests/phase37_claude_plugin.zig
```

Result: **27/27 passed**

Tests cover:
- Manifest exists, valid JSON, expected fields
- Skills exist, non-empty, reference real ryk commands
- No drone skill, no MCP skill
- Hooks exist, valid JSON, call `ryk hook claude`
- No nonexistent scripts, no absolute paths
- Marketplace file valid JSON, points to claude plugin directory
- No fake secrets in plugin files
- README includes strongest-protection warning
- README states no MCP server behavior and no drone plugin features
- Docs do not claim official marketplace availability
- Docs do not claim MCP support
- Docs do not claim drone plugin support
- Hook fixtures still present

```bash
zig test tests/phase36_codex_plugin.zig
```

Result: **23/23 passed** (non-regression)

### Build Tests

```bash
zig build
```

Result: **Pass**

```bash
zig build test
```

Result: Pre-existing MCP proxy stdin hang still occurs. The phase36 and phase37 tests were added to build.zig and will run as part of the suite when the hang is resolved. Individual test binaries pass when run directly.

### Verification Commands

```bash
./zig-out/bin/ryk plugin doctor claude
```
Result: Pass. Reports Claude Code plugin directory as "present".

```bash
./zig-out/bin/ryk plugin manifest claude
```
Result: Pass. Reports manifest as "exists".

```bash
cat tests/plugin-fixtures/claude/pre_tool_use_command_safe.json \
  | ./zig-out/bin/ryk hook claude PreToolUse
```
Result: Pass. Returns `allow` decision.

```bash
cat tests/plugin-fixtures/claude/user_prompt_submit_secret.json \
  | ./zig-out/bin/ryk hook claude UserPromptSubmit
```
Result: Pass. Returns `warn` decision with redaction.

```bash
./zig-out/bin/ryk decide command --json '{"version":1,"host":"claude","command":"git status","mode":"strict"}'
```
Result: Pass. Returns `allow` decision.

```bash
./zig-out/bin/ryk plugin doctor codex
```
Result: Pass. Non-regression verified.

```bash
./zig-out/bin/ryk plugin manifest codex
```
Result: Pass. Non-regression verified.

```bash
./zig-out/bin/ryk redteam --ci
```
Result: Pass. 10/10 fixtures passed, 100%.

```bash
./zig-out/bin/ryk doctor
```
Result: Pass.

---

## Secret-Safety Result

- No raw secrets in plugin files.
- No raw secrets in generated hook outputs.
- No raw secrets in docs.
- No fake secret test values in plugin files.
- No obvious secret-like placeholders in plugin files.

---

## Separate Workstream / Drone Non-Regression Result

- No drone skills were added.
- No drone demos were added.
- No drone docs were added.
- No drone commands were exposed.
- The `ryk plugin doctor` command still detects the separate drone workstream and reports safety mode active.
- Existing Edge tests were not modified.
- `edge redteam --ci` was not run because it is a separate binary and the plugin plan does not require it.

---

## Known Limitations

- Hooks are advisory; enforcement depends on Claude Code host support.
- The strongest protection remains `ryk claude`.
- Plugin installation is preview/dry-run by default.
- Official marketplace availability is not yet implemented.
- The `ryk plugin install` command does not yet perform actual host plugin installation.
- The marketplace catalog uses a relative path (`../claude-code-plugin`) which may need adjustment depending on the Claude Code version.

---

## Security Notes

- The ryk remains the source of truth.
- The plugin does not duplicate policy logic.
- Hook stdout is host-valid JSON.
- Human logs go to stderr.
- CI mode never prompts.
- The plugin does not claim stronger enforcement than Claude Code hooks support.
- No MCP config was added.
- No drone plugin features were added.

---

## Whether P05 Is Safe to Start

**Yes.** P05 (Plugin Security and Compatibility) is safe to start.

Rationale:
- P01 commands (`ryk plugin doctor`, `ryk plugin manifest`, `ryk plugin install`) still work.
- P02 commands (`ryk decide`, `ryk hook`) still work.
- P03 Codex plugin files/tests still work.
- The Claude Code plugin does not conflict with the Codex plugin.
- No MCP config was added.
- No drone features were added.
- All tests pass or fail for pre-existing reasons only.

---

*End of P04 handoff.*
