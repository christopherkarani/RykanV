#!/usr/bin/env sh
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="${REPO_ROOT}/integrations/opencode-plugin"
RYK_BIN="${REPO_ROOT}/zig-out/bin/ryk"
FAILED=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

echo "=== P08B — ryk-opencode-plugin npm package tests ==="
echo ""

# 1. package.json exists and is valid JSON
echo "1. package.json validation"
if [ -f "${PACKAGE_DIR}/package.json" ]; then
  if python3 -m json.tool "${PACKAGE_DIR}/package.json" >/dev/null 2>&1; then
    pass "package.json is valid JSON"
  else
    fail "package.json is invalid JSON"
  fi
else
  fail "package.json does not exist"
fi

# 2. package name is ryk-opencode-plugin
echo "2. Package name"
PKG_NAME=$(python3 -c "import json; print(json.load(open('${PACKAGE_DIR}/package.json'))['name'])")
if [ "$PKG_NAME" = "ryk-opencode-plugin" ]; then
  pass "Package name is ryk-opencode-plugin"
else
  fail "Package name is '$PKG_NAME', expected 'ryk-opencode-plugin'"
fi

# 3. no unsafe install scripts
echo "3. Install scripts safety"
HAS_SCRIPTS=$(python3 -c "import json; d=json.load(open('${PACKAGE_DIR}/package.json')); print('scripts' in d and 'install' in d.get('scripts', {}))")
if [ "$HAS_SCRIPTS" = "False" ]; then
  pass "No unsafe install scripts found"
else
  fail "Unsafe install scripts detected"
fi

# 4. dist/index.js exists
echo "4. Runtime JS output"
if [ -f "${PACKAGE_DIR}/dist/index.js" ]; then
  pass "dist/index.js exists"
else
  fail "dist/index.js missing"
fi

# 5. dist/index.d.ts exists
echo "5. Type declarations"
if [ -f "${PACKAGE_DIR}/dist/index.d.ts" ]; then
  pass "dist/index.d.ts exists"
else
  fail "dist/index.d.ts missing"
fi

# 6. README documents opencode.json usage
echo "6. README npm documentation"
if grep -q 'opencode.json' "${PACKAGE_DIR}/README.md"; then
  pass "README mentions opencode.json"
else
  fail "README missing opencode.json reference"
fi

if grep -q 'ryk-opencode-plugin' "${PACKAGE_DIR}/README.md"; then
  pass "README mentions ryk-opencode-plugin"
else
  fail "README missing ryk-opencode-plugin reference"
fi

# 7. Plugin source calls ryk
echo "7. Plugin source calls ryk"
if grep -Eq "['\"]hook['\"].*['\"]opencode['\"]" "${PACKAGE_DIR}/src/index.ts"; then
  pass "src/index.ts calls ryk hook opencode"
else
  fail "src/index.ts missing ryk hook calls"
fi

# 8. No secrets in plugin source
echo "8. Secret safety"
SECRET_PATTERNS="ghp_ sk- AKIA password123 api_key[[:space:]]*[:=][[:space:]]*[a-zA-Z0-9_/-]{16,}"
if grep -riE "(api_key|apikey|secret|token|password|private_key|privkey)[[:space:]]*[:=][[:space:]]*[\"']?[a-zA-Z0-9_/-]{16,}" "${PACKAGE_DIR}/src" "${PACKAGE_DIR}/dist" 2>/dev/null | grep -v "fake_" | grep -v "example" | grep -v "placeholder" | grep -v "your_" | grep -v "REDACTED"; then
  fail "Potential secret pattern found in plugin files"
else
  pass "No obvious secrets in plugin source"
fi

# 9. No MCP behavior
echo "9. No MCP behavior"
if grep -riq 'mcp' "${PACKAGE_DIR}/src/index.ts" 2>/dev/null; then
  fail "MCP references found in plugin source"
else
  pass "No MCP behavior in plugin source"
fi

# 10. No Zig binary bundling
echo "10. No Zig binary bundling"
if find "${PACKAGE_DIR}" -name 'ryk' -type f -o -name '*.zig' -type f 2>/dev/null | grep -q .; then
  fail "Potential Zig binary or source found in package"
else
  pass "No Zig binary bundled"
fi

# 11. npm pack dry-run succeeds
echo "11. npm pack dry-run"
if (cd "${PACKAGE_DIR}" && npm pack --dry-run >/dev/null 2>&1); then
  pass "npm pack --dry-run succeeds"
else
  fail "npm pack --dry-run failed"
fi

# 12. Package files list is minimal
echo "12. Package file list"
FILE_COUNT=$(cd "${PACKAGE_DIR}" && npm pack --dry-run 2>&1 | grep -c 'Tarball Contents' && cd "${PACKAGE_DIR}" && npm pack --dry-run 2>&1 | grep -E '^npm notice [0-9]+\.' | wc -l || echo 0)
# Just verify it doesn't include source files
if (cd "${PACKAGE_DIR}" && npm pack --dry-run 2>&1 | grep -q 'src/index.ts'); then
  fail "Package includes source TypeScript files"
else
  pass "Package excludes source TypeScript files"
fi

# 13. Required wording in README
echo "13. Required wording"
if grep -q 'The strongest local protection remains running OpenCode through' "${PACKAGE_DIR}/README.md"; then
  pass "README contains required strongest protection wording"
else
  fail "README missing required strongest protection wording"
fi

if grep -q 'The OpenCode plugin does not add MCP server behavior.' "${PACKAGE_DIR}/README.md"; then
  pass "README contains required limitation wording"
else
  fail "README missing required limitation wording"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=== All tests passed ==="
  exit 0
else
  echo "=== $FAILED test(s) failed ==="
  exit 1
fi
