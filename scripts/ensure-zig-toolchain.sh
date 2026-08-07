#!/usr/bin/env bash
# Pin the ryk build to the Zig version in .zigversion (currently 0.16.0).
# Usage:
#   ./scripts/ensure-zig-toolchain.sh          # print export instructions
#   eval "$(./scripts/ensure-zig-toolchain.sh --export)"
#   ./scripts/ensure-zig-toolchain.sh --check  # exit 1 if active zig is wrong

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT}/.zigversion"
INSTALL_ROOT="${RYK_ZIG_INSTALL_ROOT:-${HOME}/.local/zig}"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "error: missing ${VERSION_FILE}" >&2
  exit 1
fi

WANTED="$(tr -d '[:space:]' < "${VERSION_FILE}")"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "${os}" in
  darwin) zig_os="macos" ;;
  linux) zig_os="linux" ;;
  *)
    echo "error: unsupported OS for auto-install: ${os}" >&2
    exit 1
    ;;
esac
case "${arch}" in
  arm64 | aarch64) zig_arch="aarch64" ;;
  x86_64 | amd64) zig_arch="x86_64" ;;
  *)
    echo "error: unsupported CPU for auto-install: ${arch}" >&2
    exit 1
    ;;
esac

archive="zig-${zig_arch}-${zig_os}-${WANTED}"
ZIG_BIN="${INSTALL_ROOT}/${archive}/zig"
DOWNLOAD_URL="https://ziglang.org/download/${WANTED}/${archive}.tar.xz"

install_zig() {
  local task_tmp_root tmp
  if [[ -x "${ZIG_BIN}" ]]; then
    return 0
  fi
  echo "Installing Zig ${WANTED} to ${INSTALL_ROOT} ..." >&2
  mkdir -p "${INSTALL_ROOT}"
  # Darwin's bare `mktemp -d` asks confstr for /var/folders even when TMPDIR is
  # redirected by ryk. An explicit template keeps protected-agent installs on
  # the workspace session temp that Seatbelt actually grants.
  task_tmp_root="${TMPDIR:-${TMP:-/tmp}}"
  tmp="$(mktemp -d "${task_tmp_root%/}/ryk-zig.XXXXXX")"
  trap 'rm -rf "${tmp}"' RETURN
  curl -fsSL "${DOWNLOAD_URL}" -o "${tmp}/zig.tar.xz"
  tar -xJf "${tmp}/zig.tar.xz" -C "${INSTALL_ROOT}"
  if [[ ! -x "${ZIG_BIN}" ]]; then
    echo "error: install finished but ${ZIG_BIN} is missing" >&2
    exit 1
  fi
}

mode="${1:-}"
case "${mode}" in
  --check)
    active="$(command -v zig 2>/dev/null || true)"
    if [[ -x "${ZIG_BIN}" ]] && [[ "${active}" == "${ZIG_BIN}" ]]; then
      "${ZIG_BIN}" version
      exit 0
    fi
    if [[ -n "${active}" ]] && "${active}" version 2>/dev/null | grep -q "^${WANTED}"; then
      "${active}" version
      exit 0
    fi
    echo "error: active zig is not ${WANTED} (wanted ${ZIG_BIN} on PATH)" >&2
    [[ -n "${active}" ]] && echo "  current: ${active} ($("${active}" version 2>/dev/null || echo unknown))" >&2
    exit 1
    ;;
  --export)
    install_zig
    printf 'export PATH="%s:${PATH}"\n' "${INSTALL_ROOT}/${archive}"
    ;;
  --install)
    install_zig
    echo "Installed: ${ZIG_BIN}"
    "${ZIG_BIN}" version
    ;;
  "")
    install_zig
    cat <<EOF
ryk requires Zig ${WANTED} (see .zigversion).

Pinned binary:
  ${ZIG_BIN}

Use it for this shell:
  eval "\$(${ROOT}/scripts/ensure-zig-toolchain.sh --export)"

Or run builds via the wrapper:
  ${ROOT}/scripts/zig build
  ${ROOT}/scripts/zig build test

This repo targets Zig 0.16.0; do not use system zig if its version differs.
EOF
    ;;
  *)
    echo "usage: $0 [--check | --export | --install]" >&2
    exit 2
    ;;
esac
