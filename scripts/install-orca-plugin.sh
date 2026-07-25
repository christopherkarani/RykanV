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
  opencode|openclaw|hermes|hermess|codex|claude) ;;
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

if [ "$HOST" = "hermess" ]; then
  HOST="hermes"
fi

read_repo_version() {
  if [ -f "${REPO_ROOT}/VERSION" ]; then
    tr -d '[:space:]' < "${REPO_ROOT}/VERSION"
  else
    printf '1.2.0'
  fi
}

orca_executable() {
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

orca_supports_hermes() {
  orca_bin="$1"
  smoke_fixture="${REPO_ROOT}/tests/fixtures/hook-safe.json"
  output=$(cat "${smoke_fixture}" | "$orca_bin" hook hermes pre_tool_call 2>/dev/null) || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(1 if d.get("decision") == "block" else 0)' 2>/dev/null
    return $?
  fi
  case "$output" in
    *'"decision":"block"'*|*'"decision": "block"'*) return 1 ;;
    *) return 0 ;;
  esac
}

orca_candidate_ok() {
  orca_bin="$1"
  if [ "$HOST" = "hermes" ]; then
    orca_supports_hermes "$orca_bin"
    return $?
  fi
  orca_executable "$orca_bin" >/dev/null 2>&1
}

resolve_orca_bin() {
  for candidate in \
    "${ORCA_BIN:-}" \
    "${REPO_ROOT}/zig-out/bin/orca" \
    "${HOME}/.local/bin/orca" \
    "${HOME}/.orca/bin/orca" \
    "$(command -v orca 2>/dev/null || true)"
  do
    [ -n "$candidate" ] || continue
    resolved="$(orca_executable "$candidate" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    if orca_candidate_ok "$resolved"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

if ! ORCA_BIN="$(resolve_orca_bin)"; then
  export ORCA_VERSION="$(read_repo_version)"
  if [ -d "${REPO_ROOT}/dist" ]; then
    export ORCA_ARTIFACT_DIR="${REPO_ROOT}/dist"
  fi
  "${REPO_ROOT}/scripts/install.sh"
  INSTALL_DIR="${ORCA_INSTALL_DIR:-${HOME}/.local/bin}"
  ORCA_BIN="${INSTALL_DIR}/orca"
fi

if ! orca_executable "$ORCA_BIN" >/dev/null 2>&1; then
  echo "ryk binary not found after install attempt" >&2
  exit 1
fi

ORCA_BIN="$(orca_executable "$ORCA_BIN")"

if [ "$HOST" = "hermes" ] && ! orca_supports_hermes "$ORCA_BIN"; then
  echo "ryk at ${ORCA_BIN} does not support Hermes hooks (upgrade required)" >&2
  echo "Hint: build locally (zig build) or set RYK_BIN to a current ryk binary" >&2
  exit 1
fi

if [ "$HOST" = "opencode" ]; then
  "$ORCA_BIN" plugin install opencode --scope "$SCOPE" --yes
elif [ "$HOST" = "openclaw" ]; then
  "$ORCA_BIN" plugin install openclaw --yes
else
  "$ORCA_BIN" plugin install "$HOST" --yes
fi

"$ORCA_BIN" plugin doctor "$HOST"
