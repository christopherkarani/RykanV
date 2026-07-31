#!/usr/bin/env sh
set -eu

DIST_DIR="${RYK_DIST_DIR:-dist/npm}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
case "${DIST_DIR}" in
  /*) DIST_DIR_ABS="${DIST_DIR}" ;;
  *) DIST_DIR_ABS="${REPO_ROOT}/${DIST_DIR}" ;;
esac

PACKAGES="
integrations/opencode-plugin
integrations/openclaw-plugin
ryk-pi
"

rm -rf "${DIST_DIR_ABS}"
mkdir -p "${DIST_DIR_ABS}"

CHECKSUMS_FILE="${DIST_DIR_ABS}/ryk-npm-plugin-checksums.txt"
: > "${CHECKSUMS_FILE}"

TOTAL_ISSUES=0

for rel_path in ${PACKAGES}; do
  PACKAGE_DIR="${REPO_ROOT}/${rel_path}"

  if [ ! -d "${PACKAGE_DIR}" ]; then
    echo "WARNING: Package directory not found: ${PACKAGE_DIR}" >&2
    continue
  fi

  PKG_NAME="$(node -p "require('${PACKAGE_DIR}/package.json').name")"
  VERSION="$(node -p "require('${PACKAGE_DIR}/package.json').version")"
  SAFE_NAME="$(printf '%s' "$PKG_NAME" | tr '/@' '--' | sed 's/^--//')"

  echo ""
  echo "========================================"
  echo "Packaging ${PKG_NAME} v${VERSION}..."
  echo "========================================"

  if [ -f "${PACKAGE_DIR}/dist/index.js" ]; then
    :
  elif [ -f "${PACKAGE_DIR}/extensions/ryk.ts" ]; then
    :
  else
    echo "ERROR: no packable entry found in ${PACKAGE_DIR} (expected dist/index.js or extensions/ryk.ts)" >&2
    exit 1
  fi

  (cd "${PACKAGE_DIR}" && npm pack --dry-run)

  PKG_TARBALL="${DIST_DIR_ABS}/${SAFE_NAME}-v${VERSION}.tgz"
  (cd "${PACKAGE_DIR}" && npm pack --pack-destination "${DIST_DIR_ABS}")

  BUILT_TARBALL="${DIST_DIR_ABS}/$(node -p "require('${PACKAGE_DIR}/package.json').name.replace('@','').replace('/','-')")-${VERSION}.tgz"
  if [ ! -f "${BUILT_TARBALL}" ]; then
    BUILT_TARBALL="${DIST_DIR_ABS}/$(basename "${rel_path}")-${VERSION}.tgz"
  fi
  if [ -f "${BUILT_TARBALL}" ] && [ "${BUILT_TARBALL}" != "${PKG_TARBALL}" ]; then
    mv "${BUILT_TARBALL}" "${PKG_TARBALL}"
  fi

  if [ ! -f "${PKG_TARBALL}" ]; then
    for candidate in "${DIST_DIR_ABS}"/*.tgz; do
      [ -f "$candidate" ] || continue
      mv "$candidate" "${PKG_TARBALL}"
      break
    done
  fi

  if [ ! -f "${PKG_TARBALL}" ]; then
    echo "ERROR: Failed to create tarball for ${PKG_NAME}" >&2
    exit 1
  fi

  echo "Created ${PKG_TARBALL}"

  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "${PKG_TARBALL}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "${PKG_TARBALL}" | awk '{print $1}')"
  else
    echo "ERROR: sha256sum or shasum is required" >&2
    exit 1
  fi
  printf '%s  %s\n' "$hash" "$(basename "$PKG_TARBALL")" >> "${CHECKSUMS_FILE}"

  echo "Scanning ${PKG_NAME} tarball for potential secrets..."
  SCAN_ISSUES=0

  tmpdir="$(mktemp -d)"
  tar -xzf "${PKG_TARBALL}" -C "$tmpdir"
  if grep -riE "(api_key|apikey|secret|token|password|private_key|privkey)[[:space:]]*[:=][[:space:]]*[\"']?[a-zA-Z0-9_/-]{16,}" "$tmpdir" 2>/dev/null | grep -v "fake_" | grep -v "example" | grep -v "placeholder" | grep -v "your_"; then
    echo "WARNING: Potential secret pattern in ${PKG_NAME} tarball" >&2
    SCAN_ISSUES=$((SCAN_ISSUES + 1))
  fi
  rm -rf "$tmpdir"

  if [ "$SCAN_ISSUES" -eq 0 ]; then
    echo "Secret scan passed for ${PKG_NAME}."
  else
    echo "WARNING: Secret scan found ${SCAN_ISSUES} potential issues in ${PKG_NAME}. Review before release." >&2
    TOTAL_ISSUES=$((TOTAL_ISSUES + SCAN_ISSUES))
  fi
done

echo ""
echo "========================================"
echo "NPM packaging complete. Artifacts in ${DIST_DIR_ABS}:"
echo "========================================"
ls -la "${DIST_DIR_ABS}"
echo ""
echo "Checksums:"
cat "${CHECKSUMS_FILE}"

if [ "$TOTAL_ISSUES" -eq 0 ]; then
  echo ""
  echo "All secret scans passed."
else
  echo ""
  echo "Total secret scan issues: ${TOTAL_ISSUES}. Failing release packaging." >&2
  exit 1
fi
