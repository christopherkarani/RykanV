# ryk CLI package

This package exposes the CLI-facing module boundary for ryk. The implementation currently lives in `src/` and is wired into the root build.

It owns command parsing and help, launch aliases, diagnostics, policy commands, replay, MCP, red-team checks, staging, installers, and release behavior.

The package is a facade for the product CLI, not a separate binary. Keep policy decisions, audit writing, replay verification, and redaction on the shared ryk paths rather than creating a second implementation.
