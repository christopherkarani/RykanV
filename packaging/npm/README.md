# @rykan/ryk (npm launcher)

npm launcher template for the Zig-built **ryk** CLI (shell evaluation is in-process Zig `shell_engine`).

- **Primary package name:** `@rykan/ryk`
- **Bin:** `ryk`
- **Scope:** `@rykan`
- **Artifacts:** downloads the canonical `ryk-v{version}-*` release archive

> **Do not publish** this template directory while checksums are still `PLACEHOLDER_*`.
> Publish only the **rendered** package under `dist/package-manifests/npm/` after `build-release.sh` / `cut-release.sh`.

The launcher fails closed when rendered release checksums are missing or do not match the downloaded archive. Publish only after release automation has rendered and verified the package metadata.

Primary publisher: `./scripts/cut-release.sh --live` (see `docs/dev/cut-release-shortcut.md`).

## Install (after publish)

```sh
npm install -g @rykan/ryk
ryk version
```
