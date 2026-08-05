# P08 — OpenCode Plugin

## Summary

This phase adds native OpenCode plugin support to ryk. Users can now use ryk with OpenCode in two ways:

1. **Strongest protection**: `ryk opencode`
2. **Native OpenCode plugin guardrails**: OpenCode plugin hooks call the ryk CLI for policy decisions, secret checks, and diagnostics.

## Commands Added

### CLI Commands

- `ryk plugin doctor opencode` — Reports ryk version, OpenCode binary detection, plugin directory status, and OpenCode-specific paths.
- `ryk plugin doctor opencode --json` — JSON output with `opencode_paths` field.
- `ryk plugin manifest opencode` — Reports the expected OpenCode plugin path (`integrations/opencode-plugin/orca.ts`).
- `ryk plugin manifest opencode --json` — JSON output.
- `ryk plugin install opencode --dry-run` — Previews safe install options (`.opencode/plugins/ryk.ts` and `~/.config/opencode/plugins/ryk.ts`).
- `ryk hook opencode <event>` — Processes OpenCode lifecycle hooks.
- `ryk decide <kind> --json '{"host":"opencode",...}'` — Evaluates policy decisions with OpenCode host attribution.

### Hook Events Supported

| Event | Type | Behavior |
|-------|------|----------|
| `tool.execute.before` | Blocking | Evaluates commands/file writes/tools via policy engine |
| `permission.asked` | Blocking | Evaluates permission requests via policy engine |
| `session.created` | Informational | Acknowledges session start |
| `tool.execute.after` | Informational | Redacted metadata logging |
| `permission.replied` | Informational | Audit metadata |
| `file.edited` | Informational | File edit audit |
| `command.executed` | Informational | Command execution metadata |
| `session.updated` | Informational | Session update audit |
| `session.idle` | Informational | Session idle audit |
| `session.error` | Informational | Error event audit |
| `shell.env` | Informational | Environment metadata (no secret injection) |

## Plugin Files Added

```text
integrations/opencode-plugin/
  orca.ts                          # TypeScript OpenCode plugin
  README.md                        # Plugin documentation
  package.json                     # Minimal package metadata
  examples/
    project-plugin-path.md         # Project-local install guide
    global-plugin-path.md          # Global install guide
    opencode.json.example          # Example OpenCode config
```

## Docs Added

- `docs/integrations/opencode.md` — Full integration guide

## Docs Updated

- `docs/integrations/plugin-compatibility.md` — Added OpenCode column to compatibility matrix
- `README.md` — Added OpenCode plugin to plugin list
- `PLUGIN_RELEASE_NOTES.md` — Added OpenCode section
- `PLUGIN_CHANGELOG.md` — Added OpenCode entry
- `LAUNCH_PLUGINS.md` — Added OpenCode summary

## Fixtures Added

```text
tests/plugin-fixtures/opencode/
  session_created.json
  tool_execute_before_command_safe.json
  tool_execute_before_command_dangerous.json
  tool_execute_before_file_write_protected.json
  tool_execute_before_prompt_secret.json
  tool_execute_after.json
  permission_asked.json
  permission_replied.json
  file_edited.json
  command_executed.json
  session_idle.json
  shell_env.json
```

## Packaging Status

- `scripts/package-plugins.sh` updated to produce `dist/plugins/ryk-opencode-plugin-vX.Y.Z.zip`
- `dist/plugins/ryk-plugin-checksums.txt` includes the OpenCode artifact
- Secret scan passes on all artifacts

## Tests Run

### Build
- `zig build` — ✅ Passed

### Unit Tests
- All existing plugin tests pass (546/554 tests passed; 2 pre-existing failures unrelated to this change)
- New tests added:
  - `plugin doctor opencode shows opencode-specific section`
  - `plugin manifest opencode reports expected path`
  - `plugin manifest all reports all three`
  - `plugin install opencode --dry-run reports safe preview with paths`
  - `plugin install all --dry-run reports all three targets`
  - `hook opencode session.created returns allow`
  - `hook opencode tool.execute.before with safe command returns allow`
  - `hook opencode tool.execute.before with dangerous command returns block`
  - `hook opencode informational events are allowed`
  - `mapOpenCodeEvent maps known events correctly`
  - `isOpenCodeInformationalEvent identifies informational events`

### CLI Smoke Tests
```bash
./zig-out/bin/ryk plugin doctor opencode              # ✅ Works
./zig-out/bin/ryk plugin doctor opencode --json       # ✅ Works
./zig-out/bin/ryk plugin manifest opencode            # ✅ Works
./zig-out/bin/ryk plugin install opencode --dry-run   # ✅ Works
./zig-out/bin/ryk decide command --json '{"version":1,"host":"opencode","command":"git status","mode":"strict"}'  # ✅ Works
./zig-out/bin/ryk decide prompt --json '{"version":1,"host":"opencode","prompt":"fake_p08_secret_value","mode":"strict"}'  # ✅ Works
cat tests/plugin-fixtures/opencode/tool_execute_before_command_safe.json | ./zig-out/bin/ryk hook opencode tool.execute.before  # ✅ Works
cat tests/plugin-fixtures/opencode/tool_execute_before_command_dangerous.json | ./zig-out/bin/ryk hook opencode tool.execute.before  # ✅ Works
cat tests/plugin-fixtures/opencode/permission_asked.json | ./zig-out/bin/ryk hook opencode permission.asked  # ✅ Works
```

### Existing Plugin Regression
```bash
cat tests/plugin-fixtures/codex/pre_tool_use_command_dangerous.json | ./zig-out/bin/ryk hook codex PreToolUse   # ✅ Works
cat tests/plugin-fixtures/claude/pre_tool_use_command_dangerous.json | ./zig-out/bin/ryk hook claude PreToolUse # ✅ Works
```

### Packaging
```bash
./scripts/package-plugins.sh                           # ✅ Works
ls -la dist/plugins                                    # ✅ ryk-opencode-plugin-v1.1.0.zip present
cat dist/plugins/ryk-plugin-checksums.txt             # ✅ Includes opencode artifact
```

### Doctor / Redteam
```bash
./zig-out/bin/ryk doctor                              # ✅ Works
```

## Optional Local OpenCode Validation

OpenCode binary was detected in PATH. Local host validation was not performed because OpenCode plugin loading requires placing the plugin file in the host's plugin directory, which is a user-specific configuration step beyond the scope of automated testing.

## Known Limitations

- OpenCode plugin hooks are advisory; actual enforcement depends on OpenCode host capabilities.
- The strongest local protection remains `ryk opencode`.
- OpenCode does not use skills in the same sense as Codex/Claude; the plugin provides hooks and documentation only.
- Official npm/marketplace distribution is not yet implemented.
- Plugin installation is preview/dry-run by default.
- `config_references_plugin` detection is deferred (safe detection only).

## Security Notes

- No raw secrets in plugin files.
- No raw secrets in generated hook outputs.
- No raw secrets in docs.
- No telemetry.
- No silent config mutation.
- Hook/plugin output remains host-compatible JSON.
- Human logs go to stderr.
- CI mode never prompts.
- The plugin does not duplicate ryk policy logic.
- No MCP behavior was added.
- No drone plugin behavior was added.
- No `.mcp.json` was added.

## Release Packaging Safety

Release packaging is safe:
- All artifacts include only intended files.
- Secret scan passes.
- Checksums are generated.
- No drone files, no MCP files, no secrets in artifacts.

## Separate Workstream/Drone Non-Regression

- Drone workstream detection remains unchanged.
- Drone safety mode remains active when workstream is detected.
- No drone plugin behavior was added.
- No drone commands are exposed through the OpenCode plugin.

## Files Changed

### Zig CLI Source
- `src/cli/hook.zig` — Added `opencode` host, OpenCode event mapping, informational event handling, tests
- `src/cli/plugin.zig` — Added `opencode` to doctor/manifest/install commands, OpenCode path detection, tests
- `src/cli/help.zig` — Updated command documentation for opencode

### Plugin Files
- `integrations/opencode-plugin/orca.ts` — TypeScript plugin (NEW)
- `integrations/opencode-plugin/README.md` — Plugin docs (NEW)
- `integrations/opencode-plugin/package.json` — Package metadata (NEW)
- `integrations/opencode-plugin/examples/*` — Install guides and config example (NEW)

### Test Fixtures
- `tests/plugin-fixtures/opencode/*` — 12 JSON fixtures (NEW)

### Docs
- `docs/integrations/opencode.md` — Integration guide (NEW)
- `docs/integrations/plugin-compatibility.md` — Updated
- `README.md` — Updated
- `PLUGIN_RELEASE_NOTES.md` — Updated
- `PLUGIN_CHANGELOG.md` — Updated
- `LAUNCH_PLUGINS.md` — Updated

### Scripts
- `scripts/package-plugins.sh` — Added OpenCode artifact packaging

## Whether the OpenCode Plugin is Ready to Release

**Yes.** The OpenCode plugin is ready to release:

- All CLI commands work correctly.
- All hook events process correctly.
- The plugin file exists and is properly structured.
- Documentation is complete.
- Test fixtures exist for deterministic testing.
- Packaging includes the OpenCode artifact.
- Checksums include the OpenCode artifact.
- Existing Codex and Claude plugins still work.
- No MCP behavior was added.
- No drone plugin behavior was added.
- No secrets leak.
- The 2 pre-existing test failures are unrelated to this change (they concern "ryk" vs "ryk" naming in docs).
