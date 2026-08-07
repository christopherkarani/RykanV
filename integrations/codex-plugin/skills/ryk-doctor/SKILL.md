# ryk-doctor

Check ryk installation, policy status, host integration status, and plugin readiness.

## When to use

Use this skill when you want to verify that ryk is properly installed, that a policy exists for the current repository, and that the Codex plugin integration is ready.

## Commands

Run the ryk plugin doctor for Codex:

```bash
ryk plugin doctor codex
```

Run the general ryk doctor for platform capabilities:

```bash
ryk doctor
```

## Interpreting results

### Missing ryk binary

If `ryk` is not found in PATH, install ryk first. Build from source with Zig 0.16.0:

```bash
./scripts/zig build
```

The binary will be at `./zig-out/bin/ryk`.

### Missing policy

If `.ryk/policy.yaml` is missing, initialize one:

```bash
ryk init --preset codex
```

Then validate it:

```bash
ryk policy check .ryk/policy.yaml
```

### Missing Codex plugin install

If the plugin directory is not detected, ensure the ryk repository includes `integrations/codex-plugin/` and that you are running from the workspace root.

### Follow-up diagnostics

If the doctor reports warnings:

1. Read the warning message carefully.
2. Fix missing policies or binaries.
3. Re-run `ryk plugin doctor codex` to confirm.
4. If issues persist, run `ryk doctor` for platform-specific capability notes.

## Notes

- This skill does not modify host configuration.
- No telemetry is sent.
- The doctor output goes to stdout; errors go to stderr.
