#!/usr/bin/env bash
# implementor-disk-gate.sh — host-native conjunctive VERDICT gate (no agent judgment).
#
# Usage:
#   ./scripts/implementor-disk-gate.sh PATH [PATH...]
#   ./scripts/implementor-disk-gate.sh --paths-file FILE
#
# For each path:
#   1. Must exist and be non-empty (test -s)
#   2. Must contain exactly one line matching ^VERDICT: (PASS|FAIL)$
#   3. That line must be VERDICT: PASS
#
# Exit 0 only if every path PASSes. Exit 1 otherwise.
# Prints a single-line JSON object to stdout (always, even on failure):
#   {"ok":bool,"paths_checked":[...],"missing":[...],"verdicts":[...],
#    "blocking_titles":[...],"summary":"...","error":"..."}
#
# Portable: macOS Bash 3.2+ / Linux bash. No jq required.
# Aligns with docs/agents/implement-floor.md §3: missing VERDICT file ⇒ FAIL.

set -euo pipefail

usage() {
  echo "Usage: $0 PATH [PATH...] | $0 --paths-file FILE" >&2
  exit 2
}

paths=()
if [[ $# -eq 0 ]]; then
  usage
fi

if [[ "${1:-}" == "--paths-file" ]]; then
  shift
  [[ $# -ge 1 ]] || usage
  pf="$1"
  if [[ ! -f "$pf" ]]; then
    echo "{\"ok\":false,\"paths_checked\":[],\"missing\":[],\"verdicts\":[],\"blocking_titles\":[],\"summary\":\"paths-file missing\",\"error\":\"paths-file not found\"}"
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    paths+=("$line")
  done <"$pf"
else
  paths=("$@")
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  echo '{"ok":false,"paths_checked":[],"missing":[],"verdicts":[],"blocking_titles":[],"summary":"no paths","error":"no paths provided"}'
  exit 1
fi

json_escape() {
  # Escape a string for JSON (paths should not contain newlines)
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Build a JSON string array from a bash array passed by name via eval-safe copy.
# Call as: json_str_array "${arr[@]}"   — when arr is empty, call with no args.
json_str_array() {
  local out="["
  local i=0
  local it
  for it in "$@"; do
    if [[ $i -gt 0 ]]; then
      out+=","
    fi
    out+="\"$(json_escape "$it")\""
    i=$((i + 1))
  done
  out+="]"
  printf '%s' "$out"
}

paths_checked=()
missing=()
verdicts=()
blocking=()
ok=true
fail_count=0

for f in "${paths[@]}"; do
  paths_checked+=("$f")
  if [[ ! -s "$f" ]]; then
    missing+=("$f")
    verdicts+=("MISSING")
    blocking+=("missing:$(basename "$f")")
    ok=false
    fail_count=$((fail_count + 1))
    continue
  fi

  # Collect VERDICT lines into a temp list (Bash 3.2: no mapfile)
  vtmp=$(mktemp)
  # Prefer canonical ^VERDICT: (PASS|FAIL)$; also accept optional markdown bold wrappers
  # used by some reviewers (**VERDICT: FAIL**). Exactly one match required either way.
  # grep may exit 1 on no match — do not fail the script.
  grep -E '^\*{0,2}VERDICT: (PASS|FAIL)\*{0,2}$' "$f" >"$vtmp" 2>/dev/null || true
  n=$(wc -l <"$vtmp" | tr -d ' ')
  if [[ -z "$n" ]]; then
    n=0
  fi

  if [[ "$n" -eq 0 ]]; then
    missing+=("$f")
    verdicts+=("NO_VERDICT")
    blocking+=("no-verdict:$(basename "$f")")
    ok=false
    fail_count=$((fail_count + 1))
    rm -f "$vtmp"
    continue
  fi
  if [[ "$n" -gt 1 ]]; then
    missing+=("$f")
    verdicts+=("MULTI_VERDICT")
    blocking+=("multi-verdict:$(basename "$f")")
    ok=false
    fail_count=$((fail_count + 1))
    rm -f "$vtmp"
    continue
  fi

  line=$(head -n 1 "$vtmp")
  rm -f "$vtmp"
  # Normalize: strip optional leading/trailing ** then compare
  norm=$line
  norm=${norm#\*\*}
  norm=${norm%\*\*}
  if [[ "$norm" == "VERDICT: PASS" ]]; then
    verdicts+=("PASS")
  else
    verdicts+=("FAIL")
    blocking+=("FAIL:$(basename "$f")")
    ok=false
    fail_count=$((fail_count + 1))
  fi
done

if $ok; then
  summary="all ${#paths_checked[@]} paths VERDICT PASS"
  error=""
  exit_code=0
  ok_json=true
else
  summary="${fail_count} of ${#paths_checked[@]} paths failed host-native VERDICT gate"
  error="$summary"
  exit_code=1
  ok_json=false
fi

# Expand arrays safely for empty case (Bash 3.2 + set -u)
if [[ ${#paths_checked[@]} -gt 0 ]]; then
  pc_json=$(json_str_array "${paths_checked[@]}")
else
  pc_json="[]"
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  miss_json=$(json_str_array "${missing[@]}")
else
  miss_json="[]"
fi
if [[ ${#verdicts[@]} -gt 0 ]]; then
  verd_json=$(json_str_array "${verdicts[@]}")
else
  verd_json="[]"
fi
if [[ ${#blocking[@]} -gt 0 ]]; then
  block_json=$(json_str_array "${blocking[@]}")
else
  block_json="[]"
fi

printf '{'
printf '"ok":%s,' "$ok_json"
printf '"paths_checked":%s,' "$pc_json"
printf '"missing":%s,' "$miss_json"
printf '"verdicts":%s,' "$verd_json"
printf '"blocking_titles":%s,' "$block_json"
printf '"summary":"%s",' "$(json_escape "$summary")"
printf '"error":"%s"' "$(json_escape "$error")"
printf '}\n'

exit "$exit_code"
