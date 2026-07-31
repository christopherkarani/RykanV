# P05 — Plugin Security and Compatibility

## Summary

This phase validated the ryk plugin surface, Codex plugin, and Claude Code plugin for security correctness, compatibility, secret safety, documentation honesty, and separate-workstream non-regression.

All plugin security tests pass. Plugin artifacts are safe to package. P06 is safe to start.

---

## Tests Added

### New Test File

```
tests/phase38_plugin_security_and_compatibility.zig
```

This file contains 39 tests across 13 categories:

1. **Plugin fixture completeness** (2 tests)
   - All 8 Codex fixtures present
   - All 8 Claude fixtures present

2. **Codex hook behavior with fake payloads** (5 tests)
   - SessionStart returns valid allow JSON
   - UserPromptSubmit with fake secret returns warn
   - PreToolUse safe command returns allow
   - PreToolUse dangerous command returns block/warn/ask
   - PreToolUse protected file write returns block/ask/warn

3. **Claude hook behavior with fake payloads** (5 tests)
   - Same coverage as Codex, adapted for Claude host

4. **Hook CI mode** (2 tests)
   - Codex CI mode never returns ask
   - Claude CI mode never returns ask

5. **orca decide behavior** (5 tests)
   - Safe command returns allow JSON
   - Dangerous command returns block JSON
   - File write to protected path returns block/ask/warn
   - Prompt with fake secret returns warn/block
   - Tool returns valid JSON

6. **Invalid input handling** (6 tests)
   - Invalid JSON to decide
   - Invalid JSON to hook codex
   - Invalid JSON to hook claude
   - Unknown host in payload
   - Unknown event in payload
   - Unknown decision kind

7. **Oversized input handling** (2 tests)
   - Codex hook rejects >256 KiB payload safely
   - Claude hook rejects >256 KiB payload safely

8. **Secret safety scan** (3 tests)
   - No fake secret leaks outside fixtures
   - Generated hook responses do not contain fake secret
   - No obvious real secret patterns in plugin files

9. **Documentation overclaim checks** (4 tests)
   - Codex README does not claim perfect sandboxing
   - Claude README does not claim perfect sandboxing
   - Docs include strongest protection warning
   - Docs state no MCP server behavior and no drone features

10. **Separate workstream non-regression** (4 tests)
    - No drone skill in Codex plugin
    - No drone skill in Claude plugin
    - Plugin hooks do not reference drone commands
    - Plugin docs do not include drone demos

11. **Plugin manifest validation** (3 tests)
    - Codex manifest references skills and hooks
    - Claude manifest references skills and hooks
    - Claude marketplace points to plugin directory

12. **Missing required fields** (3 tests)
    - Missing version field rejected
    - Missing host field rejected
    - Missing JSON payload rejected

13. **Hook response validity** (2 tests)
    - All Codex hook responses are valid JSON with required fields
    - All Claude hook responses are valid JSON with required fields

### Existing Test Files (Updated)

```
tests/phase36_codex_plugin.zig         — updated fake secret value
tests/phase37_claude_plugin.zig        — updated fake secret value
```

### Fixture Files (Updated)

```
tests/plugin-fixtures/codex/user_prompt_submit_secret.json
tests/plugin-fixtures/claude/user_prompt_submit_secret.json
```

Updated fake secret from `fake_p02_secret_value` to `fake_p05_secret_value`.

---

## Tests Run

### Automated Tests

```bash
zig build
zig build test
```

Results:
- 545 tests passed
- 6 skipped (host-not-installed conditions)
- 0 failed
- All existing ryk tests pass
- All existing Edge/drone tests pass

### Manual Hook Verification

```bash
# Codex hooks
cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json \
  | ./zig-out/bin/ryk hook codex PreToolUse
  → decision: allow ✓

cat tests/plugin-fixtures/codex/pre_tool_use_command_dangerous.json \
  | ./zig-out/bin/ryk hook codex PreToolUse
  → decision: block ✓

cat tests/plugin-fixtures/codex/user_prompt_submit_secret.json \
  | ./zig-out/bin/ryk hook codex UserPromptSubmit
  → decision: warn, redactions present ✓

# Claude hooks
cat tests/plugin-fixtures/claude/pre_tool_use_command_safe.json \
  | ./zig-out/bin/ryk hook claude PreToolUse
  → decision: allow ✓

cat tests/plugin-fixtures/claude/pre_tool_use_command_dangerous.json \
  | ./zig-out/bin/ryk hook claude PreToolUse
  → decision: block ✓

cat tests/plugin-fixtures/claude/user_prompt_submit_secret.json \
  | ./zig-out/bin/ryk hook claude UserPromptSubmit
  → decision: warn, redactions present ✓
```

### ryk decide Verification

```bash
./zig-out/bin/ryk decide command --json '{"version":1,"host":"codex","command":"git status","mode":"strict"}'
  → decision: allow ✓

./zig-out/bin/ryk decide command --json '{"version":1,"host":"codex","command":"rm -rf /","mode":"strict"}'
  → decision: block ✓

./zig-out/bin/ryk decide prompt --json '{"version":1,"host":"codex","prompt":"fake_p05_secret_value","mode":"strict"}'
  → decision: block (prompt mode default-deny) ✓

./zig-out/bin/ryk decide command --json '{not json'
  → Exit code 1, "invalid JSON (SyntaxError)" ✓
```

### Plugin Doctor and Manifest

```bash
./zig-out/bin/ryk plugin doctor codex    → plugin directory: present ✓
./zig-out/bin/ryk plugin doctor claude   → plugin directory: present ✓
./zig-out/bin/ryk plugin manifest codex  → manifest: exists ✓
./zig-out/bin/ryk plugin manifest claude → manifest: exists ✓
```

### Redteam and Doctor

```bash
./zig-out/bin/ryk redteam --ci
  → 10/10 fixtures passed, 100% ✓

./zig-out/bin/ryk doctor
  → All capability checks report honestly (no overclaim) ✓
```

---

## Plugin Structure Result

| Check | Codex | Claude |
|---|---|---|
| Manifest exists | ✓ | ✓ |
| Valid JSON | ✓ | ✓ |
| Expected metadata fields | ✓ | ✓ |
| References `./skills/` | ✓ | ✓ |
| References `./hooks/hooks.json` | ✓ | ✓ |
| All 5 skills exist | ✓ | ✓ |
| Skills reference ryk commands | ✓ | ✓ |
| No drone skill | ✓ | ✓ |
| No MCP skill | ✓ | ✓ |
| Hooks config exists | ✓ | ✓ |
| Valid JSON | ✓ | ✓ |
| Calls `ryk hook <host>` | ✓ | ✓ |
| No nonexistent scripts | ✓ | ✓ |
| No absolute paths | ✓ | ✓ |
| README exists | ✓ | ✓ |
| Strongest-protection warning | ✓ | ✓ |
| No MCP/drone claim | ✓ | ✓ |
| Marketplace file valid | N/A | ✓ |
| Marketplace points to plugin | N/A | ✓ |

---

## Hook Behavior Result

| Scenario | Codex | Claude |
|---|---|---|
| Safe command allowed | ✓ | ✓ |
| Dangerous command blocked | ✓ | ✓ |
| Protected file write blocked/asked | ✓ | ✓ |
| Fake secret prompt redacted/warned | ✓ | ✓ |
| CI mode never prompts | ✓ | ✓ |
| Stdout is valid host JSON | ✓ | ✓ |
| Human logs go to stderr | ✓ | ✓ |

---

## Invalid/Oversized Input Result

| Test | Result |
|---|---|
| Invalid JSON to decide | Fails safely, exit 1, useful error ✓ |
| Invalid JSON to hook codex | Fails safely, exit 1, useful error ✓ |
| Invalid JSON to hook claude | Fails safely, exit 1, useful error ✓ |
| Oversized payload to hook codex | Rejected without panic ✓ |
| Oversized payload to hook claude | Rejected without panic ✓ |
| Missing required fields | Rejected with clear error ✓ |
| Unknown host | Rejected with host mismatch error ✓ |
| Unknown event | Rejected with event mismatch error ✓ |
| Unknown decision kind | Rejected with usage error ✓ |

---

## Secret-Safety Result

| Scope | Result |
|---|---|
| Plugin files (manifest, hooks, README) | No real secrets ✓ |
| Marketplace files | No real secrets ✓ |
| Generated hook responses | No fake secret leakage ✓ |
| Stderr output | No fake secret leakage ✓ |
| Fixture files | Contain only fake_p05_secret_value (expected) ✓ |
| Docs | No secret patterns ✓ |

---

## Docs Overclaim Result

| Doc | Perfect Sandboxing | Universal Enforcement | MCP/Drone Claims | Strongest Protection Warning | No MCP/Drone Statement |
|---|---|---|---|---|---|
| codex-plugin/README.md | Absent ✓ | Absent ✓ | Absent ✓ | Present ✓ | Present ✓ |
| claude-code-plugin/README.md | Absent ✓ | Absent ✓ | Absent ✓ | Present ✓ | Present ✓ |
| docs/integrations/codex.md | Absent ✓ | Absent ✓ | Absent ✓ | Present ✓ | Present ✓ |
| docs/integrations/claude-code.md | Absent ✓ | Absent ✓ | Absent ✓ | Present ✓ | Present ✓ |
| docs/integrations/integration-api.md | Absent ✓ | Absent ✓ | Absent ✓ | Present ✓ | N/A |

---

## Separate Workstream/Drone Non-regression Result

- Plugin files do NOT expose drone commands ✓
- Plugin docs do NOT include drone demos ✓
- Plugin docs do NOT include operational drone-control instructions ✓
- Plugin phases did NOT modify drone modules ✓
- Existing drone tests (phase26–phase35) pass ✓
- No drone skills added to plugins ✓
- No drone plugin behavior added ✓

---

## Optional Host Validation Result

- Codex binary: detected in PATH
- Claude Code binary: detected in PATH
- Both plugin doctors report host binary detected
- Plugin install preview available via `--dry-run`
- No hardware-operating tests were run (as required)

---

## Known Limitations

1. **Policy not present**: `.ryk/policy.yaml` is missing in the test workspace. Hooks and decide still function using built-in default policy.
2. **Host plugin loading**: Actual Codex/Claude Code plugin installation depends on host version and is not tested here.
3. **Marketplace**: Official marketplace availability is not yet implemented; only local example catalogs exist.
4. **Oversized payload**: The oversized payload tests verify safe rejection but do not exhaustively test all boundary conditions.
5. **Network access**: No external network access was required or used for any test.

---

## Whether P06 Is Safe to Start

**Yes. P06 (Plugin Distribution and Marketplace) is safe to start.**

All acceptance criteria are met:

- [x] Plugin security tests pass
- [x] Plugin structure tests pass
- [x] Codex fake hook tests pass
- [x] Claude fake hook tests pass
- [x] Invalid input tests pass
- [x] Oversized input tests pass
- [x] Secret scan passes
- [x] Docs overclaim check passes
- [x] No MCP behavior was added
- [x] No `.mcp.json` was added
- [x] No drone plugin behavior was added
- [x] No drone skills were added
- [x] No drone demos were added
- [x] Existing ryk tests pass
- [x] Existing Codex plugin tests pass
- [x] Existing Claude plugin tests pass
- [x] Existing drone tests pass
- [x] Plugin artifacts are safe to package
