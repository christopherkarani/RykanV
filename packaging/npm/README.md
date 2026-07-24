# @orca-sec/ryk (npm launcher)

npm launcher template for the Zig-built **ryk** CLI (shell evaluation is in-process Zig `shell_engine`).

- **Primary package name:** `@orca-sec/ryk`
- **Bins:** `ryk` (primary), `orca` (compat alias for one major)
- **Scope:** remains `@orca-sec` (do not rename scope in Phase 5a)
- **Artifacts:** downloads `ryk-v{version}-*` release archives (falls back to dual-published `orca-v*` if needed)

> **Do not publish** this template directory while checksums are still `PLACEHOLDER_*`.
> Publish only the **rendered** package under `dist/package-manifests/npm/` after `build-release.sh` / `cut-release.sh`.

Primary publisher: `./scripts/cut-release.sh --live` (see `docs/dev/cut-release-shortcut.md`).

Legacy package name `@orca-sec/orca` is superseded by `@orca-sec/ryk`; keep installs working via the `orca` bin shim during the dual-name window.

## Install (after publish)

```sh
npm install -g @orca-sec/ryk
ryk version
orca version   # same product, compat name
```
