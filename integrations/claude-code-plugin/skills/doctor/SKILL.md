# doctor

Check ryk installation, policy status, host integration status, and plugin readiness.

## When to use

Use this skill when you want to verify that ryk is properly installed, that a policy exists for the current repository, and that the Claude Code plugin integration is ready.

## Commands

Run the ryk plugin doctor for Claude Code:

```bash
ryk plugin doctor claude
```

Run the general ryk doctor for platform capabilities:

```bash
ryk doctor
```

## Interpreting results

### Missing ryk binary

If `ryk` is not found in PATH, install ryk first. Build from source with Zig 0.16.0:

```bash
zig build
```

The binary will be at `./zig-out/bin/ryk`.

### Missing policy

If `.ryk/policy.yaml` is missing, initialize one:

```bash
ryk init --preset claude-code
```

If the `claude-code` preset is not available, use the closest plugin-safe preset:

```bash
ryk init --preset generic-agent
```

Then validate it:

```bash
ryk policy check .ryk/policy.yaml
```

### Missing Claude Code plugin install

If the plugin directory is not detected, ensure the ryk repository includes `integrations/claude-code-plugin/` and that you are running from the workspace root.

### Follow-up diagnostics

If the doctor reports warnings:

1. Read the warning message carefully.
2. Fix missing policies or binaries.
3. Re-run `ryk plugin doctor claude` to confirm.
4. If issues persist, run `ryk doctor` for platform-specific capability notes.

## Notes

- This skill does not modify host configuration.
- No telemetry is sent.
- The doctor output goes to stdout; errors go to stderr.
