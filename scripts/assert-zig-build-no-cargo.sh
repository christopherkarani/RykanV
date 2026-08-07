#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ryk-no-cargo.XXXXXX")"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

MARKER="${TMP_DIR}/cargo-invoked"
cat > "${TMP_DIR}/cargo" <<EOF
#!/usr/bin/env sh
printf 'cargo should not be invoked by ./scripts/zig build\n' >&2
touch "${MARKER}"
exit 99
EOF
chmod 0755 "${TMP_DIR}/cargo"

(
  cd "${REPO_ROOT}"
  PATH="${TMP_DIR}:${PATH}" ./scripts/zig build >/dev/null
)

[[ ! -e "${MARKER}" ]] || {
  printf 'assert-zig-build-no-cargo: cargo was invoked during ./scripts/zig build\n' >&2
  exit 1
}

printf '[assert-zig-build-no-cargo] passed\n'
