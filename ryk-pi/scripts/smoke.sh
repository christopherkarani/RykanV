#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RYK_BIN="${RYK_BIN:-ryk}"

request() {
  local command="$1"
  printf '{"schema_version":1,"kind":"shell_command","command":%s,"cwd":%s,"source":{"host":"pi","tool_name":"bash","mode":"smoke"}}\n' \
    "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$command")" \
    "$(node -e 'process.stdout.write(JSON.stringify(process.cwd()))')"
}

cd "$ROOT_DIR"
npm test
npm pack --dry-run

request "git status" | "$RYK_BIN" evaluate --json --stdin >/tmp/ryk-pi-safe.json
safe_code=$?
if [[ "$safe_code" -ne 0 ]]; then
  echo "Expected safe command to exit 0, got $safe_code" >&2
  exit 1
fi

set +e
request "rm -rf /" | "$RYK_BIN" evaluate --json --stdin >/tmp/ryk-pi-danger.json
danger_code=$?
set -e
if [[ "$danger_code" -ne 2 ]]; then
  echo "Expected dangerous command to exit 2, got $danger_code" >&2
  exit 1
fi

echo "ryk Pi smoke checks passed"
