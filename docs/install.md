# Install

## Build From Source

```sh
./scripts/zig version   # must print 0.16.0
./scripts/build-all.sh  # or: ./scripts/zig build
./zig-out/bin/ryk version --json
```

Use Zig `0.16.0` (see `.zigversion`; prefer `./scripts/zig`). The product CLI is Zig-only: shell evaluation runs in-process via `shell_engine` (no Rust toolchain or `orca-daemon` companion). `./scripts/build-all.sh` and `./scripts/zig build` both produce `./zig-out/bin/ryk` (and `orca` compat alias).

## Release Artifacts

Release helpers build checksum-covered **ryk** archives (primary `ryk-v*`; dual-publish `orca-v*` when enabled) into `dist/`:

```sh
./scripts/build-release.sh
(cd dist && shasum -a 256 -c checksums.txt)
```

Windows archive smoke-test helper:

```powershell
.\scripts\build-release.ps1 -ArchiveOnly
.\scripts\install.ps1 -Version 1.1.0 -ArtifactDir .\dist -InstallDir "$env:USERPROFILE\bin"
```

`scripts/build-release.ps1` does not produce `release-manifest.json` or rendered package manifests. Use `scripts/build-release.sh` plus `scripts/verify-release.sh` for production release verification.

Do not use an install-only path without verification. Download the archive, verify `dist/checksums.txt`, inspect the install script if using it, then install.

## Homebrew

Homebrew distribution uses the `christopherkarani/homebrew-orca` tap and the GitHub Release archives from `christopherkarani/Orca`.

Maintainer release flow:

```sh
./scripts/build-release.sh
brew audit --strict --online dist/package-manifests/homebrew/Formula/orca.rb
brew install --build-from-source dist/package-manifests/homebrew/Formula/orca.rb
brew test dist/package-manifests/homebrew/Formula/orca.rb
```

User install after the tap repository is published:

```sh
brew tap christopherkarani/orca
brew install --formula ryk   # or: brew install --formula orca (compat)
ryk plugin install hermes --yes
```

## Manual Artifact Install

1. Download or build the archive for your OS and CPU.
2. Verify its SHA-256 digest against `dist/checksums.txt`.
3. Extract the archive, or run `scripts/install.sh` / `scripts/install.ps1` to install the binary and runtime assets together.
4. Paste the activation command printed by the installer (the highlighted `eval "$(… env …)"` block on Unix). It invokes the absolute installed binary, so it also works in the shell that launched a first-time install before `ryk` is on `PATH`. Then run `ryk start` to get protected (policy + host integrations).

The curl installer (`scripts/install.sh`) prints a step-based receipt (brand header, phases, activation hero). It honors `NO_COLOR` and `RYK_INSTALL_QUIET=1` / `ORCA_INSTALL_QUIET=1` (non-error silence; activation line still printed). Host configuration is never performed by the installer — that remains `ryk start` (orca alias works).

Windows (`scripts/install.ps1`) shares the same core contracts (checksum verify, binary + runtime install, structured failures, quiet mode, activation handoff) with a smaller surface: it does not manage `PATH` (use your profile / user PATH) and does not soft-warn on a missing dashboard UI bundle.

## Package Templates

Templates exist under `packaging/`:

- Homebrew: `packaging/homebrew/Formula/ryk.rb` (primary), `orca.rb` (compat)
- Scoop: `packaging/scoop/ryk.json` (primary), `orca.json` (compat)
- WinGet: `packaging/winget/ryk.yaml` (primary), `orca.yaml` (compat)
- npm wrapper: `packaging/npm/package.json`
- Docker: `packaging/docker/Dockerfile`

They contain release-time placeholders until artifacts and checksums are generated.

## macOS Notes

macOS builds provide process supervision, environment filtering, staged writes, PATH/shell shims, MCP stdio proxying, audit/replay, and network policy decisions. Proxy route forcing is available per session when the proxy backend and OS sandbox attach are both active; proxy startup alone is not route forcing. OS filesystem isolation for protected agent children is available through the run engine (`orca <agent>`; advanced flag: `orca run --os-sandbox auto|on|off`) using Seatbelt on product majors **14–26** (capability/version gate). **CI attach evidence** is currently **macos-14** (plus Linux amd64 for Landlock); other majors are local until freeze CI covers them. Doctor capability probes are not a live session claim; session-attach is proven only after child apply-before-exec succeeds.

## Linux Notes

Linux builds use backend detection for namespace, seccomp, Landlock, cgroup, and process supervision capability. OS filesystem isolation for protected agent children is available through the run engine (`orca <agent>`; advanced flag: `orca run --os-sandbox auto|on|off`) using Landlock when the host supports **ABI ≥ 1** (kernel **5.13+**). **CI attach evidence** is currently **linux amd64**; other cells are local until freeze jobs exist. Doctor Landlock probes are capability evidence only and never alone authorize a session `active` claim. `--os-sandbox on` fails closed when attach cannot complete.

## Windows Notes

Windows builds use `ryk.exe` (`orca.exe` alias), PowerShell scripts, path normalization, command wrappers, and process cleanup support where implemented. Transparent filesystem and network enforcement are limited; there is no kernel OS filesystem session-attach backend on Windows in this release.
