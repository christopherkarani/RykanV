# ryk Production-Readiness Fixes

Date: 2026-07-12
Status: Approved design

## Objective

Fix every confirmed defect from the 2026-07-12 production-readiness audit across the machine-wide dashboard, secret redaction, and human-facing CLI. Preserve ryk's existing local-first architecture, fail-closed behavior, and frozen raw, JSON, hook-protocol, and generated-output contracts.

Resolve the pre-existing merge conflicts in the OpenClaw and OpenCode plugin lockfiles by matching their package manifests at version `1.2.8`. The existing oversized Codex `PreToolUse` fix in `src/cli/hook.zig` and its regression test must be preserved and integrated with the redaction changes.

## Dashboard

### Trusted assets

Dashboard assets must come from a trusted installed or executable-relative resource root. A selected workspace or the current repository must never shadow dashboard JavaScript or receive the dashboard CSRF token. Development checkouts may use source assets only through an explicit development resource-root mechanism already controlled by the operator.

### One shipped machine-wide UI

The preferred and released Next export is the canonical dashboard UI. It must implement both modes exposed by the backend:

- Machine mode shows registered workspaces, workspace and host context on activity, and globally safe actions only.
- Workspace mode shows the selected workspace and enables policy, secretless, and integration surfaces.
- Machine mode hides or disables workspace-only navigation with actionable guidance.
- Session identity is the tuple `(workspace_root, session_id)`, never `session_id` alone.
- Tests inspect the UI source that produces the shipped export and verify the packaged artifact, rather than treating legacy assets as proof of the released experience.

### Durable aggregation

Global feed writes remain best-effort and must never change hook or evaluate exit behavior. Reads must:

- tolerate malformed or crash-truncated individual JSONL records;
- avoid loading unbounded history into memory;
- enforce caller-requested result limits;
- expose a degraded-feed indication instead of silently presenting corruption as an empty history;
- retain enough bounded history through rotation or compaction for useful machine-wide operation.

Session aggregation gathers candidates before sorting and limiting. Feed-derived host, decision, and denied-count metadata enriches both feed-only and filesystem-backed sessions.

## Secret Redaction

### Presentation boundary

All daemon-derived hook reasons, explanations, remediation, and error text pass through the redactor before serialization to an agent host. Human approval and denial UI uses a redacted display command for titles, explanations, and suggested commands. Evaluation continues to receive the original command; redaction must never change enforcement semantics.

### Structured detection

The redactor adds bounded, deterministic recognition for:

- case-insensitive credential prefixes and sensitive key names;
- JSON-like key/value strings and authorization headers;
- environment assignments and CLI secret flags;
- common percent, base64, and hexadecimal representations within strict size and decode-depth limits.

Redaction remains conservative: suspicious values are replaced with typed markers, raw values are never echoed in error messages, and decoding work is capped to prevent denial-of-service behavior.

### Policy semantics

Security-sensitive persisted surfaces remain unconditionally redacted. `audit.redact_secrets` must no longer imply that users can disable this guarantee: policy validation rejects `false`, documentation describes the invariant, and existing secure defaults remain compatible.

## CLI UX

- `ryk packs --help` is Zig-owned and documents the actual friendly interface; raw daemon output remains untouched for machine modes.
- `--no-rich` behaves as a global option before or after the command, but is never consumed from child argv after `--` or from opaque generated/protocol payloads.
- Human layouts derive a bounded width from terminal context and degrade cleanly on narrow terminals.
- Unicode capability is independent from color capability. Plain/ASCII environments do not emit emoji or box glyphs they cannot safely render.
- Dashboard launch output states machine or workspace mode. Invalid dashboard options use shared typo suggestions and exact help remediation.
- Generated completions hide internal commands and contain command-specific supported flags, including current dashboard and packs flags.
- Command-specific human help uses the shared product voice without adding bytes to raw, JSON, hook, completion, or generated-output contracts.

## Error Handling and Compatibility

- Dashboard feed corruption produces partial valid results plus explicit degraded status.
- Feed rotation, registry updates, and policy writes retain existing locking and atomic replacement guarantees.
- Redaction allocation or decoding failures fail safe by withholding suspect text.
- Existing machine-readable output remains byte-identical unless the audited contract itself is defective and a new regression fixture explicitly defines the corrected output.
- No new dependency is required.

## Test Strategy

Every behavior change follows RED, GREEN, REFACTOR:

1. Add a focused regression test and run it to observe the expected failure.
2. Make the minimum production change.
3. Run the focused test to green before proceeding.

Required coverage includes:

- trusted dashboard resource resolution and packaged-asset selection;
- machine/workspace Next UI rendering and composite session identity;
- malformed, oversized, rotated, and limited global feeds;
- newest-session selection and feed enrichment;
- hook and human-output redaction for structured and encoded secrets;
- rejection of `audit.redact_secrets: false`;
- global-option placement, narrow widths, ASCII fallback, dashboard remediation, canonical packs help, and command-specific completions;
- unchanged raw/JSON/protocol fixtures.

Final verification uses `./scripts/zig build`, `./scripts/zig build test-fast`, the broad Zig test gate when the environment permits socket tests, the dashboard production build, UI tests, installed-layout smoke, and release artifact inspection. Environment failures must be reported separately from product failures.

## Delivery Order

1. Dashboard trust and aggregation correctness.
2. Shipped Next UI machine/workspace parity.
3. Redaction at persistence and presentation boundaries.
4. CLI help, options, responsiveness, accessibility, and completions.
5. Cross-module verification, packaged-artifact inspection, and review.

Each slice may be committed independently using conventional commit messages after its focused and relevant regression gates pass.
