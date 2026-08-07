#!/usr/bin/env bash
# Live host E2E: exercise each host's real ryk veto path when the host (or evaluate) is available.
#
# Fixture/install smoke (`ryk hook …`) proves the CLI entrypoint offline.
# This script is the optional live path: skip honestly when host/RYK_BIN missing.
# Not part of default `test-fast` — do not make CI flaky.
#
# Usage:
#   ./scripts/host-live-e2e.sh              # all hosts
#   ./scripts/host-live-e2e.sh codex hermes # subset
#   RYK_BIN=/path/to/ryk ./scripts/host-live-e2e.sh
#
# Exit: 0 if no hard failures (skips OK); 1 if any host present failed allow or deny.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RYK_BIN="${RYK_BIN:-}"
if [[ -z "$RYK_BIN" ]]; then
  if [[ -x "$ROOT/zig-out/bin/ryk" ]]; then
    RYK_BIN="$ROOT/zig-out/bin/ryk"
  elif command -v ryk >/dev/null 2>&1; then
    RYK_BIN="$(command -v ryk)"
  fi
fi

SAFE_CMD='git status'
DANGER_CMD='rm -rf /'

ALL_HOSTS=(codex claude opencode openclaw hermes pi)
REQUESTED=("$@")
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  HOSTS=("${ALL_HOSTS[@]}")
else
  HOSTS=("${REQUESTED[@]}")
fi

pass=0
fail=0
skip=0

log() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

resolve_event() {
  case "$1" in
    codex|claude) echo PreToolUse ;;
    opencode) echo tool.execute.before ;;
    openclaw) echo tool.before ;;
    hermes) echo pre_tool_call ;;
    pi) echo evaluate ;;
    *) echo unknown ;;
  esac
}

fixture_for() {
  local host="$1" event="$2" cmd="$3"
  case "$host" in
    hermes)
      printf '{"version":1,"host":"hermes","event":"%s","payload":{"tool_name":"terminal","tool_input":{"command":"%s"},"command":"%s"}}' \
        "$event" "$cmd" "$cmd"
      ;;
    opencode)
      printf '{"version":1,"host":"opencode","event":"%s","payload":{"tool":"bash","sessionID":"live-e2e","callID":"1","command":"%s","args":{"command":"%s"}}}' \
        "$event" "$cmd" "$cmd"
      ;;
    openclaw)
      printf '{"version":1,"host":"openclaw","event":"%s","payload":{"tool":"bash","command":"%s"}}' \
        "$event" "$cmd"
      ;;
    codex|claude)
      printf '{"version":1,"host":"%s","event":"%s","payload":{"tool_name":"Bash","tool_input":{"command":"%s"}}}' \
        "$host" "$event" "$cmd"
      ;;
    *)
      return 1
      ;;
  esac
}

interpret_allow() {
  local host="$1" code="$2" stdout="$3"
  [[ "$code" == "0" ]] || return 1
  printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"allow"' || return 1
  return 0
}

interpret_deny() {
  local host="$1" code="$2" stdout="$3"
  if [[ "$host" == "codex" ]]; then
    # Codex deny: exit 2 + stderr sentinel (stdout JSON intentionally empty).
    [[ "$code" == "2" ]] && return 0
    printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && return 0
    return 1
  fi
  [[ "$code" == "0" ]] || return 1
  printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' || return 1
  return 0
}

run_hook_case() {
  local host="$1" expected="$2" cmd="$3"
  local event out code
  event="$(resolve_event "$host")"
  out="$(mktemp)"
  set +e
  fixture_for "$host" "$event" "$cmd" | "$RYK_BIN" hook "$host" "$event" >"$out" 2>/dev/null
  code=$?
  set -e
  local body
  body="$(cat "$out")"
  rm -f "$out"
  if [[ "$expected" == "allow" ]]; then
    interpret_allow "$host" "$code" "$body"
  else
    interpret_deny "$host" "$code" "$body"
  fi
}

run_pi_case() {
  local expected="$1" cmd="$2"
  local cwd out code payload
  cwd="$(pwd)"
  payload="$(printf '{"schema_version":1,"request_id":"live-e2e","kind":"shell_command","command":"%s","cwd":"%s","source":{"host":"pi","tool_name":"bash","mode":"tui","session_id":"live-e2e"}}' \
    "$cmd" "$cwd")"
  out="$(mktemp)"
  set +e
  printf '%s' "$payload" | "$RYK_BIN" evaluate --json --stdin >"$out" 2>/dev/null
  code=$?
  set -e
  local body
  body="$(cat "$out")"
  rm -f "$out"
  if [[ "$expected" == "allow" ]]; then
    [[ "$code" == "0" ]] || return 1
    printf '%s' "$body" | grep -Eq '"decision"[[:space:]]*:[[:space:]]*"(allow|ALLOW)"' \
      || printf '%s' "$body" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"Allow"' \
      || return 1
    return 0
  fi
  # deny: exit 2 preferred; also accept decision deny/block in JSON
  if [[ "$code" == "2" ]]; then
    return 0
  fi
  printf '%s' "$body" | grep -Eqi '"decision"[[:space:]]*:[[:space:]]*"(deny|block)"' \
    || printf '%s' "$body" | grep -Eqi '"status"[[:space:]]*:[[:space:]]*"(Deny|Block)"' \
    || return 1
  return 0
}

host_present() {
  local host="$1"
  case "$host" in
    pi)
      # Real Pi host sessions need the `pi` CLI; evaluate path is still exercised when present.
      have "pi"
      ;;
    *)
      have "$host"
      ;;
  esac
}

live_note() {
  case "$1" in
    codex) echo "hooks.json → ryk hook codex PreToolUse (deny=exit 2)" ;;
    claude) echo "settings hooks → ryk hook claude PreToolUse (JSON decision)" ;;
    opencode) echo "plugin throw path ← tool.execute.before decision" ;;
    openclaw) echo "plugin tool.before → JSON block" ;;
    hermes) echo "Hermes plugin pre_tool_call → {action:block}; fixture uses ryk hook" ;;
    pi) echo "direct smoke: evaluate bash; extension also protects write/edit/read and approval-gates grep/find/ls after root preflight (not exercised here)" ;;
  esac
}

if [[ -z "$RYK_BIN" || ! -x "$RYK_BIN" ]]; then
  log "RYK_BIN missing — cannot run live E2E. Build with ./scripts/zig build or set RYK_BIN."
  log "status: skipped (no ryk binary)"
  exit 0
fi

log "ryk live host E2E"
log "  ryk: $RYK_BIN"
log "  note: fixture path via ryk hook/evaluate; host CLI presence gates skip vs run"
log ""

for host in "${HOSTS[@]}"; do
  event="$(resolve_event "$host")"
  if [[ "$event" == "unknown" ]]; then
    log "[$host] skip — unknown host"
    skip=$((skip + 1))
    continue
  fi

  if ! host_present "$host"; then
    log "[$host] skip — host not installed (live: skipped — host not installed)"
    if [[ "$host" == "pi" ]]; then
      log "         install Pi, then: pi install npm:@rykan/pi-ryk"
    else
      log "         fixture smoke still available via: ryk plugin install $host / ryk plugin doctor $host"
    fi
    log "         live differs: $(live_note "$host")"
    skip=$((skip + 1))
    continue
  fi

  log "[$host] run — gate=$(resolve_event "$host"); $(live_note "$host")"

  allow_ok=0
  deny_ok=0
  if [[ "$host" == "pi" ]]; then
    if run_pi_case allow "$SAFE_CMD"; then allow_ok=1; fi
    if run_pi_case deny "$DANGER_CMD"; then deny_ok=1; fi
  else
    if run_hook_case "$host" allow "$SAFE_CMD"; then allow_ok=1; fi
    if run_hook_case "$host" deny "$DANGER_CMD"; then deny_ok=1; fi
  fi

  if [[ "$allow_ok" -eq 1 && "$deny_ok" -eq 1 ]]; then
    log "  readiness: protected (allow+deny pass)"
    pass=$((pass + 1))
  elif [[ "$deny_ok" -eq 1 && "$allow_ok" -eq 0 ]]; then
    log "  readiness: degraded (deny ok, allow failed — policy/eval? fix: ryk doctor)"
    # Degraded is not a hard fail for protection proof, but counts as fail for usability gate.
    fail=$((fail + 1))
  elif [[ "$deny_ok" -eq 0 ]]; then
    log "  readiness: not-protected (deny failed)"
    fail=$((fail + 1))
  else
    log "  readiness: unknown"
    fail=$((fail + 1))
  fi
  log "  smoke allow=$([[ $allow_ok -eq 1 ]] && echo pass || echo fail) deny=$([[ $deny_ok -eq 1 ]] && echo pass || echo fail)"
done

log ""
log "summary: pass=$pass fail=$fail skip=$skip"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
