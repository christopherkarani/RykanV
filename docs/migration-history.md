# Migration: Aegis to ryk

ryk is the current CLI name for the local agent guardrail runtime that older
project notes may still call Aegis. This migration note is for repository
metadata and local workspace paths only.

## Local Workspace Paths

- New ryk sessions should use `.ryk/` for policy, audit, replay, and runtime
  artifacts.
- Older `.aegis/` session directories may remain for historical replay or
  migration reference.
- Do not copy old secrets, raw payloads, or unredacted logs into new ryk
  workspaces.

## Command Mapping

- `aegis --help` is no longer installed in the hard-break release; use `ryk --help`.
- Use `ryk --help`, `ryk doctor`, `ryk run`, `ryk replay`, and
  `ryk redteam` in new documentation and integrations.

## Safety Boundary

This document does not change the Edge boundary. Edge evidence remains
simulation, SITL, bench-preparation, and customer-evaluation evidence only. It
is not real-flight readiness, certification, regulatory approval,
detect-and-avoid, or autopilot replacement.
