# Packaging

The canonical CLI binary is **ryk** (Rykan V). Artifacts are `ryk-v{version}-*`.

Production package templates live under:

- `homebrew/Formula/ryk.rb`
- `scoop/ryk.json`
- `winget/ryk.yaml`
- `npm/package.json` (`@rykan/ryk`, bin `ryk`)
- `docker/Dockerfile` (ENTRYPOINT `ryk`)
- `edge/Dockerfile`
- `systemd/edge.service`
- `systemd/edge-bench.example.service`
- `systemd/edge-sitl.service`

Templates use release version metadata and remain fail-closed while they contain placeholder checksums. Release automation renders publishable Homebrew, npm, Scoop, and WinGet manifests into `dist/package-manifests/` from `dist/checksums.txt`; `scripts/verify-release.sh` fails if rendered manifests are missing or still contain placeholders. The project license is Apache-2.0.

## Cutting a release (primary)

Use **`scripts/cut-release.sh`** on a Mac (optional Shortcuts.app UX). See [`docs/dev/cut-release-shortcut.md`](../docs/dev/cut-release-shortcut.md) and [`docs/dev/release.md`](../docs/dev/release.md).

```sh
./scripts/cut-release.sh --bump patch --live
```

That path builds artifacts locally (Linux via Docker), creates the GitHub Release with assets, publishes npm from **rendered** manifests (never `PLACEHOLDER_*`), and pushes the Homebrew tap.

Edge packaging is for local simulation/SITL/bench-preparation evaluation only. Package templates must not add credentials, hosted telemetry, privileged container defaults, real hardware endpoint defaults, real-flight deployment, certification claims, detect-and-avoid claims, or autopilot replacement behavior.
