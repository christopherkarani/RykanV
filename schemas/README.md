# Schemas

Versioned v1 JSON Schemas:

- `policy-v1.json`: ryk policy file shape for `version: 1`.
- `event-v1.json`: audit `events.jsonl` record shape for `version: 1`.
- `mcp-manifest-v1.json`: stdio MCP manifest shape for `version: 1`.
- `edge-policy-placeholder-v1.json`: reserved placeholder for future Edge policy schemas.
- `edge-event-placeholder-v1.json`: reserved placeholder for future Edge audit-event schemas.
- `safety-report-placeholder-v1.json`: reserved placeholder for future safety-report schemas.

The runtime parsers reject unknown keys for these v1 formats. Future breaking schema changes require a new version and migration notes.

Edge and safety-report schemas are versioned domain/schema contracts for local policy evaluation, MAVLink mediation, fake-PX4/fake-ArduPilot scenarios, and opt-in PX4/ArduPilot SITL simulation evidence. They do not claim real drone enforcement, real-flight readiness, regulatory approval, or real hardware support.

- `edge-policy-v1.json`: policy shape for domain validation and simulation mediation.
- `edge-event-v1.json`: audit event name surface for local Edge decisions and simulation evidence.
- `safety-report-v1.json`: safety report shape and limitation fields for engineering audit artifacts.
