#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${RYK_PLUGIN_VERSION:-${RYK_VERSION:-$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null || printf '1.2.0')}}"
DIST_DIR="${RYK_DIST_DIR:-dist/plugins}"
case "${DIST_DIR}" in
  /*) DIST_DIR_ABS="${DIST_DIR}" ;;
  *) DIST_DIR_ABS="${REPO_ROOT}/${DIST_DIR}" ;;
esac

echo "Packaging ryk plugins v${VERSION}..."

rm -rf "${DIST_DIR_ABS}"
mkdir -p "${DIST_DIR_ABS}"

# Package Codex plugin
echo "Packaging Codex plugin..."
CODEX_PLUGIN_DIR="${REPO_ROOT}/integrations/codex-plugin"
CODEX_ZIP="${DIST_DIR_ABS}/ryk-codex-plugin-v${VERSION}.zip"

if [ -d "${CODEX_PLUGIN_DIR}" ]; then
  (cd "${CODEX_PLUGIN_DIR}" && zip -qr "${CODEX_ZIP}" \
    .codex-plugin/plugin.json \
    skills/ \
    hooks/ \
    README.md \
    -x "*.DS_Store" \
    -x "*.mcp.json" \
    -x "*drone*" \
    -x "*build*" \
    -x "*tmp*" \
    -x "*secret*")
  echo "Created ${CODEX_ZIP}"
else
  echo "ERROR: Codex plugin directory not found: ${CODEX_PLUGIN_DIR}" >&2
  exit 1
fi

# Package Claude Code plugin
echo "Packaging Claude Code plugin..."
CLAUDE_PLUGIN_DIR="${REPO_ROOT}/integrations/claude-code-plugin"
CLAUDE_ZIP="${DIST_DIR_ABS}/ryk-claude-code-plugin-v${VERSION}.zip"

if [ -d "${CLAUDE_PLUGIN_DIR}" ]; then
  (cd "${CLAUDE_PLUGIN_DIR}" && zip -qr "${CLAUDE_ZIP}" \
    .claude-plugin/plugin.json \
    skills/ \
    hooks/ \
    README.md \
    -x "*.DS_Store" \
    -x "*.mcp.json" \
    -x "*drone*" \
    -x "*build*" \
    -x "*tmp*" \
    -x "*secret*")
  echo "Created ${CLAUDE_ZIP}"
else
  echo "ERROR: Claude Code plugin directory not found: ${CLAUDE_PLUGIN_DIR}" >&2
  exit 1
fi

# Package OpenCode plugin
echo "Packaging OpenCode plugin..."
OPENCODE_PLUGIN_DIR="${REPO_ROOT}/integrations/opencode-plugin"
OPENCODE_ZIP="${DIST_DIR_ABS}/ryk-opencode-plugin-v${VERSION}.zip"

if [ -d "${OPENCODE_PLUGIN_DIR}" ]; then
  (cd "${OPENCODE_PLUGIN_DIR}" && zip -qr "${OPENCODE_ZIP}" \
    orca.ts \
    README.md \
    package.json \
    examples/ \
    -x "*.DS_Store" \
    -x "*.mcp.json" \
    -x "*drone*" \
    -x "*build*" \
    -x "*tmp*" \
    -x "*secret*")
  echo "Created ${OPENCODE_ZIP}"
else
  echo "WARNING: OpenCode plugin directory not found: ${OPENCODE_PLUGIN_DIR}" >&2
fi

# Package Claude marketplace catalog
echo "Packaging Claude marketplace catalog..."
MARKETPLACE_DIR="${REPO_ROOT}/integrations/claude-marketplace"
MARKETPLACE_ZIP="${DIST_DIR_ABS}/ryk-claude-marketplace-v${VERSION}.zip"

if [ -d "${MARKETPLACE_DIR}" ]; then
  (cd "${MARKETPLACE_DIR}" && zip -qr "${MARKETPLACE_ZIP}" \
    .claude-plugin/marketplace.json \
    README.md \
    -x "*.DS_Store" \
    -x "*.mcp.json" \
    -x "*drone*" \
    -x "*build*" \
    -x "*tmp*" \
    -x "*secret*")
  echo "Created ${MARKETPLACE_ZIP}"
else
  echo "WARNING: Claude marketplace directory not found: ${MARKETPLACE_DIR}" >&2
fi

# Generate checksums
echo "Generating checksums..."
CHECKSUMS_FILE="${DIST_DIR_ABS}/ryk-plugin-checksums.txt"

tmp="${CHECKSUMS_FILE}.tmp"
: > "$tmp"

for file in "${DIST_DIR_ABS}"/*.zip; do
  [ -f "$file" ] || continue
  name="$(basename "$file")"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    echo "ERROR: sha256sum or shasum is required" >&2
    rm -f "$tmp"
    exit 1
  fi
  printf '%s  %s\n' "$hash" "$name" >> "$tmp"
done

[ -s "$tmp" ] || {
  echo "ERROR: no plugin artifacts found in ${DIST_DIR_ABS}" >&2
  rm -f "$tmp"
  exit 1
}

mv "$tmp" "$CHECKSUMS_FILE"
echo "Created ${CHECKSUMS_FILE}"

# Verify no secrets in artifacts
echo "Scanning artifacts for potential secrets..."
SECRET_PATTERNS="password|secret|token|api_key|apikey|private_key|privkey|aws_access|aws_secret|github_token|gcp_key|azure_key"
SCAN_ISSUES=0

for file in "${DIST_DIR_ABS}"/*.zip; do
  [ -f "$file" ] || continue
  # Use unzip -l to list contents, grep for suspicious patterns
  if unzip -l "$file" | grep -iE "${SECRET_PATTERNS}" | grep -v "fake_" | grep -v "README" | grep -v "SKILL.md" | grep -v "hooks.json" | grep -v "plugin.json" | grep -v "marketplace.json" | grep -v "secret_" | grep -v "secret-"; then
    echo "WARNING: Potential secret-like filename in ${file}" >&2
    SCAN_ISSUES=$((SCAN_ISSUES + 1))
  fi
done

# Check actual file contents for real secrets (not fake test values)
for file in "${DIST_DIR_ABS}"/*.zip; do
  [ -f "$file" ] || continue
  # Extract and scan (to temp)
  tmpdir="$(mktemp -d)"
  unzip -q "$file" -d "$tmpdir"
  if grep -riE "(api_key|apikey|secret|token|password|private_key|privkey)[[:space:]]*[:=][[:space:]]*[\"']?[a-zA-Z0-9_/-]{16,}" "$tmpdir" 2>/dev/null | grep -v "fake_" | grep -v "example" | grep -v "placeholder" | grep -v "your_"; then
    echo "WARNING: Potential secret pattern in ${file}" >&2
    SCAN_ISSUES=$((SCAN_ISSUES + 1))
  fi
  rm -rf "$tmpdir"
done

if [ "$SCAN_ISSUES" -eq 0 ]; then
  echo "Secret scan passed. No obvious secrets found in artifacts."
else
  echo "Secret scan found ${SCAN_ISSUES} potential issues. Failing release packaging." >&2
  exit 1
fi

echo ""
echo "Plugin packaging complete. Artifacts in ${DIST_DIR_ABS}:"
ls -la "${DIST_DIR_ABS}"
echo ""
cat "${CHECKSUMS_FILE}"
