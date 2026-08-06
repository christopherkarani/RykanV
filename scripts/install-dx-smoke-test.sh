#!/usr/bin/env bash
# Simulates a packaged ryk install layout (no git clone) and verifies plugin wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RYK_BIN="${REPO_ROOT}/zig-out/bin/ryk"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

if [[ ! -x "${RYK_BIN}" ]]; then
  echo "install-dx-smoke: building ryk binary first..." >&2
  (cd "${REPO_ROOT}" && zig build)
fi

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  if command -v jq >/dev/null 2>&1; then
    actual="$(printf '%s' "${json}" | jq -r "${field}")"
    if [[ "${actual}" != "${expected}" ]]; then
      echo "install-dx-smoke: expected ${field}=${expected}, got ${actual}" >&2
      exit 1
    fi
    return 0
  fi
  case "${expected}" in
    true) printf '%s' "${json}" | grep -q "\"${field##*.}\": true" ;;
    false) printf '%s' "${json}" | grep -q "\"${field##*.}\": false" ;;
    *) printf '%s' "${json}" | grep -Fq "\"${field##*.}\": \"${expected}\"" ;;
  esac
}

canonical_path() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ryk-install-dx.XXXXXX")"
cleanup() {
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT INT TERM

RESOURCE_ROOT="${TMP_HOME}/.local/share/ryk/${VERSION}"
BIN_DIR="${TMP_HOME}/.local/bin"
mkdir -p "${RESOURCE_ROOT}" "${BIN_DIR}"
ln -sf "${RYK_BIN}" "${BIN_DIR}/ryk"

for dir in integrations fixtures schemas policies; do
  cp -R "${REPO_ROOT}/${dir}" "${RESOURCE_ROOT}/"
done

export HOME="${TMP_HOME}"
export PATH="${BIN_DIR}:${PATH}"
export RYK_RESOURCE_ROOT="${RESOURCE_ROOT}"

WORKSPACE="${TMP_HOME}/workspace"
mkdir -p "${WORKSPACE}/.ryk" "${WORKSPACE}/nested"
printf 'mode: generic-agent\n' > "${WORKSPACE}/.ryk/policy.yaml"
cd "${WORKSPACE}/nested"

echo "[install-dx-smoke] RYK_RESOURCE_ROOT=${RYK_RESOURCE_ROOT}"

"${RYK_BIN}" plugin install hermes --yes
hermes_json="$("${RYK_BIN}" plugin doctor hermes --json)"
assert_json_field "${hermes_json}" ".hermes_paths.user_manifest_exists" "true"

"${RYK_BIN}" plugin install codex --yes
codex_json="$("${RYK_BIN}" plugin doctor codex --json)"
assert_json_field "${codex_json}" ".marketplace.codex_user_plugin" "true"
assert_json_field "${codex_json}" ".workspace_root" "$(canonical_path "${WORKSPACE}")"

"${RYK_BIN}" plugin install claude --yes
claude_json="$("${RYK_BIN}" plugin doctor claude --json)"
assert_json_field "${claude_json}" ".marketplace.claude_user_plugin" "true"
assert_json_field "${claude_json}" ".workspace_root" "$(canonical_path "${WORKSPACE}")"

# Reinstall helper should replace stale RYK_RESOURCE_ROOT export when marker exists
RC_FILE="${TMP_HOME}/.zshrc"
marker="# ryk runtime assets"
CURRENT_LINK="${TMP_HOME}/.local/share/ryk/current"
{
  printf '\n%s\n' "${marker}"
  printf 'export RYK_RESOURCE_ROOT="%s"\n' "${TMP_HOME}/.local/share/ryk/old-version"
} >> "${RC_FILE}"
tmp_rc="$(mktemp)"
awk -v marker="${marker}" -v new_line="export RYK_RESOURCE_ROOT=\"${CURRENT_LINK}\"" '
  $0 == marker { print; print new_line; skip=1; next }
  skip && /^export RYK_RESOURCE_ROOT=/ { next }
  skip && $0 == "" { skip=0 }
  { print }
' "${RC_FILE}" > "${tmp_rc}"
mv "${tmp_rc}" "${RC_FILE}"
grep -qF "export RYK_RESOURCE_ROOT=\"${CURRENT_LINK}\"" "${RC_FILE}"
grep -qF "export RYK_RESOURCE_ROOT=\"${TMP_HOME}/.local/share/ryk/old-version\"" "${RC_FILE}" && {
  echo "install-dx-smoke: stale RYK_RESOURCE_ROOT was not replaced" >&2
  exit 1
}

echo "[install-dx-smoke] passed"
