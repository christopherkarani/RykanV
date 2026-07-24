#!/usr/bin/env sh
set -eu

# Phase 5a: primary product brand is ryk; dual-name env RYK_* then ORCA_*.
VERSION="${RYK_VERSION:-${ORCA_VERSION:-$(tr -d '[:space:]' <"$(dirname "$0")/../VERSION" 2>/dev/null || printf '1.2.0')}}"
COMMIT="${RYK_COMMIT:-${ORCA_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || printf unknown)}}"
BUILD_DATE="${RYK_BUILD_DATE:-${ORCA_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}}"
DIST_DIR="${RYK_DIST_DIR:-${ORCA_DIST_DIR:-dist}}"
ZIG_OPTIMIZE="${RYK_ZIG_OPTIMIZE:-${ORCA_ZIG_OPTIMIZE:-ReleaseSafe}}"
RELEASE_PRODUCT="${RYK_RELEASE_PRODUCT:-${ORCA_RELEASE_PRODUCT:-all}}"
CLI_ARTIFACT_DIR="${RYK_CLI_ARTIFACT_DIR:-${ORCA_CLI_ARTIFACT_DIR:-}}"
# Dual-publish orca-v* alias archives (same bytes as ryk-v*) for one major.
DUAL_PUBLISH_ORCA="${RYK_DUAL_PUBLISH_ORCA:-${ORCA_DUAL_PUBLISH_ORCA:-1}}"
SIGNING_STATUS="not_configured"

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
x86_64) HOST_ARCH="amd64" ;;
aarch64 | arm64) HOST_ARCH="arm64" ;;
esac

# Phase 5a artifact contract (primary):
# - ryk-v{version}-darwin-amd64.tar.gz
# - ryk-v{version}-darwin-arm64.tar.gz
# - ryk-v{version}-linux-amd64.tar.gz
# - ryk-v{version}-linux-arm64.tar.gz
# Archive root contains bin/ryk (primary) + bin/orca (compat alias).
# When DUAL_PUBLISH_ORCA=1, also emit orca-v* copies of the same archives.

CLI_TARGETS="
darwin amd64 x86_64-macos tar.gz ryk
darwin arm64 aarch64-macos tar.gz ryk
linux amd64 x86_64-linux tar.gz ryk
linux arm64 aarch64-linux tar.gz ryk
"

selected_targets() {
  case "$RELEASE_PRODUCT" in
    all | cli)
      printf '%s\n' "$CLI_TARGETS"
      ;;
    host)
      case "$HOST_OS-$HOST_ARCH" in
        darwin-amd64) printf 'darwin amd64 x86_64-macos tar.gz ryk\n' ;;
        darwin-arm64) printf 'darwin arm64 aarch64-macos tar.gz ryk\n' ;;
        linux-amd64) printf 'linux amd64 x86_64-linux tar.gz ryk\n' ;;
        linux-arm64) printf 'linux arm64 aarch64-linux tar.gz ryk\n' ;;
        windows-amd64) printf 'windows amd64 x86_64-windows zip ryk.exe\n' ;;
        *) printf 'build-release: unsupported host target for release dry-run: %s-%s\n' "$HOST_OS" "$HOST_ARCH" >&2; exit 1 ;;
      esac
      ;;
    *)
      printf 'build-release: unsupported RELEASE_PRODUCT=%s (expected all, cli, or host)\n' "$RELEASE_PRODUCT" >&2
      exit 1
      ;;
  esac
}

target_platforms_json() {
  case "$RELEASE_PRODUCT" in
    all | cli) printf '["darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64"]' ;;
    host) printf '["%s-%s"]' "$HOST_OS" "$HOST_ARCH" ;;
    *) printf '[]' ;;
  esac
}

copy_cli_payload() {
  root="$1"
  mkdir -p "$root"
  cp README.md LICENSE SECURITY.md CONTRIBUTING.md "$root/"
  cp -R docs policies schemas fixtures examples packages packaging scripts integrations "$root/"
  if [ -d "orca-dashboard-ui/dist" ]; then
    mkdir -p "$root/orca-dashboard-ui"
    cp -R orca-dashboard-ui/dist "$root/orca-dashboard-ui/dist"
  elif [ -f "src/dashboard/assets/index.html" ]; then
    printf 'error: orca-dashboard-ui/dist/ missing but legacy src/dashboard/assets/ exists.\n' >&2
    printf 'error: Run "npm ci && npm run build" in orca-dashboard-ui/ before creating a release.\n' >&2
    printf 'error: The legacy fallback has been intentionally removed to prevent shipping the wrong dashboard.\n' >&2
    exit 1
  else
    printf 'warning: dashboard UI assets not found; ryk dashboard will be unavailable in this artifact.\n' >&2
  fi
  find "$root" -type d \( \
    -name node_modules -o \
    -name __pycache__ -o \
    -name .pytest_cache -o \
    -name .pnpm-store -o \
    -name .yarn -o \
    -name .turbo -o \
    -name .cache \
    \) -prune -exec rm -rf {} +
  find "$root" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
  rm -rf \
    "$root/docs/integrations/drone-safepoint.md" \
    "$root/docs/integrations/drone-safety.md" \
    "$root/schemas/safety-report"* \
    "$root/.DS_Store" \
    "$root/docs/.DS_Store" \
    "$root/packages/.DS_Store" \
    "$root/examples/.DS_Store" \
    "$root/orca-dashboard-ui/node_modules" 2>/dev/null || true
}

write_release_readme() {
  root="$1"
  title="ryk ${VERSION} Release Artifact"
  boundary="This archive contains the ryk CLI (primary binary) plus an orca compat alias, and Core policy, audit, replay, redaction, schema, integration, and packaging resources. Edge runtime, drone, SITL, and customer-pilot materials are intentionally excluded."
  cat >"$root/README-release.md" <<EOF
# ${title}

This artifact is built from commit ${COMMIT} at ${BUILD_DATE}.

Primary CLI: \`bin/ryk\`. Legacy alias: \`bin/orca\` (same product).

Verify the archive against the top-level checksums.txt before installing:

\`\`\`sh
sha256sum -c checksums.txt
\`\`\`

${boundary}
EOF
}

# CLI-only archives: Zig shell_engine evaluates in-process (no orca-daemon product binary).

install_primary_and_alias() {
  # Copy primary ryk binary into root/bin and ensure orca alias exists.
  os="$1"
  prefix="$2"
  root="$3"
  bin_name="$4"

  primary_src=""
  alias_src=""
  if [ "$os" = "windows" ]; then
    if [ -f "$prefix/bin/ryk.exe" ]; then
      primary_src="$prefix/bin/ryk.exe"
    elif [ -f "$prefix/bin/$bin_name" ]; then
      primary_src="$prefix/bin/$bin_name"
    elif [ -f "$prefix/bin/orca.exe" ]; then
      primary_src="$prefix/bin/orca.exe"
    fi
    if [ -f "$prefix/bin/orca.exe" ]; then
      alias_src="$prefix/bin/orca.exe"
    fi
    [ -n "$primary_src" ] || {
      printf 'missing ryk/orca binary in %s\n' "$prefix/bin" >&2
      exit 1
    }
    cp "$primary_src" "$root/bin/ryk.exe"
    if [ -n "$alias_src" ]; then
      cp "$alias_src" "$root/bin/orca.exe"
    else
      cp "$primary_src" "$root/bin/orca.exe"
    fi
  else
    if [ -f "$prefix/bin/ryk" ]; then
      primary_src="$prefix/bin/ryk"
    elif [ -f "$prefix/bin/$bin_name" ]; then
      primary_src="$prefix/bin/$bin_name"
    elif [ -f "$prefix/bin/orca" ]; then
      primary_src="$prefix/bin/orca"
    fi
    if [ -f "$prefix/bin/orca" ]; then
      alias_src="$prefix/bin/orca"
    fi
    [ -n "$primary_src" ] || {
      printf 'missing ryk/orca binary in %s\n' "$prefix/bin" >&2
      exit 1
    }
    cp "$primary_src" "$root/bin/ryk"
    chmod 0755 "$root/bin/ryk"
    if [ -n "$alias_src" ]; then
      cp "$alias_src" "$root/bin/orca"
    else
      cp "$primary_src" "$root/bin/orca"
    fi
    chmod 0755 "$root/bin/orca"
  fi
}

build_cli_target() {
  os="$1"
  arch="$2"
  zig_target="$3"
  ext="$4"
  bin_name="$5"

  artifact="ryk-v${VERSION}-${os}-${arch}.${ext}"
  work="${DIST_DIR}/work/cli-${os}-${arch}"
  prefix="${work}/prefix"
  root="${work}/ryk-v${VERSION}-${os}-${arch}"

  rm -rf "$work"
  mkdir -p "$prefix" "$root/bin"

  staged_cli="${CLI_ARTIFACT_DIR}/${os}-${arch}/${bin_name}"
  if [ -n "$CLI_ARTIFACT_DIR" ] && [ -f "$staged_cli" ]; then
    mkdir -p "$prefix/bin"
    cp -p "$staged_cli" "$prefix/bin/$bin_name"
    # staged path may only ship primary; alias filled in install_primary_and_alias
  else
    "$(dirname "$0")/zig" build install-ryk \
      -Dtarget="$zig_target" \
      -Doptimize="$ZIG_OPTIMIZE" \
      -Dversion="$VERSION" \
      -Dcommit="$COMMIT" \
      -Dbuild-date="$BUILD_DATE" \
      --prefix "$prefix"
  fi

  copy_cli_payload "$root"
  write_release_readme "$root"
  install_primary_and_alias "$os" "$prefix" "$root" "$bin_name"
  # orca-daemon removed: Zig shell_engine evaluates in-process.
  find "$root" -name .DS_Store -delete

  if [ "$ext" = "zip" ]; then
    (cd "$work" && zip -qr "../../$artifact" "ryk-v${VERSION}-${os}-${arch}")
  else
    # COPYFILE_DISABLE=1 prevents macOS bsdtar from embedding extended attributes
    # (LIBARCHIVE.xattr.com.apple.provenance etc.) as PAX headers. This eliminates
    # the 80–120+ "Ignoring unknown extended header keyword" lines on Linux extracts
    # of mac-built release tarballs (Ubuntu 24.04 + Alpine curl|sh flow).
    COPYFILE_DISABLE=1 tar -C "$work" -czf "${DIST_DIR}/$artifact" "ryk-v${VERSION}-${os}-${arch}"
  fi
  printf 'Built %s\n' "${DIST_DIR}/$artifact"

  # Cheap dual-publish: identical orca-v* alias for one major (installers / old taps).
  if [ "$DUAL_PUBLISH_ORCA" = "1" ]; then
    alias_artifact="orca-v${VERSION}-${os}-${arch}.${ext}"
    cp -p "${DIST_DIR}/$artifact" "${DIST_DIR}/$alias_artifact"
    printf 'Built %s (compat dual-publish of ryk archive)\n' "${DIST_DIR}/$alias_artifact"
  fi
}

write_release_manifest() {
  output="${DIST_DIR}/release-manifest.json"
  artifact_entries=""
  first=1
  for file in "${DIST_DIR}"/ryk-v* "${DIST_DIR}"/orca-v*; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    hash="$(awk -v name="$name" '$2 == name {print $1}' "${DIST_DIR}/checksums.txt")"
    [ -n "$hash" ] || {
      printf 'missing checksum for %s\n' "$name" >&2
      exit 1
    }
    if [ "$first" = "1" ]; then
      first=0
    else
      artifact_entries="${artifact_entries},"
    fi
    artifact_entries="${artifact_entries}
    {\"name\":\"${name}\",\"sha256\":\"${hash}\"}"
  done

  products_json="[\"ryk\", \"orca\", \"core\"]"
  runtime_assets_json="[\"schemas\", \"policies\", \"fixtures\", \"examples\", \"integrations\", \"packaging\"]"
  schemas_json="[\"schemas/policy-v1.json\", \"schemas/event-v1.json\", \"schemas/mcp-manifest-v1.json\"]"
  fixtures_json="[\"fixtures/shell-abuse/curl-pipe-sh\", \"examples/mcp\", \"examples/network\", \"examples/policies\"]"
  docs_json="[\"README.md\", \"docs/install.md\", \"README-release.md\"]"
  target_platforms="$(target_platforms_json)"
  safety_summary="ryk is a local CLI/runtime firewall (orca is a compat alias); Edge artifacts are not included in CLI-only releases."

  cat >"$output" <<EOF
{
  "release_version": "${VERSION}",
  "commit": "${COMMIT}",
  "build_date": "${BUILD_DATE}",
  "release_channel": "stable",
  "products_included": ${products_json},
  "artifacts": [${artifact_entries}
  ],
  "checksums": "checksums.txt",
  "target_platforms": ${target_platforms},
  "required_runtime_assets": ${runtime_assets_json},
  "schemas_included": ${schemas_json},
  "fixtures_included": ${fixtures_json},
  "docs_included": ${docs_json},
  "safety_boundary_summary": "${safety_summary}",
  "known_limitations_path": null,
  "generated_by": "scripts/build-release.sh",
  "signing_status": "${SIGNING_STATUS}",
  "sbom_status": "hook-only inventory generated at sbom.json",
  "primary_cli": "ryk",
  "legacy_cli_alias": "orca"
}
EOF
  printf 'Wrote %s\n' "$output"
}

cleanup_attempts=0
while [ -d "$DIST_DIR" ] && [ "$cleanup_attempts" -lt 5 ]; do
  find "$DIST_DIR" -name .DS_Store -type f -delete 2>/dev/null || true
  rm -rf "$DIST_DIR" 2>/dev/null || true
  cleanup_attempts=$((cleanup_attempts + 1))
  [ ! -d "$DIST_DIR" ] || sleep 1
done
[ ! -d "$DIST_DIR" ] || {
  printf 'could not clean release directory: %s\n' "$DIST_DIR" >&2
  exit 1
}
mkdir -p "$DIST_DIR"

printf '%s\n' "$(selected_targets)" | while read -r os arch zig_target ext bin_name; do
  [ -n "${os:-}" ] || continue
  build_cli_target "$os" "$arch" "$zig_target" "$ext" "$bin_name"
done

if [ "${RYK_SIGNING_ENABLED:-${ORCA_SIGNING_ENABLED:-0}}" = "1" ]; then
  if [ -n "${RYK_SIGNING_COMMAND:-${ORCA_SIGNING_COMMAND:-}}" ]; then
    SIGNING_STATUS="signed"
    sh -c "${RYK_SIGNING_COMMAND:-$ORCA_SIGNING_COMMAND}" sh "$DIST_DIR"
  else
    printf 'Signing requested but RYK_SIGNING_COMMAND/ORCA_SIGNING_COMMAND is not set.\n' >&2
    exit 1
  fi
else
  SIGNING_STATUS="signing hook available; not configured"
  printf 'Signing skipped; set RYK_SIGNING_ENABLED=1 (or ORCA_SIGNING_ENABLED) and signing command in release environments.\n'
fi

./scripts/generate-checksums.sh "$DIST_DIR"
if [ "$RELEASE_PRODUCT" != "host" ]; then
  RYK_DIST_DIR="$DIST_DIR" ORCA_DIST_DIR="$DIST_DIR" ./scripts/render-package-manifests.sh
fi
ORCA_RELEASE_PRODUCT="$RELEASE_PRODUCT" RYK_RELEASE_PRODUCT="$RELEASE_PRODUCT" ./scripts/generate-sbom.sh "$DIST_DIR"

write_release_manifest
rm -rf "$DIST_DIR/work"
rm -rf "$DIST_DIR/daemon-artifacts"
