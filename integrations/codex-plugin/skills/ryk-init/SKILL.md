# ryk-init

Create or repair an ryk policy for the current repository.

## When to use

Use this skill when starting a new project, when `.ryk/policy.yaml` is missing, or when you want to reset to a known-good policy preset.

## Commands

Initialize an ryk policy with the Codex preset:

```bash
ryk init --preset codex
```

Validate the resulting policy:

```bash
ryk policy check .ryk/policy.yaml
```

## Preset fallback

If the `codex` preset is not available in your ryk build, use the closest plugin-safe preset:

```bash
ryk init --preset generic-agent
```

Or, for stricter defaults:

```bash
ryk init --preset strict-local
```

The `generic-agent` preset is a conservative starting point for local coding agents. Review the generated `.ryk/policy.yaml` before trusting it.

## Safety rules

- **Do not silently overwrite** `.ryk/policy.yaml`. If a policy already exists, review it first.
- If you need to recreate it, back up the old file:
  ```bash
  cp .ryk/policy.yaml .ryk/policy.yaml.bak
  ```
- Always run `ryk policy check` after creating or editing a policy.

## Notes

- This skill modifies only `.ryk/policy.yaml` in the current workspace.
- No host configuration is changed.
- No telemetry is sent.
- The generated policy does not contain real secrets.
