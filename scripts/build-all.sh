#!/usr/bin/env bash
# Build the Zig CLI (single-binary product path).
#
# Usage:
#   ./scripts/build-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "[build-all] Building Zig binary..."
"${SCRIPT_DIR}/zig" build

echo "[build-all] Done."
echo ""
echo "  Zig binary:    zig-out/bin/ryk"
echo "  Note: ryk-daemon (former orca-rs crate) was removed; shell eval is in-process Zig."
