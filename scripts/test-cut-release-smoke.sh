#!/usr/bin/env bash
# Lightweight smoke for cut-release.sh (no full build / publish).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

fail() { printf 'test-cut-release-smoke: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-cut-release-smoke: OK: %s\n' "$*"; }

bash -n scripts/cut-release.sh || fail "bash -n cut-release.sh"
bash -n scripts/build-linux-release-docker.sh || fail "bash -n build-linux-release-docker.sh"
pass "bash -n"

./scripts/cut-release.sh --help >/dev/null || fail "--help"
pass "--help"

# Missing args should fail
if ./scripts/cut-release.sh 2>/dev/null; then
  fail "expected failure with no args"
fi
pass "no-args fails"

# Invalid bump
if ./scripts/cut-release.sh --bump weird --plan-only 2>/dev/null; then
  fail "expected failure for invalid --bump"
fi
pass "invalid bump fails"

# Dirty tree or wrong branch should fail plan-only (this worktree is often dirty)
set +e
out="$(./scripts/cut-release.sh --bump patch --plan-only 2>&1)"
ec=$?
set -e
if [[ $ec -eq 0 ]]; then
  pass "plan-only succeeded (clean main + tools available)"
  echo "$out" | grep -q 'RELEASE PLAN' || fail "plan-only missing RELEASE PLAN banner"
  pass "plan-only prints plan"
else
  echo "$out" | grep -qiE 'dirty|branch must|docker|gh is not|zig version' \
    || fail "plan-only failed without expected preflight reason: $out"
  pass "plan-only fails closed on preflight ($ec)"
fi

printf 'test-cut-release-smoke: all checks passed\n'
