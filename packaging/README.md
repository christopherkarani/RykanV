# Packaging inputs

The canonical binary is `ryk`. Release artifacts use the form
`ryk-v{version}-{os}-{arch}` and are published on GitHub for the checksum-
verified curl installer.

The `packaging/` tree contains build and container inputs used by the release
build. npm, Homebrew, Scoop, and WinGet are legacy templates and are not active
distribution channels.

Use `scripts/cut-release.sh` for the supported release path. Read
[`docs/dev/release.md`](../docs/dev/release.md) first.

```sh
./scripts/cut-release.sh --version X.Y.Z --plan-only
```
