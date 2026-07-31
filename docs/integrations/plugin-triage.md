# Plugin Issue Triage

Use this document to triage plugin issues for the ryk Codex plugin, Claude Code plugin, CLI plugin surface, packaging, and release flow.

## Recommended labels

- plugin:codex
- plugin:claude
- plugin:cli
- plugin:hooks
- plugin:install
- plugin:marketplace
- plugin:security
- plugin:compatibility
- plugin:docs
- plugin:packaging
- plugin:release

## Severity guidance

- P0: secret leakage, unsafe decision downgrade, hook output corrupts host protocol
- P1: install broken, hooks not firing, false security claim, release artifact broken
- P2: docs confusion, compatibility gap, non-critical false positive
- P3: enhancement request

## Triage process

1. Confirm the host, plugin version, ryk version, install method, and exact reproduction path.
2. Reproduce locally with the smallest safe fixture, command, or hook payload.
3. Classify the issue by surface: Codex, Claude, CLI, hooks, install, marketplace, security, compatibility, docs, packaging, or release.
4. Assign the smallest accurate label set from the recommended labels above.
5. Rate severity using the guidance above and escalate P0/P1 issues immediately.
6. Capture expected behavior, actual behavior, redacted logs, and any local environment details needed to reproduce.
7. Prefer deterministic fixtures and local verification over screenshots, remote services, or telemetry.
8. Close the loop with the fix, the verification result, and any doc update needed to prevent repeat confusion.

## Notes

- Do not add labels through API unless a safe local script already exists and the user requested it.
- Keep triage local-first; do not require telemetry or remote reproduction.
- Do not over-label issues that clearly belong to a single surface.
