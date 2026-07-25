#!/usr/bin/env bash
# ryk Plugin Baseline Smoke Test
# Safe checks only. No drone hardware. No network. No secrets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORCA_BIN="${REPO_ROOT}/zig-out/bin/orca"

ERRORS=0

log_info() { echo "[INFO]  $1"; }
log_pass() { echo "[PASS]  $1"; }
log_fail() { echo "[FAIL]  $1"; ERRORS=$((ERRORS + 1)); }

cd "${REPO_ROOT}"

log_info "=== ryk Plugin Baseline Smoke Test ==="
log_info "Repo: ${REPO_ROOT}"
log_info "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# 1. Build
log_info "Running zig build..."
if zig build 2>/dev/null; then
    log_pass "zig build"
else
    log_fail "zig build"
fi
echo ""

# 2. Tests
log_info "Running zig build test..."
if zig build test 2>/dev/null; then
    log_pass "zig build test"
else
    log_fail "zig build test"
fi
echo ""

# 3. CLI smoke tests
log_info "Running CLI smoke tests..."

if [[ -x "${ORCA_BIN}" ]]; then
    if "${ORCA_BIN}" --help >/dev/null 2>&1; then
        log_pass "orca --help"
    else
        log_fail "orca --help"
    fi

    if "${ORCA_BIN}" version >/dev/null 2>&1; then
        log_pass "orca version"
    else
        log_fail "orca version"
    fi

    if "${ORCA_BIN}" doctor >/dev/null 2>&1; then
        log_pass "orca doctor"
    else
        log_fail "orca doctor"
    fi

    if "${ORCA_BIN}" redteam --ci >/dev/null 2>&1; then
        log_pass "orca redteam --ci"
    else
        log_fail "orca redteam --ci"
    fi
else
    log_fail "orca binary not found at ${ORCA_BIN}"
fi
echo ""

# 5. Check baseline docs exist
log_info "Checking baseline docs..."

if [[ -f "${REPO_ROOT}/docs/integrations/current-baseline.md" ]]; then
    log_pass "docs/integrations/current-baseline.md exists"
else
    log_fail "docs/integrations/current-baseline.md missing"
fi
echo ""

# 6. Packaged install DX smoke
log_info "Running install DX smoke test..."
if [[ -x "${REPO_ROOT}/scripts/install-dx-smoke-test.sh" ]]; then
    if "${REPO_ROOT}/scripts/install-dx-smoke-test.sh"; then
        log_pass "install-dx-smoke-test.sh"
    else
        log_fail "install-dx-smoke-test.sh"
    fi
else
    log_fail "scripts/install-dx-smoke-test.sh missing"
fi
echo ""

# Summary
log_info "=== Smoke Test Summary ==="
if [[ ${ERRORS} -eq 0 ]]; then
    echo "All checks passed."
    exit 0
else
    echo "${ERRORS} check(s) failed."
    exit 1
fi
