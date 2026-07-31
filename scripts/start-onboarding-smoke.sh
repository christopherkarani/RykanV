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
ORCA="$ROOT/zig-out/bin/ryk"

echo "== Fresh environment: ryk start (firewall) =="
"$ORCA" start --auto --protection firewall --skip-verify

echo "== Idempotent second run =="
"$ORCA" start --auto --protection firewall --skip-verify

echo "== doctor =="
"$ORCA" doctor

echo "== version =="
"$ORCA" version

echo "ryk start smoke completed in $SMOKE_HOME"
