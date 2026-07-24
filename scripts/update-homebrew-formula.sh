#!/usr/bin/env sh
set -eu

VERSION="${1:-${RYK_VERSION:-${ORCA_VERSION:-}}}"
HOMEBREW_TAP_DIR="${RYK_HOMEBREW_TAP_DIR:-${ORCA_HOMEBREW_TAP_DIR:-${HOME}/code/homebrew-orca}}"
FORMULA_OUT="${ORCA_HOMEBREW_FORMULA:-${RYK_HOMEBREW_FORMULA:-${HOMEBREW_TAP_DIR}/Formula/ryk.rb}}"
TEMPLATE="${ORCA_HOMEBREW_TEMPLATE:-${RYK_HOMEBREW_TEMPLATE:-packaging/homebrew/Formula/ryk.rb}}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ryk-homebrew.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'update-homebrew-formula: %s\n' "$1" >&2
  exit 1
}

[ -n "$VERSION" ] || fail "usage: $0 <version>  (or set RYK_VERSION / ORCA_VERSION)"
[ -f "$TEMPLATE" ] || fail "homebrew template not found: $TEMPLATE"

BASE_URL="https://github.com/christopherkarani/Orca/releases/download/v${VERSION}"
DIST_DIR="${RYK_DIST_DIR:-${ORCA_DIST_DIR:-}}"

if [ -n "$DIST_DIR" ]; then
  printf 'Using local release assets for ryk %s from %s...\n' "$VERSION" "$DIST_DIR"
else
  printf 'Downloading release assets for ryk %s...\n' "$VERSION"
fi

for plat in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do
  # Prefer primary ryk-v* artifacts; fall back to dual-published orca-v*.
  artifact="ryk-v${VERSION}-${plat}.tar.gz"
  legacy="orca-v${VERSION}-${plat}.tar.gz"
  output="${TMP_DIR}/${artifact}"

  printf '  → %s\n' "$artifact"
  if [ -n "$DIST_DIR" ] && [ -f "${DIST_DIR}/${artifact}" ]; then
    cp "${DIST_DIR}/${artifact}" "$output"
  elif [ -n "$DIST_DIR" ] && [ -f "${DIST_DIR}/${legacy}" ]; then
    cp "${DIST_DIR}/${legacy}" "$output"
  elif command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL -o "$output" "${BASE_URL}/${artifact}"; then
      curl -fsSL -o "$output" "${BASE_URL}/${legacy}" || fail "failed to download ryk or orca artifact for $plat"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -q -O "$output" "${BASE_URL}/${artifact}"; then
      wget -q -O "$output" "${BASE_URL}/${legacy}" || fail "failed to download ryk or orca artifact for $plat"
    fi
  else
    fail "curl or wget is required"
  fi
done

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

darwin_arm64="$(sha256_file "${TMP_DIR}/ryk-v${VERSION}-darwin-arm64.tar.gz")"
darwin_amd64="$(sha256_file "${TMP_DIR}/ryk-v${VERSION}-darwin-amd64.tar.gz")"
linux_arm64="$(sha256_file "${TMP_DIR}/ryk-v${VERSION}-linux-arm64.tar.gz")"
linux_amd64="$(sha256_file "${TMP_DIR}/ryk-v${VERSION}-linux-amd64.tar.gz")"

printf 'Merging version and checksums into formula template...\n'

mkdir -p "$(dirname "$FORMULA_OUT")"
cp "$TEMPLATE" "$FORMULA_OUT"

sed \
  -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
  -e "s/{{DARWIN_ARM64_SHA256}}/${darwin_arm64}/" \
  -e "s/{{DARWIN_AMD64_SHA256}}/${darwin_amd64}/" \
  -e "s/{{LINUX_ARM64_SHA256}}/${linux_arm64}/" \
  -e "s/{{LINUX_AMD64_SHA256}}/${linux_amd64}/" \
  "$FORMULA_OUT" > "${FORMULA_OUT}.tmp"
mv "${FORMULA_OUT}.tmp" "$FORMULA_OUT"

printf 'Formula written to %s\n' "$FORMULA_OUT"

formula_basename="$(basename "$FORMULA_OUT")"
if [ -d "${HOMEBREW_TAP_DIR}/.git" ]; then
  cd "$HOMEBREW_TAP_DIR"
  git add "Formula/${formula_basename}"
  if git diff --cached --quiet; then
    printf 'No changes to commit.\n'
  else
    git commit -m "Update ${formula_basename%.rb} to ${VERSION}"
    printf 'Committed. Run `git push` to publish.\n'
  fi
else
  printf 'Note: %s is not a git repo. Skipping commit.\n' "$HOMEBREW_TAP_DIR"
fi
