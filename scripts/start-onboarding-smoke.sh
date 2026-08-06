#!/usr/bin/env bash
# Manual/staged smoke for `ryk start` using an isolated HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ryk-start-smoke.XXXXXX")"
cleanup() {
    rm -rf "$SMOKE_HOME"
}
trap cleanup EXIT

export HOME="$SMOKE_HOME"
export RYK_RESOURCE_ROOT="${RYK_RESOURCE_ROOT:-$ROOT}"

"$ROOT/scripts/zig" build
RYK_BIN="$ROOT/zig-out/bin/ryk"

echo "== Fresh environment: ryk start (firewall) =="
"$RYK_BIN" start --auto --protection firewall --skip-verify

echo "== Idempotent second run =="
"$RYK_BIN" start --auto --protection firewall --skip-verify

echo "== doctor =="
"$RYK_BIN" doctor

echo "== version =="
"$RYK_BIN" version

echo "ryk start smoke completed in $SMOKE_HOME"
