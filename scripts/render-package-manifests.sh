#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${RYK_VERSION:-${ORCA_VERSION:-$(tr -d '[:space:]' < "${SCRIPT_DIR}/../VERSION")}}"
DIST_DIR="${RYK_DIST_DIR:-${ORCA_DIST_DIR:-dist}}"
OUT_DIR="${RYK_PACKAGE_MANIFEST_DIR:-${ORCA_PACKAGE_MANIFEST_DIR:-${DIST_DIR}/package-manifests}}"
CHECKSUMS="${DIST_DIR}/checksums.txt"

fail() {
  printf 'render-package-manifests: %s\n' "$1" >&2
  exit 1
}

checksum_for() {
  name="$1"
  awk -v name="$name" '$2 == name {print $1}' "$CHECKSUMS"
}

require_sha256() {
  label="$1"
  value="$2"
  printf '%s' "$value" | awk -v label="$label" '
    length($0) == 64 && $0 ~ /^[0-9a-fA-F]+$/ { ok = 1 }
    END { if (!ok) { printf "render-package-manifests: invalid %s checksum\n", label > "/dev/stderr"; exit 1 } }
  '
}

[ -f "$CHECKSUMS" ] || fail "checksums not found: $CHECKSUMS"

# Prefer primary ryk-v* checksums; fall back to dual-published orca-v*.
darwin_amd64="$(checksum_for "ryk-v${VERSION}-darwin-amd64.tar.gz")"
[ -n "$darwin_amd64" ] || darwin_amd64="$(checksum_for "orca-v${VERSION}-darwin-amd64.tar.gz")"
darwin_arm64="$(checksum_for "ryk-v${VERSION}-darwin-arm64.tar.gz")"
[ -n "$darwin_arm64" ] || darwin_arm64="$(checksum_for "orca-v${VERSION}-darwin-arm64.tar.gz")"
linux_amd64="$(checksum_for "ryk-v${VERSION}-linux-amd64.tar.gz")"
[ -n "$linux_amd64" ] || linux_amd64="$(checksum_for "orca-v${VERSION}-linux-amd64.tar.gz")"
linux_arm64="$(checksum_for "ryk-v${VERSION}-linux-arm64.tar.gz")"
[ -n "$linux_arm64" ] || linux_arm64="$(checksum_for "orca-v${VERSION}-linux-arm64.tar.gz")"

[ -n "$darwin_amd64" ] || fail "missing darwin amd64 checksum"
[ -n "$darwin_arm64" ] || fail "missing darwin arm64 checksum"
[ -n "$linux_amd64" ] || fail "missing linux amd64 checksum"
[ -n "$linux_arm64" ] || fail "missing linux arm64 checksum"
require_sha256 "darwin amd64" "$darwin_amd64"
require_sha256 "darwin arm64" "$darwin_arm64"
require_sha256 "linux amd64" "$linux_amd64"
require_sha256 "linux arm64" "$linux_arm64"

rm -rf "$OUT_DIR"
mkdir -p \
  "$OUT_DIR/homebrew/Formula" \
  "$OUT_DIR/npm/bin" \
  "$OUT_DIR/scoop" \
  "$OUT_DIR/winget"

# Primary Homebrew formula: ryk.rb
if [ -f packaging/homebrew/Formula/ryk.rb ]; then
  cp packaging/homebrew/Formula/ryk.rb "$OUT_DIR/homebrew/Formula/ryk.rb"
  ORCA_VERSION="$VERSION" RYK_VERSION="$VERSION" \
  ORCA_DIST_DIR="$DIST_DIR" RYK_DIST_DIR="$DIST_DIR" \
  ORCA_HOMEBREW_FORMULA="$OUT_DIR/homebrew/Formula/ryk.rb" \
  ORCA_HOMEBREW_TEMPLATE="packaging/homebrew/Formula/ryk.rb" \
    ./scripts/update-homebrew-formula.sh >/dev/null
fi

# Compat formula path kept for existing taps during dual-name window.
if [ -f packaging/homebrew/Formula/orca.rb ]; then
  cp packaging/homebrew/Formula/orca.rb "$OUT_DIR/homebrew/Formula/orca.rb"
  ORCA_VERSION="$VERSION" RYK_VERSION="$VERSION" \
  ORCA_DIST_DIR="$DIST_DIR" RYK_DIST_DIR="$DIST_DIR" \
  ORCA_HOMEBREW_FORMULA="$OUT_DIR/homebrew/Formula/orca.rb" \
  ORCA_HOMEBREW_TEMPLATE="packaging/homebrew/Formula/orca.rb" \
    ./scripts/update-homebrew-formula.sh >/dev/null
fi

sed \
  -e "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" \
  -e "s|https://github.com/christopherkarani/Orca/releases/download/v[^\"]*|https://github.com/christopherkarani/Orca/releases/download/v${VERSION}|" \
  -e "s/PLACEHOLDER_DARWIN_AMD64_SHA256/${darwin_amd64}/g" \
  -e "s/PLACEHOLDER_DARWIN_ARM64_SHA256/${darwin_arm64}/g" \
  -e "s/PLACEHOLDER_LINUX_AMD64_SHA256/${linux_amd64}/g" \
  -e "s/PLACEHOLDER_LINUX_ARM64_SHA256/${linux_arm64}/g" \
  -e "s/PLACEHOLDER checksums/verified checksums/g" \
  packaging/npm/package.json > "$OUT_DIR/npm/package.json"
if [ -f packaging/npm/bin/ryk.js ]; then
  cp packaging/npm/bin/ryk.js "$OUT_DIR/npm/bin/ryk.js"
fi
if [ -f packaging/npm/bin/orca.js ]; then
  cp packaging/npm/bin/orca.js "$OUT_DIR/npm/bin/orca.js"
fi
cp packaging/npm/README.md "$OUT_DIR/npm/README.md"

if [ -f packaging/scoop/ryk.json ]; then
  sed \
    -e "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" \
    -e "s|v[0-9][0-9.]*|v${VERSION}|g" \
    packaging/scoop/ryk.json > "$OUT_DIR/scoop/ryk.json" || true
fi
if [ -f packaging/winget/ryk.yaml ]; then
  sed \
    -e "s/PackageVersion: .*/PackageVersion: ${VERSION}/" \
    packaging/winget/ryk.yaml > "$OUT_DIR/winget/ryk.yaml" || true
fi

for rendered in \
  "$OUT_DIR/homebrew/Formula/ryk.rb" \
  "$OUT_DIR/homebrew/Formula/orca.rb" \
  "$OUT_DIR/npm/package.json"
do
  [ -f "$rendered" ] || continue
  if grep -q 'PLACEHOLDER' "$rendered"; then
    fail "rendered manifest still contains PLACEHOLDER: $rendered"
  fi
done

printf 'Rendered package manifests in %s\n' "$OUT_DIR"
