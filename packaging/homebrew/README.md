# ryk Homebrew Tap

This directory is the source for the `christopherkarani/homebrew-orca` tap
(tap name kept for dual-name window; formula primary is **ryk**).

## Release flow

**Preferred:** Mac cut-release updates the tap automatically after GitHub assets exist:

```sh
./scripts/cut-release.sh --bump patch --live
# requires clone at ~/code/homebrew-orca or RYK_HOMEBREW_TAP_DIR
```

Manual path:

```sh
./scripts/build-release.sh
# Ensure release assets are uploaded to GitHub before updating the formula
./scripts/update-homebrew-formula.sh
brew audit --strict --online packaging/homebrew/Formula/ryk.rb
brew install --formula packaging/homebrew/Formula/ryk.rb
brew test packaging/homebrew/Formula/ryk.rb
# Compat formula (existing taps): packaging/homebrew/Formula/orca.rb
```

## Publish flow

1. Create or update `https://github.com/christopherkarani/homebrew-orca`.
2. Prefer `cut-release.sh` / `update-homebrew-formula.sh` writing into the tap clone (`RYK_HOMEBREW_TAP_DIR`, default `~/code/homebrew-orca`).
3. Or copy rendered `Formula/ryk.rb` (+ `orca.rb` compat) into the tap and push after GitHub Release assets exist.
4. Verify formula sha256 values match `dist/checksums.txt`.

## User install

```sh
brew tap christopherkarani/orca
brew install --formula orca
orca version
orca doctor
```
