# Release

## Primary path: Mac cut-release

Ship from a clean `main` on a Mac using **`scripts/cut-release.sh`** (optional Shortcuts.app UX).

Full guide: [`docs/dev/cut-release-shortcut.md`](cut-release-shortcut.md).

```sh
./scripts/cut-release.sh --bump patch --plan-only   # preview
./scripts/cut-release.sh --bump patch --live        # gate + build + GitHub + npm + Homebrew
```

What it does:

1. Preflight (clean main, Docker, `gh`, `npm`, Zig pin, Homebrew tap clone)
2. Semver bump (patch / minor / major) and auto release notes (CHANGELOG + GH body)
3. `./scripts/verify-pre-merge.sh`
4. Local multi-arch build (Darwin Zig + Linux Docker) via `build-release.sh`
5. GitHub Release with assets (including `checksums.txt`)
6. npm: `@orca-sec/ryk` (rendered checksums) + integration plugins + `orca-pi`
7. Push formulas to `christopherkarani/homebrew-orca`

CI `release.yml` on `v*` tags **skips** when the release already has `checksums.txt`. Use **workflow_dispatch** only as a backup cut.

## Legacy / lower-level scripts

| Script | Role |
|--------|------|
| `scripts/build-release.sh` | Build archives, checksums, package manifests |
| `scripts/build-linux-release-docker.sh` | Stage Linux `ryk` bins for Mac hosts |
| `scripts/verify-release.sh` | Artifact contract |
| `scripts/render-package-manifests.sh` | npm / Homebrew / Scoop / WinGet from checksums |
| `scripts/update-homebrew-formula.sh` | Write tap formula + optional commit |
| `scripts/release-dry-run.sh` | Host-only dry-run build + verify |

## Product notes

Keep the Zig version pinned (`.zigversion`). Generated release archives, SBOMs, and checksums under `dist/` are not committed. Never publish `packaging/npm` while checksums are still `PLACEHOLDER_*` — only publish the **rendered** tree under `dist/package-manifests/npm`.
