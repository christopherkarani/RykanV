# Separate Workstream Guardrails

## Purpose

The ryk repository may contain other workstreams, including drone-related work under `packages/edge/`.

The plugin plan must not break, expose, or expand those workstreams.

## Rules

Plugin work must not:

- modify safety-sensitive modules unless required to preserve build/test compatibility
- expose unrelated commands through plugins
- add plugin skills for unrelated workstreams
- add demos for unrelated safety-sensitive workstreams
- add operational instructions for safety-sensitive systems
- weaken tests
- weaken policies
- auto-approve high-risk operations

## Drone-specific Note

A separate drone workstream exists in this repository under `packages/edge/`.

The ryk plugins do not expose or modify drone functionality.

Plugin packages do not include drone skills or drone demos.

Plugin docs do not include operational drone-control instructions.

Existing drone tests should continue to pass or have safe skip reasons documented.

## Plugin Package Contents

Plugin artifacts (`ryk-codex-plugin-vX.Y.Z.zip` and `ryk-claude-code-plugin-vX.Y.Z.zip`) contain only:

- Plugin manifest (`plugin.json`)
- Skills (doctor, init, protect, redteam, replay)
- Hooks configuration (`hooks.json`)
- README

Plugin artifacts explicitly exclude:
- Drone files
- `.mcp.json`
- Build artifacts
- Temporary files
- Secrets

## Verification

To verify that plugin packages do not contain drone files:

```bash
unzip -l dist/plugins/ryk-codex-plugin-v*.zip | grep -i drone || echo "No drone files found"
unzip -l dist/plugins/ryk-claude-code-plugin-v*.zip | grep -i drone || echo "No drone files found"
```

## Documentation Policy

Plugin documentation may reference the separate drone workstream only to state:

```text
A separate drone workstream exists in this repository. The ryk plugins do not expose or modify drone functionality.
```

Plugin documentation must not include:
- Drone-control procedures
- Drone demo instructions
- Operational drone safety checklists
- Drone actuation commands

## See Also

- `docs/integrations/plugin-security-model.md`
- `SEPARATE_WORKSTREAM_GUARDRAILS.md`
