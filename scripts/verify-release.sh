#!/usr/bin/env sh
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${1:-${RYK_DIST_DIR:-${ORCA_DIST_DIR:-dist}}}"
RELEASE_PRODUCT="${RYK_RELEASE_PRODUCT:-${ORCA_RELEASE_PRODUCT:-all}}"

fail() {
  printf 'release verify: %s\n' "$1" >&2
  exit 1
}

checksum_for_name() {
  name="$1"
  awk -v name="$name" '$2 == name {print $1}' "$DIST_DIR/checksums.txt"
}

require_artifact() {
  pattern="$1"
  found=0
  for artifact in $pattern; do
    [ -f "$artifact" ] || continue
    found=1
    name="$(basename "$artifact")"
    [ -n "$(checksum_for_name "$name")" ] || fail "missing checksum entry for $name"
    grep -q "\"name\":\"$name\"" "$DIST_DIR/release-manifest.json" ||
      fail "missing release-manifest.json artifact entry for $name"
  done
  [ "$found" = "1" ] || fail "missing artifact pattern $pattern"
}

require_archive_binary() {
  pattern="$1"
  binary="$2"
  found=0
  for artifact in $pattern; do
    [ -f "$artifact" ] || continue
    found=1
    name="$(basename "$artifact")"
    case "$name" in
      *.tar.gz)
        tar -tzf "$artifact" | grep -q "^[^/]*/bin/$binary$" ||
          fail "artifact $name missing bin/$binary"
        ;;
      *.zip)
        command -v unzip >/dev/null 2>&1 || fail "unzip is required to inspect $name"
        unzip -Z1 "$artifact" | grep -q "^[^/]*/bin/$binary$" ||
          fail "artifact $name missing bin/$binary"
        ;;
      *)
        fail "unsupported archive format: $name"
        ;;
    esac
  done
  [ "$found" = "1" ] || fail "missing artifact pattern $pattern"
}

# Backward-compat alias used by older call sites.
require_orca_archive_binary() {
  require_archive_binary "$@"
}

disallowed_archive_path() {
  case "$1" in
    */schemas/safety-report*|\
    */customer_pilot/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_archive_excludes() {
  pattern="$1"
  found=0
  for artifact in $pattern; do
    [ -f "$artifact" ] || continue
    found=1
    name="$(basename "$artifact")"
    case "$name" in
      *.tar.gz)
        listing="$(tar -tzf "$artifact")"
        ;;
      *.zip)
        command -v unzip >/dev/null 2>&1 || fail "unzip is required to inspect $name"
        listing="$(unzip -Z1 "$artifact")"
        ;;
      *)
        fail "unsupported archive format: $name"
        ;;
    esac

    for path in $listing; do
      if disallowed_archive_path "$path"; then
        fail "artifact $name contains Edge-only path: $path"
      fi
    done
  done
  [ "$found" = "1" ] || fail "missing artifact pattern $pattern"
}

artifact_package_key() {
  case "$1" in
    ryk-v*-darwin-amd64.tar.gz|orca-v*-darwin-amd64.tar.gz) printf 'darwin-amd64' ;;
    ryk-v*-darwin-arm64.tar.gz|orca-v*-darwin-arm64.tar.gz) printf 'darwin-arm64' ;;
    ryk-v*-linux-amd64.tar.gz|orca-v*-linux-amd64.tar.gz) printf 'linux-amd64' ;;
    ryk-v*-linux-arm64.tar.gz|orca-v*-linux-arm64.tar.gz) printf 'linux-arm64' ;;
    ryk-v*-windows-amd64.zip|orca-v*-windows-amd64.zip) printf 'windows-amd64' ;;
    *) fail "unsupported package artifact name: $1" ;;
  esac
}

detect_host_target() {
  host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  host_arch="$(uname -m)"
  case "$host_arch" in
    x86_64|amd64) host_arch="amd64" ;;
    arm64|aarch64) host_arch="arm64" ;;
  esac
  printf '%s-%s' "$host_os" "$host_arch"
}

artifact_manifest_name() {
  case "$1" in
    ryk-v*-darwin-amd64.tar.gz) printf 'ryk-v#{version}-darwin-amd64.tar.gz' ;;
    ryk-v*-darwin-arm64.tar.gz) printf 'ryk-v#{version}-darwin-arm64.tar.gz' ;;
    ryk-v*-linux-amd64.tar.gz) printf 'ryk-v#{version}-linux-amd64.tar.gz' ;;
    ryk-v*-linux-arm64.tar.gz) printf 'ryk-v#{version}-linux-arm64.tar.gz' ;;
    orca-v*-darwin-amd64.tar.gz) printf 'orca-v#{version}-darwin-amd64.tar.gz' ;;
    orca-v*-darwin-arm64.tar.gz) printf 'orca-v#{version}-darwin-arm64.tar.gz' ;;
    orca-v*-linux-amd64.tar.gz) printf 'orca-v#{version}-linux-amd64.tar.gz' ;;
    orca-v*-linux-arm64.tar.gz) printf 'orca-v#{version}-linux-arm64.tar.gz' ;;
    *) printf '%s' "$1" ;;
  esac
}

require_manifest_hash_for_artifact() {
  manifest="$1"
  artifact_name="$2"
  hash="$(checksum_for_name "$artifact_name")"
  [ -n "$hash" ] || fail "missing checksum entry for $artifact_name"

  case "$manifest" in
    */homebrew/Formula/ryk.rb|*/homebrew/Formula/orca.rb)
      manifest_name="$(artifact_manifest_name "$artifact_name")"
      # Prefer ryk-named entries; accept either in dual-name formulas.
      awk -v name="$manifest_name" -v hash="$hash" -v raw="$artifact_name" '
        index($0, name) || index($0, raw) { seen = 1; window = 8 }
        seen && index($0, hash) { ok = 1 }
        seen { window -= 1; if (window <= 0) seen = 0 }
        END { exit ok ? 0 : 1 }
      ' "$manifest" || fail "rendered Homebrew formula checksum is not bound to $artifact_name"
      ;;
    */npm/package.json)
      key="$(artifact_package_key "$artifact_name")"
      grep -Eq "\"$key\"[[:space:]]*:[[:space:]]*\"$hash\"" "$manifest" ||
        fail "rendered npm package checksum is not bound to $artifact_name"
      ;;
    */scoop/ryk.json|*/scoop/orca.json|*/winget/ryk.yaml|*/winget/orca.yaml)
      grep -q "$artifact_name" "$manifest" ||
        fail "rendered manifest $(basename "$manifest") missing artifact URL for $artifact_name"
      grep -q "$hash" "$manifest" ||
        fail "rendered manifest $(basename "$manifest") missing checksum for $artifact_name"
      ;;
    *)
      fail "unsupported rendered package manifest: $manifest"
      ;;
  esac
}

require_package_hashes() {
  homebrew_ryk="$DIST_DIR/package-manifests/homebrew/Formula/ryk.rb"
  homebrew_orca="$DIST_DIR/package-manifests/homebrew/Formula/orca.rb"
  npm="$DIST_DIR/package-manifests/npm/package.json"

  for artifact in \
    "$DIST_DIR"/ryk-v*-darwin-amd64.tar.gz \
    "$DIST_DIR"/ryk-v*-darwin-arm64.tar.gz \
    "$DIST_DIR"/ryk-v*-linux-amd64.tar.gz \
    "$DIST_DIR"/ryk-v*-linux-arm64.tar.gz
  do
    [ -f "$artifact" ] || continue
    name="$(basename "$artifact")"
    if [ -f "$homebrew_ryk" ]; then
      require_manifest_hash_for_artifact "$homebrew_ryk" "$name"
    elif [ -f "$homebrew_orca" ]; then
      require_manifest_hash_for_artifact "$homebrew_orca" "$name"
    fi
    require_manifest_hash_for_artifact "$npm" "$name"
  done
}

# Product archives ship the Zig CLI only (shell evaluation is in-process shell_engine).
forbid_archive_binary() {
  pattern="$1"
  binary="$2"
  found=0
  for artifact in $pattern; do
    [ -f "$artifact" ] || continue
    found=1
    name="$(basename "$artifact")"
    case "$name" in
      *.tar.gz)
        if tar -tzf "$artifact" | grep -q "^[^/]*/bin/$binary$"; then
          fail "artifact $name unexpectedly contains bin/$binary (daemon removed from product packaging)"
        fi
        ;;
      *.zip)
        command -v unzip >/dev/null 2>&1 || fail "unzip is required to inspect $name"
        if unzip -Z1 "$artifact" | grep -q "^[^/]*/bin/$binary$"; then
          fail "artifact $name unexpectedly contains bin/$binary (daemon removed from product packaging)"
        fi
        ;;
      *)
        fail "unsupported archive format: $name"
        ;;
    esac
  done
  [ "$found" = "1" ] || fail "missing artifact pattern $pattern"
}

require_cli_pair() {
  # Primary ryk + orca compat alias both required in primary archives.
  pattern="$1"
  require_archive_binary "$pattern" "ryk"
  require_archive_binary "$pattern" "orca"
  forbid_archive_binary "$pattern" "orca-daemon"
  require_archive_excludes "$pattern"
}

require_release_artifacts() {
  case "$RELEASE_PRODUCT" in
    all | cli)
      require_artifact "$DIST_DIR/ryk-v*-darwin-amd64.tar.gz"
      require_artifact "$DIST_DIR/ryk-v*-darwin-arm64.tar.gz"
      require_artifact "$DIST_DIR/ryk-v*-linux-amd64.tar.gz"
      require_artifact "$DIST_DIR/ryk-v*-linux-arm64.tar.gz"
      require_cli_pair "$DIST_DIR/ryk-v*-darwin-amd64.tar.gz"
      require_cli_pair "$DIST_DIR/ryk-v*-darwin-arm64.tar.gz"
      require_cli_pair "$DIST_DIR/ryk-v*-linux-amd64.tar.gz"
      require_cli_pair "$DIST_DIR/ryk-v*-linux-arm64.tar.gz"
      ;;
    host)
      case "$(detect_host_target)" in
        darwin-amd64)
          require_artifact "$DIST_DIR/ryk-v*-darwin-amd64.tar.gz"
          require_cli_pair "$DIST_DIR/ryk-v*-darwin-amd64.tar.gz"
          ;;
        darwin-arm64)
          require_artifact "$DIST_DIR/ryk-v*-darwin-arm64.tar.gz"
          require_cli_pair "$DIST_DIR/ryk-v*-darwin-arm64.tar.gz"
          ;;
        linux-amd64)
          require_artifact "$DIST_DIR/ryk-v*-linux-amd64.tar.gz"
          require_cli_pair "$DIST_DIR/ryk-v*-linux-amd64.tar.gz"
          ;;
        linux-arm64)
          require_artifact "$DIST_DIR/ryk-v*-linux-arm64.tar.gz"
          require_cli_pair "$DIST_DIR/ryk-v*-linux-arm64.tar.gz"
          ;;
        windows-amd64)
          require_artifact "$DIST_DIR/ryk-v*-windows-amd64.zip"
          require_archive_binary "$DIST_DIR/ryk-v*-windows-amd64.zip" "ryk.exe"
          require_archive_binary "$DIST_DIR/ryk-v*-windows-amd64.zip" "orca.exe"
          forbid_archive_binary "$DIST_DIR/ryk-v*-windows-amd64.zip" "orca-daemon.exe"
          require_archive_excludes "$DIST_DIR/ryk-v*-windows-amd64.zip"
          ;;
        *)
          fail "unsupported host target for host-only release verification"
          ;;
      esac
      ;;
    *)
      fail "unsupported RELEASE_PRODUCT=${RELEASE_PRODUCT}"
      ;;
  esac
}

[ -d "$DIST_DIR" ] || fail "missing dist dir: $DIST_DIR"
[ -s "$DIST_DIR/checksums.txt" ] || fail "missing checksums.txt"
[ -s "$DIST_DIR/release-manifest.json" ] || fail "missing release-manifest.json"
[ -s "$DIST_DIR/sbom.json" ] || fail "missing sbom.json"
if [ "$RELEASE_PRODUCT" != "host" ]; then
  if [ ! -s "$DIST_DIR/package-manifests/homebrew/Formula/ryk.rb" ] && \
     [ ! -s "$DIST_DIR/package-manifests/homebrew/Formula/orca.rb" ]; then
    fail "missing rendered Homebrew formula (ryk.rb or orca.rb)"
  fi
  [ -s "$DIST_DIR/package-manifests/npm/package.json" ] || fail "missing rendered npm package manifest"
  if [ ! -s "$DIST_DIR/package-manifests/npm/bin/ryk.js" ] && \
     [ ! -s "$DIST_DIR/package-manifests/npm/bin/orca.js" ]; then
    fail "missing rendered npm launcher (ryk.js or orca.js)"
  fi
fi
grep -q '"products_included"' "$DIST_DIR/release-manifest.json" || fail "release-manifest.json missing products_included"
grep -q '"ryk"' "$DIST_DIR/release-manifest.json" || fail "release-manifest.json missing ryk product"
# Daemon product was removed; packaging is CLI + core only (Zig shell_engine in-process).
if grep -q '"orca-daemon"' "$DIST_DIR/release-manifest.json"; then
  fail "release-manifest.json still lists orca-daemon product (removed from packaging)"
fi
if grep -q '"orca-daemon"' "$DIST_DIR/sbom.json"; then
  fail "sbom.json still lists orca-daemon component (removed from packaging)"
fi
# SBOM may still list orca (compat) or ryk (primary).
if ! grep -qE '"ryk"|"orca"' "$DIST_DIR/sbom.json"; then
  fail "sbom.json missing ryk/orca component"
fi
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && sha256sum -c checksums.txt)
else
  (cd "$DIST_DIR" && shasum -a 256 -c checksums.txt)
fi

require_release_artifacts
grep -q '"signing_status"' "$DIST_DIR/release-manifest.json"
grep -q '"sbom_status"' "$DIST_DIR/release-manifest.json"
if [ "$RELEASE_PRODUCT" != "host" ]; then
  for rendered in \
    "$DIST_DIR/package-manifests/homebrew/Formula/ryk.rb" \
    "$DIST_DIR/package-manifests/homebrew/Formula/orca.rb" \
    "$DIST_DIR/package-manifests/npm/package.json"
  do
    [ -f "$rendered" ] || continue
    ! grep -q 'PLACEHOLDER' "$rendered" || { printf 'release verify: placeholder left in %s\n' "$rendered" >&2; exit 1; }
  done
  require_package_hashes
fi

# Plugin version alignment check
CLI_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
HERMES_VERSION=$(grep "^version:" "${REPO_ROOT}/integrations/hermes-plugin/plugin.yaml" | sed 's/version: *//')
OPENCLAW_VERSION=$(grep '"version"' "${REPO_ROOT}/integrations/openclaw-plugin/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
CODEX_VERSION=$(grep '"version"' "${REPO_ROOT}/integrations/codex-plugin/.codex-plugin/plugin.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
CLAUDE_VERSION=$(grep '"version"' "${REPO_ROOT}/integrations/claude-code-plugin/.claude-plugin/plugin.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
OPENCODE_VERSION=$(grep '"version"' "${REPO_ROOT}/integrations/opencode-plugin/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
# Pi runtime dependency may be @orca-sec/ryk (primary) or legacy @orca-sec/orca.
PI_RUNTIME_VERSION=$(grep -E '"@orca-sec/(ryk|orca)"' "${REPO_ROOT}/orca-pi/package.json" | head -1 | sed 's/.*"@orca-sec\/[^"]*": *"\([^"]*\)".*/\1/')
for plugin_version in "${HERMES_VERSION}" "${OPENCLAW_VERSION}" "${CODEX_VERSION}" "${CLAUDE_VERSION}" "${OPENCODE_VERSION}" "${PI_RUNTIME_VERSION}"; do
  if [ "${plugin_version}" != "${CLI_VERSION}" ]; then
    echo "ERROR: plugin version mismatch (expected ${CLI_VERSION}, got ${plugin_version})" >&2
    exit 1
  fi
done

printf 'release verify: passed\n'
printf 'Limitations: ryk release assets cover local CLI/runtime guardrails only; no hosted telemetry or cloud enforcement is included. orca is a PATH/package compat alias for one major.\n'
