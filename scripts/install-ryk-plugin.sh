#!/usr/bin/env sh
set -eu

HOST="${1:-}"
SCOPE="${2:-project}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -z "$HOST" ]; then
  echo "Usage: $0 <opencode|openclaw|hermes|codex|claude> [project|global]" >&2
  exit 2
fi

case "$HOST" in
  opencode|openclaw|hermes|codex|claude) ;;
  *)
    echo "unsupported host: $HOST (expected opencode|openclaw|hermes|codex|claude)" >&2
    exit 2
    ;;
esac

case "$SCOPE" in
  project|global) ;;
  *)
    echo "unsupported scope: $SCOPE (expected project|global)" >&2
    exit 2
    ;;
esac

read_repo_version() {
  if [ -f "${REPO_ROOT}/VERSION" ]; then
    tr -d '[:space:]' < "${REPO_ROOT}/VERSION"
  else
    printf '1.2.9'
  fi
}

ryk_executable() {
  candidate="$1"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if command -v "$candidate" >/dev/null 2>&1; then
    command -v "$candidate"
    return 0
  fi
  return 1
}

ryk_supports_hermes() {
  ryk_bin="$1"
  smoke_fixture="${REPO_ROOT}/tests/fixtures/hook-safe.json"
  output=$(cat "${smoke_fixture}" | "$ryk_bin" hook hermes pre_tool_call 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("decision") in {"allow", "warn", "ask"} else 1)' 2>/dev/null
    return $?
  fi
  printf '%s' "$output" | grep -E '"decision"[[:space:]]*:[[:space:]]*"(allow|warn|ask)"' >/dev/null
}

ryk_candidate_ok() {
  ryk_bin="$1"
  if [ "$HOST" = "hermes" ]; then
    ryk_supports_hermes "$ryk_bin"
    return $?
  fi
  ryk_executable "$ryk_bin" >/dev/null 2>&1
}

resolve_ryk_bin() {
  for candidate in \
    "${RYK_BIN:-}" \
    "${REPO_ROOT}/zig-out/bin/ryk" \
    "${HOME}/.local/bin/ryk" \
    "${HOME}/.ryk/bin/ryk" \
    "$(command -v ryk 2>/dev/null || true)"
  do
    [ -n "$candidate" ] || continue
    resolved="$(ryk_executable "$candidate" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    if ryk_candidate_ok "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

if ! RYK_BIN="$(resolve_ryk_bin)"; then
  export RYK_VERSION="$(read_repo_version)"
  if [ -d "${REPO_ROOT}/dist" ]; then
    export RYK_ARTIFACT_DIR="${REPO_ROOT}/dist"
  fi
  "${REPO_ROOT}/scripts/install.sh"
  INSTALL_DIR="${RYK_INSTALL_DIR:-${HOME}/.local/bin}"
  RYK_BIN="${INSTALL_DIR}/ryk"
fi

if ! ryk_executable "$RYK_BIN" >/dev/null 2>&1; then
  echo "ryk binary not found after install attempt" >&2
  exit 1
fi

RYK_BIN="$(ryk_executable "$RYK_BIN")"

if [ "$HOST" = "hermes" ] && ! ryk_supports_hermes "$RYK_BIN"; then
  echo "ryk at ${RYK_BIN} does not support Hermes hooks (upgrade required)" >&2
  echo "Hint: build locally (./scripts/zig build) or set RYK_BIN to a current ryk binary" >&2
  exit 1
fi

if [ "$HOST" = "opencode" ]; then
  "$RYK_BIN" plugin install opencode --scope "$SCOPE" --yes
elif [ "$HOST" = "openclaw" ]; then
  "$RYK_BIN" plugin install openclaw --yes
else
  "$RYK_BIN" plugin install "$HOST" --yes
fi

"$RYK_BIN" plugin doctor "$HOST"
