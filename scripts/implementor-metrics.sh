#!/usr/bin/env bash
# implementor-metrics.sh — local residual / VERDICT rollup for one implementor run.
#
# Usage:
#   ./scripts/implementor-metrics.sh RUN_DIR
#   ./scripts/implementor-metrics.sh RUN_DIR --write   # also write RUN_DIR/metrics.md
#
# No SaaS/telemetry. Reads on-disk reviews + residuals only.
# Aligns with docs/agents/implement-floor.md §3 (complete gates) and §6 classes.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 RUN_DIR [--write]" >&2
  exit 2
fi

run_dir=$1
do_write=false
if [[ "${2:-}" == "--write" ]]; then
  do_write=true
fi

if [[ ! -d "$run_dir" ]]; then
  echo "RUN_DIR not a directory: $run_dir" >&2
  exit 1
fi

reviews_dir="$run_dir/reviews"
residuals="$run_dir/residuals.md"
status_md="$run_dir/status.md"
report_md="$run_dir/report.md"

# Optional markdown bold wrappers around VERDICT lines (same as disk-gate).
VERDICT_RE='^\*{0,2}VERDICT: (PASS|FAIL)\*{0,2}$'
VERDICT_PASS_RE='^\*{0,2}VERDICT: PASS\*{0,2}$'
VERDICT_FAIL_RE='^\*{0,2}VERDICT: FAIL\*{0,2}$'

count_verdicts() {
  local want=$1
  local re=$VERDICT_PASS_RE
  if [[ "$want" == "FAIL" ]]; then
    re=$VERDICT_FAIL_RE
  fi
  local n=0
  if [[ -d "$reviews_dir" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qE "$re" "$f" 2>/dev/null; then
        n=$((n + 1))
      fi
    done < <(find "$reviews_dir" -type f -name '*.md' 2>/dev/null | sort)
  fi
  echo "$n"
}

count_missing_verdict() {
  local n=0
  if [[ -d "$reviews_dir" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if ! grep -qE "$VERDICT_RE" "$f" 2>/dev/null; then
        n=$((n + 1))
      fi
    done < <(find "$reviews_dir" -type f -name '*.md' 2>/dev/null | sort)
  fi
  echo "$n"
}

review_file_count=0
if [[ -d "$reviews_dir" ]]; then
  review_file_count=$(find "$reviews_dir" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
fi

pass_n=$(count_verdicts PASS)
fail_n=$(count_verdicts FAIL)
missing_n=$(count_missing_verdict)

# Residual class hits (case-insensitive keyword scan of residuals + open integration reviews)
scan_blob=""
if [[ -f "$residuals" ]]; then
  scan_blob+=$(cat "$residuals")
  scan_blob+=$'\n'
fi
if [[ -d "$reviews_dir" ]]; then
  for f in "$reviews_dir"/integration-*.md; do
    [[ -f "$f" ]] || continue
    scan_blob+=$(cat "$f")
    scan_blob+=$'\n'
  done
fi

class_count() {
  local pattern=$1
  if [[ -z "$scan_blob" ]]; then
    echo 0
    return
  fi
  # Count matching lines; force 0 on no-match (grep exit 1) without double-echo
  local n
  n=$(printf '%s\n' "$scan_blob" | grep -Eic "$pattern" 2>/dev/null || true)
  if [[ -z "$n" ]]; then
    n=0
  fi
  echo "$n"
}

c_composition=$(class_count 'composition|monopath|project-path|workspace-root|nested-cwd|loader.*path|cwd-only')
c_flock=$(class_count 'flock|multi-process|load-modify-write|double-grant')
c_ownership=$(class_count 'double-free|errdefer|ownership|UAF|use-after-free')
c_pathform=$(class_count 'realpath|/private/var|path.form|cwd/realpath')
c_honesty=$(class_count 'corrupt|silent discard|fail-closed|operator-visible|LoadOutcome')
c_process=$(class_count 'disk.gate|missing VERDICT|tests_touched|thrash|soft.fail|VERDICT file')
c_testgap=$(class_count 'test.gap|weak.coverage|tests_touched:\s*false|no test')

# Integration split signal: any integration lane FAIL while another PASS
integ_pass=0
integ_fail=0
if [[ -d "$reviews_dir" ]]; then
  for f in "$reviews_dir"/integration-*.md; do
    [[ -f "$f" ]] || continue
    if grep -qE "$VERDICT_PASS_RE" "$f" 2>/dev/null; then
      integ_pass=$((integ_pass + 1))
    elif grep -qE "$VERDICT_FAIL_RE" "$f" 2>/dev/null; then
      integ_fail=$((integ_fail + 1))
    fi
  done
fi
split_integ=false
if (( integ_pass > 0 && integ_fail > 0 )); then
  split_integ=true
fi

generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)

body=$(
  cat <<EOF
# Implementor metrics

**Run dir:** \`$run_dir\`
**Generated:** $generated
**Source:** on-disk reviews + residuals only (local; no telemetry)

## VERDICT inventory

| Metric | Count |
|--------|------:|
| Review files | $review_file_count |
| VERDICT PASS | $pass_n |
| VERDICT FAIL | $fail_n |
| Missing/invalid VERDICT | $missing_n |
| Integration PASS lanes | $integ_pass |
| Integration FAIL lanes | $integ_fail |
| Split integration (PASS+FAIL) | $split_integ |

## Residual class hits (keyword scan)

Rough line-hit counts over \`residuals.md\` + \`integration-*.md\`. Not a legal finding list — a floor trend signal.

| Class | Hits |
|-------|-----:|
| composition/wiring | $c_composition |
| concurrency/flock | $c_flock |
| ownership/errdefer | $c_ownership |
| path-form | $c_pathform |
| fail-closed/honesty | $c_honesty |
| process/gate | $c_process |
| test-gap | $c_testgap |

## Floor complete checks (manual)

Per \`docs/agents/implement-floor.md\` §3, complete requires:

- [ ] Every unit required lane has \`VERDICT: PASS\` on disk (missing ⇒ FAIL)
- [ ] All integration lanes PASS (never complete with split integ)
- [ ] Host-native \`./scripts/implementor-disk-gate.sh\` green on full required path set
- [ ] §6 defects fixed or **explicitly accepted** residuals (not silent minors)
- [ ] Composition acceptance + nested-cwd writer↔loader when product surface

## Paths

- Residuals: \`$residuals\`
- Reviews: \`$reviews_dir\`
- Status: \`$status_md\`
EOF
)

printf '%s\n' "$body"

if $do_write; then
  out="$run_dir/metrics.md"
  printf '%s\n' "$body" >"$out"
  echo "Wrote $out" >&2
fi
