#!/usr/bin/env bash
# Fast compile-only gates for local iteration (Zig 0.16.0).
#
# Prefer this while editing Zig sources: compile first, run tests only when needed.
# Always uses pinned ./scripts/zig with incremental compilation.
#
# Compile-only modes use the default job count (faster on multi-core hosts).
# Run modes force -j1 so test binaries stay serial (parallel runs have hung
# with no output on some hosts — see build.zig test-fast comments).
#
# Usage:
#   ./scripts/compile-fast.sh              # default: check (CLI only)
#   ./scripts/compile-fast.sh check        # compile ryk executable
#   ./scripts/compile-fast.sh test-lib     # compile ryk lib test binary (largest test-fast piece)
#   ./scripts/compile-fast.sh test-fast    # compile all test-fast artifacts (matches test-fast set)
#   ./scripts/compile-fast.sh test-lib-run # compile + run lib tests (serial)
#   ./scripts/compile-fast.sh test-fast-run
#
# See Agents.md → "Verification gates" for when to use each mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Incremental compile; parallel jobs for compile-only. Serial (-j1) for run modes.
ZIG_BUILD_COMPILE=(./scripts/zig build -fincremental -Dincremental=true)
ZIG_BUILD_RUN=(./scripts/zig build -fincremental -j1 -Dincremental=true)

mode="${1:-check}"
start_ts=$(date +%s)

case "${mode}" in
  check)
    echo "[compile-fast] check (ryk CLI only)"
    "${ZIG_BUILD_COMPILE[@]}" check
    ;;
  test-lib)
    echo "[compile-fast] compile-test-lib (ryk lib tests, no run)"
    "${ZIG_BUILD_COMPILE[@]}" compile-test-lib
    ;;
  test-fast)
    echo "[compile-fast] compile-test-fast (test-fast artifacts, no run)"
    "${ZIG_BUILD_COMPILE[@]}" compile-test-fast
    ;;
  test-lib-run)
    echo "[compile-fast] test-lib (compile + run, serial)"
    "${ZIG_BUILD_RUN[@]}" test-lib
    ;;
  test-fast-run)
    echo "[compile-fast] test-fast (compile + run, serial)"
    "${ZIG_BUILD_RUN[@]}" test-fast
    ;;
  *)
    echo "usage: $0 [check|test-lib|test-fast|test-lib-run|test-fast-run]" >&2
    exit 2
    ;;
esac

elapsed=$(( $(date +%s) - start_ts ))
echo "[compile-fast] OK (${mode}) in ${elapsed}s"
