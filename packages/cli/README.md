# ryk

ryk is the desktop and CI AI-agent runtime firewall product.

## What Belongs Here

- `ryk` command parsing, help, version, doctor, policy, replay, run, MCP, red-team, and staging commands.
- Desktop and CI process supervision behavior for ryk-managed child sessions.
- Desktop file, network, command, MCP, installer, release, and CLI documentation surfaces.
- CLI examples and CI recipes.

## What Does Not Belong Here

- Drone or robotics command mediation.
- MAVLink, PX4, ArduPilot, flight-controller, autopilot, or detect-and-avoid behavior.
- Hosted policy sync, monetization, or product claims outside local CLI behavior. Release builds may send the fixed pseudonymous CLI telemetry described in [`docs/telemetry.md`](../../docs/telemetry.md); Core and plugin payloads remain outside that surface.

## Current Status

Phase 25 keeps the existing `ryk` binary and CLI behavior intact while hardening command UX, Core integration, redaction, audit/replay, red-team, MCP, docs, and packaging behavior after the Core/CLI/Edge split.

## Future Phases

Future phases can continue to improve CLI packaging and desktop/CI behavior without coupling those changes to Edge runtime work.
