# ryk Core

Core is the shared policy, audit, event, replay, redaction, schema registry, type, and decision contract used by ryk.

## What Belongs Here

- Policy loading, validation, evaluation, and explanations.
- Decision types, action types, sessions, events, and platform-independent utilities.
- Audit event persistence, redaction before persistence, hash-chain replay, and summaries.
- Shared schema registry and engine contracts that are not tied to one product UI.

## What Does Not Belong Here

- CLI command parsing, desktop process supervision commands, installers, or shell completions.
- Drone hardware adapters, MAVLink, PX4, ArduPilot, or real-flight behavior.
- SaaS, telemetry, monetization, hosted dashboards, or network services.

## Current API Surface

Core is the engine facade for ryk:

- `api`: policy parsing, validation, action evaluation, decision creation, audit event creation/writing, replay loading, replay verification, and redaction helpers.
- `actions`: shared command, file, network, MCP, prompt, environment, and extension action types.
- `schemas`: schema registry for policy, event, and MCP manifest schemas.
- `abi`: experimental C ABI skeleton.
The existing implementation remains in `src/` to preserve ryk CLI behavior while future phases separate code physically where it is safe.

## ABI Status

The C ABI skeleton is experimental and not stable v1. See `ABI.md` for ownership, limits, return-code, and scope rules.

## Future Phases

Later phases may move implementation files into this package after dependency cycles are deliberately removed and regression tests prove the CLI behavior remains unchanged.

## ryk CLI Contract

Core is the single engine facade for CLI policy loading, validation, evaluation, explanations, redaction, audit writing, replay verification, and schema lookup. CLI code may keep product-specific parsing and UX, but it must not fork a second policy engine, audit writer, replay verifier, or redaction path.
