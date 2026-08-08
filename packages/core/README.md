# ryk Core

This package defines the shared policy, decision, audit, replay, redaction, schema, and type boundary used by the ryk CLI.

The current implementation remains under `src/`. `packages/core/` provides the curated package surface and contract tests while the module graph is kept stable.

Core code is local and platform-independent where possible. It does not own CLI parsing, host plugin installation, dashboard serving, or shell-specific presentation.
