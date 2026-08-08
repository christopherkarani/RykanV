# Packaging

The canonical binary is `ryk`. Release artifacts use the form `ryk-v{version}-{os}-{arch}`.

Package templates live under:

- `homebrew/Formula/ryk.rb`
- `scoop/ryk.json`
- `winget/ryk.yaml`
- `npm/package.json`
- `docker/Dockerfile`

The templates contain release-time placeholders until the build produces checksums. `scripts/build-release.sh` renders publishable manifests under `dist/package-manifests/`; `scripts/verify-release.sh` refuses missing or placeholder checksums.

## Release path

Use `scripts/cut-release.sh` for a full maintainer release. Read [`docs/dev/release.md`](../docs/dev/release.md) first.

```sh
./scripts/cut-release.sh --bump patch --plan-only
+```

Do not publish `packaging/npm` or another template directory directly. Publish only rendered manifests after the release checks pass.
