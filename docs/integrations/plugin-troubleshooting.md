# Plugin Troubleshooting

This document covers common issues when installing, running, or uninstalling ryk plugins.

## ryk binary not found

**Symptom:** `orca: command not found` or plugin doctor reports `ryk binary: not found`.

**Fix:**
1. Use the one-command bootstrap:
   ```bash
   ./scripts/install-ryk-plugin.sh opencode project
   # or
   ./scripts/install-ryk-plugin.sh openclaw project
   # or
   ./scripts/install-ryk-plugin.sh hermes project
   ```
2. Or build ryk from source:
   ```bash
   zig build
   ```
3. Use the full path:
   ```bash
   ./zig-out/bin/ryk plugin doctor codex
   ```
4. Or add to PATH:
   ```bash
   export PATH="$PWD/zig-out/bin:$PATH"
   ```

## Plugin manifest missing

**Symptom:** `ryk plugin manifest codex` reports `missing`.

**Fix:**
1. Ensure you are running from the repository root.
2. Check that the file exists:
   ```bash
   ls integrations/codex-plugin/.codex-plugin/plugin.json
   ls integrations/claude-code-plugin/.claude-plugin/plugin.json
   ```
3. If installing from a release artifact, ensure the zip was extracted fully.

## Plugin path wrong

**Symptom:** Host IDE cannot find the plugin after installation.

**Fix:**
1. Verify the plugin directory structure:
   ```bash
   ls integrations/codex-plugin/
   # Expected: .codex-plugin/  skills/  hooks/  README.md
   ```
2. For release artifacts, ensure you extracted to the correct location.
3. For marketplace installs, check that the `source` path in `marketplace.json` is correct.

## Codex host not found

**Symptom:** `ryk plugin doctor codex` reports `codex binary: not detected`.

**Fix:**
1. Ensure Codex is installed and in PATH.
2. The doctor checks for common Codex binary names. If your binary has a different name, the plugin will still work but the doctor cannot confirm host presence.

## Claude host not found

**Symptom:** `ryk plugin doctor claude` reports `claude binary: not detected`.

**Fix:**
1. Ensure Claude Code is installed and in PATH.
2. The doctor checks for common Claude Code binary names. If your binary has a different name, the plugin will still work but the doctor cannot confirm host presence.

## Hooks not firing

**Symptom:** No ryk output appears when host triggers hooks.

**Fix:**
1. Check that `ryk` is in PATH.
2. Check hook configuration exists:
   ```bash
   ls integrations/codex-plugin/hooks/hooks.json
   ls integrations/claude-code-plugin/hooks/hooks.json
   ```
3. Test manually:
   ```bash
   cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json \
     | ./zig-out/bin/ryk hook codex PreToolUse
   ```
4. Check that the host IDE's plugin system is enabled and configured to load hooks.

## Cursor beforeShellExecution: invalid JSON

**Symptom:** Cursor agent Shell tool is blocked with:

```text
Hook "ryk" returned invalid JSON. The command was blocked for safety.
```

**Cause:** Cursor's `beforeShellExecution` hook expects valid JSON on stdout (`permission`, `continue`, …). If `~/.cursor/hooks.json` points at bare `ryk` and the binary prints human help instead of JSON, Cursor fail-closes every shell command.

**Fix (recommended):** Re-run ryk install so Cursor uses the generated Python wrapper:

```bash
# From a ryk install tree or release bundle
./install.sh   # configure_cursor() writes ~/.cursor/hooks/ryk-pre-shell.py
```

Expected `~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [
      {
        "command": "$HOME/.cursor/hooks/ryk-pre-shell.py"
      }
    ]
  }
}
```

**Fix (bare `ryk` on PATH):** Zig `ryk` now supports Rust-compatible stdin agent-hook mode when invoked with no subcommand and piped JSON. Verify outside Cursor's agent shell:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | orca
# allow: empty stdout, exit 0

echo '{"command":"pwd","cwd":"/tmp"}' | orca
# allow: {"permission":"allow","continue":true,...}

echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | orca
# deny: {"hookSpecificOutput":{"permissionDecision":"deny",...}}
```

Interactive `ryk` with no args on a TTY still shows help (not hook mode).

**Mode (bare hook):** Default is `strict`. Ambient `RYK_MODE=observe` / `ask` / `trusted` is **ignored** so a hostile env cannot soften bare hooks. To intentionally soften bare-hook mode, set both:

```bash
export RYK_ALLOW_MODE_SOFTEN=1
export RYK_MODE=observe
```

Prefer `ryk run -- …` (session-recorded `shim_mode`) for intentional soft modes under an agent session.

**Wrapper smoke test:**

```bash
echo '{"command":"echo hello","cwd":"'"$PWD"'"}' | python3 ~/.cursor/hooks/ryk-pre-shell.py
```

Should print one JSON object with `"permission":"allow"` for safe commands.

## Hook output invalid

**Symptom:** Host IDE reports invalid JSON from hook.

**Fix:**
1. Test the hook manually and inspect stdout:
   ```bash
   cat tests/plugin-fixtures/codex/pre_tool_use_command_safe.json \
     | ./zig-out/bin/ryk hook codex PreToolUse 2>/dev/null
   ```
2. Ensure stderr is separate from stdout. Human-readable logs go to stderr; only JSON goes to stdout.
3. If stdout contains non-JSON text, check that no shell aliases or wrappers are interfering.

## Hook command timeout

**Symptom:** Host IDE reports hook timed out.

**Fix:**
1. Check that `.ryk/policy.yaml` is small and loads quickly.
2. Ensure the machine is not under extreme load.
3. The default timeouts are 10s for most hooks, 15s for PreToolUse and PermissionRequest.
4. If policy evaluation is slow, consider simplifying the policy file.

## Permission errors

**Symptom:** `Permission denied` when running `ryk` or accessing plugin files.

**Fix:**
1. Ensure the `ryk` binary has execute permissions:
   ```bash
   chmod +x ./zig-out/bin/ryk
   ```
2. Ensure plugin directories are readable:
   ```bash
   chmod -R u+r integrations/codex-plugin/
   chmod -R u+r integrations/claude-code-plugin/
   ```

## Missing policy

**Symptom:** Hooks return warnings about missing policy.

**Fix:**
1. Create a default policy:
   ```bash
   ./zig-out/bin/ryk init --preset generic-agent
   ```
2. Validate the policy:
   ```bash
   ./zig-out/bin/ryk policy check .ryk/policy.yaml
   ```

## Redteam failure

**Symptom:** `ryk redteam --ci` reports failures.

**Fix:**
1. Check that all fixtures are present:
   ```bash
   ls tests/plugin-fixtures/codex/
   ls tests/plugin-fixtures/claude/
   ```
2. Ensure you are running from the repository root.
3. Check stderr for specific failure reasons.
4. Some failures may be pre-existing issues (e.g., MCP proxy stdin hang). Check the P02 handoff for known issues.

## Fake secret redaction questions

**Symptom:** Test output mentions secrets like `fake_p05_secret_value`.

**Explanation:** These are synthetic test values used only in fixture files. They are not real secrets. The redaction system is expected to detect and warn about them. This is correct behavior.

**If you see real secrets:**
1. Do not commit them.
2. Rotate the exposed credential immediately.
3. Report the leak per `SECURITY.md`.

## Uninstall/reinstall

**Uninstall:**
1. Remove the plugin from the host IDE's plugin management.
2. Delete the plugin directory if installed from a release artifact.
3. The plugin does not mutate host config, so no cleanup is needed beyond removal.

**Reinstall:**
1. Uninstall first.
2. Reinstall from the release artifact or local path.
3. Run `ryk plugin doctor <host>` to verify.

## Marketplace path issues

**Symptom:** Claude marketplace catalog cannot find the plugin.

**Fix:**
1. Check that the `source` path in `marketplace.json` points to the correct directory.
2. The default uses a relative path (`../claude-code-plugin`). If your Claude Code version requires absolute paths, update the `source` field.
3. Verify the marketplace file is valid JSON:
   ```bash
   cat integrations/claude-marketplace/.claude-plugin/marketplace.json | python3 -m json.tool
   ```

## Still stuck?

1. Run `ryk doctor` for a full capability report.
2. Run `ryk plugin doctor <host> --json` for detailed plugin status.
3. Check `docs/troubleshooting.md` for general ryk issues.
4. Review the phase handoffs in `docs/integrations/` for known limitations.
