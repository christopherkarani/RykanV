#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RYK_BIN="${REPO_ROOT}/zig-out/bin/ryk"

fail() {
  printf 'uninstall-first-user-regression: %s\n' "$1" >&2
  exit 1
}

(cd "${REPO_ROOT}" && ./scripts/zig build)

[[ -x "${RYK_BIN}" ]] || fail "built CLI not found under zig-out/bin/ryk"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/ryk-uninstall-first-user.XXXXXX")"
cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM

prepare_install() {
  local root="$1"
  mkdir -p "${root}/home/custom/bin" \
    "${root}/home/custom/share/ryk/1.2.0/fixtures" \
    "${root}/home/custom/share/ryk/1.2.0/integrations" \
    "${root}/home/custom/share/ryk/1.2.0/schemas" \
    "${root}/home/custom/share/ryk/1.2.0/policies" \
    "${root}/home/.config/ryk" \
    "${root}/home/.local/share/ryk" \
    "${root}/workspace/.ryk"
  cp "${RYK_BIN}" "${root}/home/custom/bin/ryk"
  printf '#!/bin/sh\nexit 0\n' > "${root}/home/custom/bin/ryk-daemon"
  chmod +x "${root}/home/custom/bin/ryk-daemon"
  printf 'ryk-runtime-v1\nversion=1.2.0\n' > "${root}/home/custom/share/ryk/1.2.0/.ryk-installation"
  ln -sfn "${root}/home/custom/share/ryk/1.2.0" "${root}/home/custom/share/ryk/current"
  printf '{}\n' > "${root}/home/custom/share/ryk/allow_once.jsonl"
  printf '{}\n' > "${root}/home/custom/share/ryk/pending_exceptions.jsonl"
  printf 'user config\n' > "${root}/home/.config/ryk/config.toml"
  printf 'workspace policy\n' > "${root}/workspace/.ryk/policy.yaml"
  cat > "${root}/home/.profile" <<EOF
export KEEP_ME=1
# Added by ryk installer
export PATH="${root}/home/custom/bin:\$PATH"
# ryk runtime assets
export RYK_RESOURCE_ROOT="${root}/home/custom/share/ryk/current"
export ALSO_KEEP_ME=1
EOF
}

# ── --keep-config: binary + runtime gone; config + allow-once kept ──────────
keep_root="${tmp_root}/keep-config"
prepare_install "${keep_root}"
(
  cd "${keep_root}/workspace"
  HOME="${keep_root}/home" \
  XDG_CONFIG_HOME="${keep_root}/home/.config" \
  RYK_RESOURCE_ROOT="${keep_root}/home/custom/share/ryk/current" \
  PATH=/usr/bin:/bin \
  "${keep_root}/home/custom/bin/ryk" uninstall --yes --keep-config >"${keep_root}/uninstall.log"
)

[[ ! -e "${keep_root}/home/custom/bin/ryk" ]] || fail "--keep-config left the ryk binary"
if [[ -e "${keep_root}/home/custom/bin/ryk-daemon" ]]; then
  cat "${keep_root}/uninstall.log" >&2
  fail "--keep-config left ryk-daemon"
fi
[[ ! -e "${keep_root}/home/custom/share/ryk/current" ]] || fail "--keep-config left the current runtime link"
[[ ! -e "${keep_root}/home/custom/share/ryk/1.2.0" ]] || fail "--keep-config left runtime assets"
[[ -f "${keep_root}/home/.config/ryk/config.toml" ]] || fail "--keep-config removed user config"
[[ -f "${keep_root}/home/custom/share/ryk/allow_once.jsonl" ]] || fail "--keep-config removed allow-once data"
[[ -f "${keep_root}/workspace/.ryk/policy.yaml" ]] || fail "uninstall removed workspace .ryk"
grep -qF 'export KEEP_ME=1' "${keep_root}/home/.profile" || fail "uninstall removed unrelated profile content"
grep -qF 'export ALSO_KEEP_ME=1' "${keep_root}/home/.profile" || fail "uninstall removed unrelated profile content"
! grep -qF '# Added by ryk installer' "${keep_root}/home/.profile" || fail "uninstall left PATH marker"
! grep -qF '# ryk runtime assets' "${keep_root}/home/.profile" || fail "uninstall left runtime marker"

# ── full uninstall: share wipe including allow-once; config gone ─────────────
full_root="${tmp_root}/full"
prepare_install "${full_root}"
mkdir -p "${full_root}/home/.local/share"
ln -sfn "${full_root}/home/custom/share/ryk" "${full_root}/home/.local/share/ryk"
(
  cd "${full_root}/workspace"
  HOME="${full_root}/home" \
  XDG_CONFIG_HOME="${full_root}/home/.config" \
  RYK_RESOURCE_ROOT="${full_root}/home/custom/share/ryk/current" \
  PATH=/usr/bin:/bin \
  "${full_root}/home/custom/bin/ryk" uninstall --yes >"${full_root}/uninstall.log"
)
[[ ! -e "${full_root}/home/custom/bin/ryk" ]] || fail "full uninstall left ryk"
[[ ! -e "${full_root}/home/.config/ryk/config.toml" ]] || fail "full uninstall left config"
[[ ! -e "${full_root}/home/custom/share/ryk/allow_once.jsonl" ]] || fail "full uninstall left allow-once"
[[ -f "${full_root}/workspace/.ryk/policy.yaml" ]] || fail "full uninstall removed workspace .ryk"

# ── --plugins-only ──────────────────────────────────────────────────────────
plugins_root="${tmp_root}/plugins-only"
prepare_install "${plugins_root}"
(
  cd "${plugins_root}/workspace"
  HOME="${plugins_root}/home" \
  XDG_CONFIG_HOME="${plugins_root}/home/.config" \
  RYK_RESOURCE_ROOT="${plugins_root}/home/custom/share/ryk/current" \
  PATH=/usr/bin:/bin \
  "${plugins_root}/home/custom/bin/ryk" uninstall --yes --plugins-only >/dev/null
)

[[ -x "${plugins_root}/home/custom/bin/ryk" ]] || fail "--plugins-only removed the CLI binary"
[[ -x "${plugins_root}/home/custom/bin/ryk-daemon" ]] || fail "--plugins-only removed ryk-daemon"
[[ -e "${plugins_root}/home/custom/share/ryk/current" ]] || fail "--plugins-only removed runtime assets"
grep -qF '# Added by ryk installer' "${plugins_root}/home/.profile" || fail "--plugins-only changed profile activation"

# ── --dry-run leaves everything ─────────────────────────────────────────────
dry_root="${tmp_root}/dry-run"
prepare_install "${dry_root}"
(
  cd "${dry_root}/workspace"
  HOME="${dry_root}/home" \
  XDG_CONFIG_HOME="${dry_root}/home/.config" \
  RYK_RESOURCE_ROOT="${dry_root}/home/custom/share/ryk/current" \
  PATH=/usr/bin:/bin \
  "${dry_root}/home/custom/bin/ryk" uninstall --dry-run >"${dry_root}/uninstall.log"
)
[[ -x "${dry_root}/home/custom/bin/ryk" ]] || fail "--dry-run removed ryk"
[[ -e "${dry_root}/home/custom/share/ryk/current" ]] || fail "--dry-run removed runtime"
[[ -f "${dry_root}/home/.config/ryk/config.toml" ]] || fail "--dry-run removed config"
grep -qF 'dry-run' "${dry_root}/uninstall.log" || fail "--dry-run did not report dry-run mode"

printf '[uninstall-first-user-regression] passed\n'
