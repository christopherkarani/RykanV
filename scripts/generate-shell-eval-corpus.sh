#!/usr/bin/env bash
# Regenerate MVP shell-eval goldens from an *independent* oracle binary.
#
# Usage:
#   RYK_ORACLE_BIN=/path/to/pinned-ryk ./scripts/generate-shell-eval-corpus.sh commands.txt
#
# Refuses to use this checkout's zig-out binary (that would copy bugs into goldens).
# Without RYK_ORACLE_BIN, leaves the checked-in JSONL unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/src/shell_engine/mvp_corpus.jsonl"
CMDS="${1:-}"

if [[ -z "${RYK_ORACLE_BIN:-}" ]]; then
  echo "RYK_ORACLE_BIN is required (path to an independent, version-pinned ryk oracle)." >&2
  echo "Refusing to regenerate goldens from this checkout's build under test." >&2
  echo "Leaving ${OUT} unchanged." >&2
  exit 0
fi

RYK_BIN="${RYK_ORACLE_BIN}"
if [[ ! -x "${RYK_BIN}" ]]; then
  echo "RYK_ORACLE_BIN is not executable: ${RYK_BIN}" >&2
  exit 1
fi

# Hard fail if someone points the oracle at this tree's build output.
case "${RYK_BIN}" in
  "${ROOT}/zig-out/"*|"${ROOT}/.zig-cache/"*)
    echo "RYK_ORACLE_BIN must not be this checkout's zig-out/.zig-cache binary: ${RYK_BIN}" >&2
    exit 1
    ;;
esac

if [[ -z "${CMDS}" ]]; then
  echo "Pass a commands file (one command per line) to regenerate goldens." >&2
  echo "Example: RYK_ORACLE_BIN=/opt/ryk-oracle/bin/ryk ./scripts/generate-shell-eval-corpus.sh /tmp/cmds.txt" >&2
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
while IFS= read -r cmd || [[ -n "${cmd}" ]]; do
  [[ -z "${cmd}" || "${cmd}" == \#* ]] && continue
  json="$("${RYK_BIN}" test --format json "${cmd}" 2>/dev/null || true)"
  if [[ -z "${json}" ]]; then
    echo "skip (no json): ${cmd}" >&2
    continue
  fi
  decision="$(printf '%s' "${json}" | sed -n 's/.*"decision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  rule_id="$(printf '%s' "${json}" | sed -n 's/.*"rule_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "${decision}" ]]; then
    echo "skip (no decision): ${cmd}" >&2
    continue
  fi
  if [[ -n "${rule_id}" ]]; then
    printf '{"command":%s,"expected":"%s","rule_id":"%s"}\n' "$(printf '%s' "${cmd}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))')" "${decision}" "${rule_id}" >>"${tmp}"
  else
    printf '{"command":%s,"expected":"%s"}\n' "$(printf '%s' "${cmd}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))')" "${decision}" >>"${tmp}"
  fi
done <"${CMDS}"

if [[ -s "${tmp}" ]]; then
  mv "${tmp}" "${OUT}"
  echo "Wrote $(wc -l <"${OUT}") goldens to ${OUT} (oracle=${RYK_BIN})"
else
  echo "No goldens produced." >&2
  exit 1
fi
