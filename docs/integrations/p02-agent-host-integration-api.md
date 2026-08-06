# P02 Agent Host Integration API Handoff

> Scope: P02, agent host integration contract for `ryk decide` and `ryk hook`
> Version: 1.0.0

## Phase Overview

P02 adds the local integration layer that lets agent hosts ask ryk for policy decisions without reimplementing policy logic. The goal of this phase was to expose a direct decision command for tools and a host hook adapter for Codex and Claude Code, both backed by the same policy engine and the same `.ryk/policy.yaml` source of truth.

This phase does not add a new enforcement boundary. Hook enforcement is additive and still depends on the host exposing the event. The stronger control remains `ryk run -- <command>`.

## What Was Delivered

- `src/cli/decide.zig`
  - Added `ryk decide`.
  - Supports four decision kinds: `command`, `file`, `prompt`, and `tool`.
  - Accepts input with `--json` or `--stdin`.
  - Supports `--ci`, which converts `ask` to `block`.
  - Uses semantic exit codes on policy outcomes: `0` allow/context_only, `3` block, `7` ask, `8` warn; `1` general error and `2` usage for failures before JSON is emitted. See `docs/integrations/integration-api.md` for the full table.
  - Reads `.ryk/policy.yaml` during evaluation.

- `src/cli/hook.zig`
  - Added `ryk hook`.
  - Supports two hosts, `codex` and `claude`.
  - Supports seven events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, and `SessionEnd`.
  - Reads JSON payloads from stdin with a 256 KiB limit.
  - Validates version, host, and event before evaluation.
  - Returns standardized JSON responses.

- Host adapters
  - Normalize Codex and Claude payloads into a common decision flow.
  - Detect file tools case-insensitively: `edit`, `write`, `file_write`, `file_edit`, `apply`, `create_file`, and `write_file`.
  - Redact secrets on `UserPromptSubmit` using the existing redaction engine.
  - Include honest `host_limitations` text in responses.

- JSON schemas under `integrations/common/schemas/`
  - `hook-request-v1.json`
  - `hook-response-v1.json`
  - `host-capabilities-v1.json`

- Test fixtures under `tests/plugin-fixtures/`
  - `codex/` with 8 JSON fixtures.
  - `claude/` with 8 JSON fixtures.

- Wiring
  - `src/cli/mod.zig` now imports and dispatches `decide` and `hook`.
  - `src/cli/help.zig` now documents the new commands.

## Architecture Summary

### `ryk decide`

`decide` is the direct policy evaluation API. It is meant for host integrations, plugin packages, and local tooling that need one policy answer for one request.

Flow:

1. Parse kind and payload.
2. Load `.ryk/policy.yaml`.
3. Evaluate the request against the matching decision path.
4. Return a structured decision with a stable exit code.

### `ryk hook`

`hook` is the host event adapter. It accepts a host and an event, normalizes the payload, and routes the request into the same policy engine used by `decide`.

Flow:

1. Read JSON from stdin.
2. Validate protocol version, host, and event.
3. Normalize the host payload.
4. Map the event to command, file, prompt, or tool evaluation.
5. Return a standardized JSON response.

### Host adapters

The Codex and Claude adapters exist to hide host-specific payload shape differences. They do not define policy. They only normalize inputs, identify file tool usage, and preserve honest limits in the output.

## API Surface Summary

### Commands

- `ryk decide <kind> --json '<payload>'`
- `ryk decide <kind> --stdin`
- `ryk decide <kind> --ci`
- `ryk hook codex <event>`
- `ryk hook claude <event>`

### Decision kinds

- `command`
- `file`
- `prompt`
- `tool`

### Hosts

- `codex`
- `claude`

### Events

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `Stop`
- `SessionEnd`

### Schemas

- Request schema: `integrations/common/schemas/hook-request-v1.json`
- Response schema: `integrations/common/schemas/hook-response-v1.json`
- Capability schema: `integrations/common/schemas/host-capabilities-v1.json`

## Test Coverage

### Fixtures

`tests/plugin-fixtures/` covers both hosts with mirrored event sets.

- Codex fixtures:
  - `session_start`
  - `user_prompt_submit_secret`
  - `pre_tool_use_command_safe`
  - `pre_tool_use_command_dangerous`
  - `pre_tool_use_file_write_protected`
  - `permission_request`
  - `post_tool_use`
  - `stop`

- Claude fixtures:
  - same event coverage, with `session_end` instead of `stop`

### Manual verification

Verified acceptance flows:

- `zig build` passes.
- `ryk decide command --json '{"command":"git status"}'` returns allow.
- `ryk decide command --json '{"command":"rm -rf *"}'` returns block.
- `ryk decide file --json '{"path":"/etc/passwd","operation":"write"}'` returns block.
- `ryk decide prompt --stdin` with a secret returns warn.
- `ryk hook codex SessionStart` with fixture input returns allow.
- `ryk hook codex UserPromptSubmit` with fixture input returns warn.
- `ryk hook codex PreToolUse` with a safe command fixture returns allow.
- `ryk hook codex PreToolUse` with a dangerous command fixture returns block.
- `ryk hook claude PreToolUse` with a file write fixture returns block.

## Known Limitations and Issues

- `zig build test` hangs because a pre-existing MCP proxy test reads real stdin and conflicts with Zig test runner `--listen=-` handling.
- Individual test binaries pass when run directly.
- Current reported state: 267 of 273 tests pass, with 6 skipped.
- Hook enforcement is additive. It does not replace `ryk run` supervision.
- File tool detection is heuristic and based on tool name matching.
- Secret detection uses the existing pattern-based redaction engine.

## Non-Regression Verification

P01 plugin-surface commands still work after this phase.

- `ryk plugin doctor`
- `ryk plugin manifest`
- `ryk plugin install --dry-run`

No P01 behavior was removed or renamed by this phase.

## Next Steps for P03/P04

- Build the actual Codex plugin package that calls `ryk hook`.
- Build the actual Claude Code plugin package that calls `ryk hook`.
- Keep both plugin packages thin.
- Plugin packages must call the ryk and must not duplicate policy logic.
- Plugin docs must not claim stronger enforcement tha ryk actually provides.
- Do not add MCP server behavior here.
- Do not add drone plugin behavior here.

## Acceptance Criteria Checklist

- [x] `zig build` passes.
- [x] `ryk decide command --json '{"command":"git status"}'` returns allow.
- [x] `ryk decide command --json '{"command":"rm -rf *"}'` returns block.
- [x] `ryk decide file --json '{"path":"/etc/passwd","operation":"write"}'` returns block.
- [x] `ryk decide prompt --stdin` with a secret returns warn.
- [x] `ryk hook codex SessionStart` with fixture input returns allow.
- [x] `ryk hook codex UserPromptSubmit` with fixture input returns warn.
- [x] `ryk hook codex PreToolUse` with a safe command fixture returns allow.
- [x] `ryk hook codex PreToolUse` with a dangerous command fixture returns block.
- [x] `ryk hook claude PreToolUse` with a file write fixture returns block.
- [x] `ryk plugin doctor` still works.
- [x] `ryk plugin manifest` still works.
- [x] `ryk plugin install --dry-run` still works.
