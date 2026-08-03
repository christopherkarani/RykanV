#!/usr/bin/env bash
# plan-harden-gate.sh — host-native conjunctive gate for pre-implement plans.
#
# Usage:
#   ./scripts/plan-harden-gate.sh RUN_DIR
#   ./scripts/plan-harden-gate.sh RUN_DIR --mode full|standard|lite
#
# Checks (conjunctive — any failure ⇒ exit 1):
#   1. Required plan artifacts exist and are non-empty:
#        plan.json, plan.md, ownership.md, forks.md
#   2. PLAN_READY candidate path writable context (reviews/plan-harden/)
#   3. Required plan-harden VERDICT files each have exactly one VERDICT: PASS
#      (reuses implementor-disk-gate.sh semantics)
#   4. plan.json structural rules (python):
#        - units array non-empty, within mode caps
#        - each unit: id, title, goal, acceptance (1–3), depends_on,
#          code_paths, test_paths, parallel_safe, fat
#        - no fat:true remaining
#        - exclusive path overlaps among parallel_safe units → FAIL
#        - product-ish units (code_paths mention cli/run/loader/monopath or
#          acceptance mentions live/smoke/CLI) must have a live_smoke field
#          OR an acceptance bullet containing a real command token
#
# Prints single-line JSON to stdout (always):
#   {"ok":bool,"run_dir":"...","paths_checked":[...],"missing":[...],
#    "verdicts":[...],"blocking":[...],"summary":"...","error":"..."}
#
# Exit 0 only when ok=true. Portable: macOS Bash 3.2+ / Linux bash.

set -euo pipefail

usage() {
  echo "Usage: $0 RUN_DIR [--mode full|standard|lite]" >&2
  exit 2
}

if [[ $# -lt 1 ]]; then
  usage
fi

RUN_DIR="$1"
shift
MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      shift
      MODE="${1:-full}"
      ;;
    *)
      usage
      ;;
  esac
  shift || true
done

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_str_array() {
  local out="["
  local i=0
  local it
  for it in "$@"; do
    if [[ $i -gt 0 ]]; then out+=","; fi
    out+="\"$(json_escape "$it")\""
    i=$((i + 1))
  done
  out+="]"
  printf '%s' "$out"
}

emit_and_exit() {
  local ok_json=$1
  local summary=$2
  local error=$3
  local exit_code=$4
  local pc_json miss_json verd_json block_json
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
  printf '{"ok":%s,"run_dir":"%s","mode":"%s","paths_checked":%s,"missing":%s,"verdicts":%s,"blocking":%s,"summary":"%s","error":"%s"}\n' \
    "$ok_json" \
    "$(json_escape "$RUN_DIR")" \
    "$(json_escape "$MODE")" \
    "$pc_json" \
    "$miss_json" \
    "$verd_json" \
    "$block_json" \
    "$(json_escape "$summary")" \
    "$(json_escape "$error")"
  exit "$exit_code"
}

paths_checked=()
missing=()
verdicts=()
blocking=()
ok=true

if [[ ! -d "$RUN_DIR" ]]; then
  blocking+=("run_dir_missing")
  emit_and_exit false "run_dir missing" "run_dir not a directory: $RUN_DIR" 1
fi

# --- required plan artifacts ---
for rel in plan.json plan.md ownership.md forks.md; do
  f="$RUN_DIR/$rel"
  paths_checked+=("$f")
  if [[ ! -s "$f" ]]; then
    missing+=("$f")
    verdicts+=("MISSING")
    blocking+=("missing:$rel")
    ok=false
  else
    verdicts+=("PRESENT")
  fi
done

# --- required plan-harden VERDICT lanes (mode-scaled) ---
PH_DIR="$RUN_DIR/reviews/plan-harden"
mkdir -p "$PH_DIR" 2>/dev/null || true

# Always required lanes
REQUIRED_VERDICTS=(
  "architect-systems.md"
  "architect-security.md"
  "architect-composition.md"
  "decompose-primary.md"
  "decompose-adversarial.md"
  "gate-author.md"
  "plan-structure.md"
  "plan-ownership.md"
  "plan-verifiability.md"
)

if [[ "$MODE" != "lite" ]]; then
  REQUIRED_VERDICTS+=(
    "plan-grounding.md"
    "plan-false-positive.md"
    "plan-false-negative.md"
    "plan-feasibility.md"
    "plan-invariants.md"
  )
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK_GATE="$SCRIPT_DIR/implementor-disk-gate.sh"

verdict_paths=()
for rel in "${REQUIRED_VERDICTS[@]}"; do
  verdict_paths+=("$PH_DIR/$rel")
done

if [[ -x "$DISK_GATE" ]] || [[ -f "$DISK_GATE" ]]; then
  # Capture disk-gate JSON; do not let set -e abort on exit 1
  set +e
  dg_out=$("$DISK_GATE" "${verdict_paths[@]}" 2>/dev/null)
  dg_ec=$?
  set -e
  for p in "${verdict_paths[@]}"; do
    paths_checked+=("$p")
  done
  if [[ $dg_ec -ne 0 ]]; then
    ok=false
    blocking+=("verdict_lanes_failed")
    # Best-effort parse missing from JSON is hard without jq; record raw summary
    if [[ -n "$dg_out" ]]; then
      # Extract rough summary field if present
      case "$dg_out" in
        *\"summary\":\"*)
          # leave blocking generic; detailed paths checked below
          ;;
      esac
    fi
    # Per-path fallback inspection
    for p in "${verdict_paths[@]}"; do
      if [[ ! -s "$p" ]]; then
        missing+=("$p")
        verdicts+=("MISSING")
        blocking+=("missing:$(basename "$p")")
        continue
      fi
      n=$(grep -E '^\*{0,2}VERDICT: (PASS|FAIL)\*{0,2}$' "$p" 2>/dev/null | wc -l | tr -d ' ')
      if [[ -z "$n" ]]; then n=0; fi
      if [[ "$n" -ne 1 ]]; then
        missing+=("$p")
        verdicts+=("BAD_VERDICT")
        blocking+=("bad-verdict:$(basename "$p")")
        continue
      fi
      line=$(grep -E '^\*{0,2}VERDICT: (PASS|FAIL)\*{0,2}$' "$p" | head -n 1)
      norm=$line
      norm=${norm#\*\*}
      norm=${norm%\*\*}
      if [[ "$norm" == "VERDICT: PASS" ]]; then
        verdicts+=("PASS")
      else
        verdicts+=("FAIL")
        blocking+=("FAIL:$(basename "$p")")
      fi
    done
  else
    for p in "${verdict_paths[@]}"; do
      verdicts+=("PASS")
    done
  fi
else
  ok=false
  blocking+=("implementor-disk-gate.sh missing")
fi

# --- plan.json structural rules via python ---
PLAN_JSON="$RUN_DIR/plan.json"
STRUCT_ERR=""
if [[ -s "$PLAN_JSON" ]]; then
  set +e
  STRUCT_ERR=$(python3 - "$PLAN_JSON" "$MODE" <<'PY'
import json, sys, re

path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"plan_json_parse:{e}")
    sys.exit(1)

units = data.get("units")
if not isinstance(units, list) or len(units) == 0:
    print("units_empty")
    sys.exit(1)

max_units = 12
if mode == "lite":
    max_units = 4
if len(units) > max_units:
    print(f"units_over_cap:{len(units)}>{max_units}")
    sys.exit(1)

errors = []
# path -> list of unit ids claiming it with parallel_safe
claims = {}

def is_productish(u):
    paths = (u.get("code_paths") or []) + (u.get("test_paths") or [])
    blob = " ".join(str(p) for p in paths).lower()
    acc = " ".join(str(a) for a in (u.get("acceptance") or [])).lower()
    goal = str(u.get("goal") or "").lower()
    keys = ("cli", "run.", "loader", "monopath", "shell", "opencode", "host", "product", "entrypoint")
    return any(k in blob or k in acc or k in goal for k in keys)

def has_live_smoke(u):
    if u.get("live_smoke"):
        return True
    acc = u.get("acceptance") or []
    for a in acc:
        s = str(a)
        if re.search(r"(ryk|zig-out|./|live.?smoke|product.?oracle)", s, re.I):
            return True
    return False

for u in units:
    if not isinstance(u, dict):
        errors.append("unit_not_object")
        continue
    uid = str(u.get("id") or "").strip()
    if not uid:
        errors.append("unit_missing_id")
        continue
    for req in ("title", "goal"):
        if not str(u.get(req) or "").strip():
            errors.append(f"{uid}:missing_{req}")
    acc = u.get("acceptance")
    if not isinstance(acc, list) or not (1 <= len(acc) <= 3):
        errors.append(f"{uid}:acceptance_count")
    if "depends_on" not in u or not isinstance(u.get("depends_on"), list):
        errors.append(f"{uid}:depends_on")
    if "code_paths" not in u or not isinstance(u.get("code_paths"), list):
        errors.append(f"{uid}:code_paths")
    if "test_paths" not in u or not isinstance(u.get("test_paths"), list):
        errors.append(f"{uid}:test_paths")
    if "parallel_safe" not in u:
        errors.append(f"{uid}:parallel_safe")
    if u.get("fat") is True:
        errors.append(f"{uid}:still_fat")
    if is_productish(u) and not has_live_smoke(u):
        errors.append(f"{uid}:missing_live_smoke")
    # ownership claims for parallel_safe
    if u.get("parallel_safe") is True:
        for p in (u.get("code_paths") or []) + (u.get("test_paths") or []):
            ps = str(p).strip()
            if not ps:
                continue
            claims.setdefault(ps, []).append(uid)

# parallel_safe path collisions
for p, owners in claims.items():
    uniq = sorted(set(owners))
    if len(uniq) > 1:
        errors.append(f"path_overlap:{p}:{'+'.join(uniq)}")

# forks.md open-fork check done outside if needed
if errors:
    print(";".join(errors[:40]))
    sys.exit(1)
sys.exit(0)
PY
)
  struct_ec=$?
  set -e
  paths_checked+=("$PLAN_JSON#structure")
  if [[ $struct_ec -ne 0 ]]; then
    ok=false
    verdicts+=("STRUCT_FAIL")
    if [[ -n "$STRUCT_ERR" ]]; then
      # collapse newlines
      se=$(printf '%s' "$STRUCT_ERR" | tr '\n' ' ')
      blocking+=("structure:$se")
    else
      blocking+=("structure:unknown")
    fi
  else
    verdicts+=("STRUCT_OK")
  fi
else
  ok=false
  blocking+=("plan_json_missing_for_structure")
fi

# --- forks.md: unresolved open forks block PLAN_READY ---
FORKS="$RUN_DIR/forks.md"
if [[ -s "$FORKS" ]]; then
  paths_checked+=("$FORKS#open_forks")
  # Fail if any line looks like an OPEN unresolved fork (not LOCKED/DEFERRED)
  if grep -Eiq '^\s*[-*].*\bOPEN\b' "$FORKS" 2>/dev/null; then
    ok=false
    verdicts+=("OPEN_FORKS")
    blocking+=("unresolved_open_forks")
  else
    verdicts+=("FORKS_OK")
  fi
fi

if $ok; then
  emit_and_exit true "plan-harden gate PASS (${#paths_checked[@]} checks)" "" 0
else
  # dedupe-ish summary
  sum="plan-harden gate FAIL: ${#blocking[@]} blocking"
  emit_and_exit false "$sum" "$sum" 1
fi
