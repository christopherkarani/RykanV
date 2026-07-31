#!/usr/bin/env sh
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${RYK_INSTALL_DIR:-${HOME}/.local/bin}"

# find_dev_orca: prefer a development binary from the source tree when available.
# Checks (in priority order for dev workflows):
#  1. The repo root derived from this script's location (classic case).
#  2. $PWD/zig-out (covers running ./scripts/setup.sh or scripts/setup.sh
#     from the repo root, or from a different cwd with absolute script path).
#  3. git rev-parse --show-toplevel /zig-out (handles invocation from outside
#     the tree, subdirectories, symlinks, etc. when git is present).
# Only falls back to PATH or the network installer when no local dev binary
# is detectable. This is safe: we only ever select a literal zig-out/bin/ryk
# under a credible tree root.
find_dev_orca() {
  # 1. Script-derived repo root (existing behavior)
  if [ -x "${REPO_ROOT}/zig-out/bin/ryk" ]; then
    printf '%s\n' "${REPO_ROOT}/zig-out/bin/ryk"
    return 0
  fi
  # 2. Current working directory (common dev invocation pattern)
  if [ -x "${PWD}/zig-out/bin/ryk" ]; then
    printf '%s\n' "${PWD}/zig-out/bin/ryk"
    return 0
  fi
  # 3. Git root (robust for "invoked from elsewhere" or odd cwd cases)
  if command -v git >/dev/null 2>&1; then
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "${git_root:-}" ] && [ -x "${git_root}/zig-out/bin/ryk" ]; then
      printf '%s\n' "${git_root}/zig-out/bin/ryk"
      return 0
    fi
  fi
  return 1
}

resolve_ryk_bin() {
  # Strongly prefer a dev binary from the tree when one is present.
  # This fixes the common case where setup.sh would fall back to the
  # network installer simply because the script was invoked from outside
  # the repo root or via a relative path from another directory.
  dev_bin=""
  if dev_bin="$(find_dev_orca 2>/dev/null || true)"; then
    [ -n "$dev_bin" ] && printf '%s\n' "$dev_bin" && return 0
  fi
  if command -v ryk >/dev/null 2>&1; then
    command -v orca
    return 0
  fi
  if [ -x "${INSTALL_DIR}/orca" ]; then
    printf '%s\n' "${INSTALL_DIR}/orca"
    return 0
  fi
  return 1
}

RYK_BIN="$(resolve_ryk_bin)" || {
  "${SCRIPT_DIR}/install.sh"
  RYK_BIN="${INSTALL_DIR}/orca"
}

"${RYK_BIN}" setup --auto
