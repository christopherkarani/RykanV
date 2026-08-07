#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RYK_BIN="$ROOT/zig-out/bin/ryk"

cd "$ROOT"
./scripts/zig build

if [ ! -x "$RYK_BIN" ]; then
  printf 'v1 smoke: missing binary at %s\n' "$RYK_BIN" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ryk-v1-smoke.XXXXXX")
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

(
  cd "$TMP_DIR"
  "$RYK_BIN" version
  "$RYK_BIN" version --json
  "$RYK_BIN" doctor
  "$RYK_BIN" init --preset generic-agent --force
  "$RYK_BIN" policy check .ryk/policy.yaml
  "$RYK_BIN" run -- echo hello
  "$RYK_BIN" replay --session last --verify
)

"$RYK_BIN" redteam --ci

printf 'v1 smoke: passed\n'
