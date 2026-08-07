#!/usr/bin/env bash
# Pre-merge verification: fast gate + full test suite (Zig 0.16.0).
#
# Usage:
#   ./scripts/verify-pre-merge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "[verify-pre-merge] Fast gate"
./scripts/test-fast.sh

echo "[verify-pre-merge] Full test suite (plugins/setup/fuzz)"
./scripts/zig build test

echo "[verify-pre-merge] First-user install and uninstall regressions"
./scripts/install-first-user-regression-test.sh
./scripts/uninstall-first-user-regression-test.sh

echo "[verify-pre-merge] All checks passed."
