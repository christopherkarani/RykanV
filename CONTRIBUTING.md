# Contributing

Thanks for taking the time to improve ryk. Keep changes focused, explain the user-visible effect, and include a reproducible check when the change affects behavior.

## Development requirements

- Use Zig `0.16.0` from `.zigversion`.
- Prefer `./scripts/zig` so local and CI builds use the same compiler.
- Do not add dependencies without documenting them in [`docs/dev/dependencies.md`](docs/dev/dependencies.md).
- Do not add telemetry, hosted enforcement, SaaS, billing, or cloud dashboards without a separate product decision.
- Never commit credentials or raw secrets, even in fixtures or example output.

## Build and test

From the repository root:

```sh
./scripts/zig version
./scripts/compile-fast.sh check
./scripts/zig build test-shell-engine
```

Use the narrowest relevant check while iterating:

```sh
./scripts/test-slice.sh policy
./scripts/test-slice.sh sandbox
./scripts/test-slice.sh intercept
```

Before a pull request, run the default product gate. The full gate can take several minutes because it includes the Zig test graph and install checks:

```sh
./scripts/test-fast.sh
./scripts/verify-pre-merge.sh
```

For changes to the dashboard or a host integration, also run that package's local test command and inspect the generated or serialized output. A green unit test is not proof that a host hook fired or that an OS sandbox attached.

## Documentation

Document behavior that a user can observe. Include the command, platform, and limitation when a feature is conditional. Use `wrapper`, `hook`, `proxy`, and `OS-enforced` according to [the compatibility matrix](docs/compatibility.md); do not describe a capability probe as live enforcement.

Keep internal notes, handoffs, and scratch output out of the tracked documentation tree. Generated release archives, SBOMs, checksums, and package output belong in ignored build directories.

## Pull requests

Use a short title that describes the change. In the body, include:

- what changed and why;
- the checks you ran;
- platform-specific gaps or unverified host behavior;
- screenshots or sample output when the CLI or dashboard changed.

Keep unrelated formatting and cleanup out of the diff. Review [SECURITY.md](SECURITY.md) before touching policy, secrets, network, MCP, hooks, or sandbox code.
