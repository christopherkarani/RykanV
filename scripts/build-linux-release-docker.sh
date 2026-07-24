#!/usr/bin/env bash
# Build Linux ryk CLI binaries (amd64 + arm64) via Docker buildx and stage them
# for scripts/build-release.sh (ORCA_CLI_ARTIFACT_DIR / RYK_CLI_ARTIFACT_DIR).
#
# Layout written:
#   $OUT_DIR/linux-amd64/ryk
#   $OUT_DIR/linux-amd64/orca   (compat alias)
#   $OUT_DIR/linux-arm64/ryk
#   $OUT_DIR/linux-arm64/orca
#
# OUT_DIR must NOT live under dist/ if you then run build-release.sh — that script
# wipes dist/. Prefer .release-cli-bins/ (cut-release default).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${1:-${ORCA_LINUX_ARTIFACT_DIR:-${RYK_LINUX_ARTIFACT_DIR:-${REPO_ROOT}/.release-cli-bins}}}"
VERSION="${RYK_VERSION:-${ORCA_VERSION:-$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")}}"
COMMIT="${RYK_COMMIT:-${ORCA_COMMIT:-$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD)}}"
BUILD_DATE="${RYK_BUILD_DATE:-${ORCA_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}}"

command -v docker >/dev/null 2>&1 || {
  echo "build-linux-release-docker: docker is required" >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "build-linux-release-docker: docker daemon is unavailable" >&2
  exit 1
}

# Each buildx local export replaces the dest tree; merge per-arch into OUT_DIR.
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ryk-linux-docker.XXXXXX")"
cleanup() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT INT TERM

for arch in amd64 arm64; do
  echo "Building linux-${arch} ryk binaries with Docker"
  arch_out="${TMP_ROOT}/linux-${arch}"
  mkdir -p "${arch_out}"
  docker buildx build \
    --platform "linux/${arch}" \
    --build-arg "ORCA_VERSION=${VERSION}" \
    --build-arg "ORCA_COMMIT=${COMMIT}" \
    --build-arg "ORCA_BUILD_DATE=${BUILD_DATE}" \
    --build-arg "RYK_VERSION=${VERSION}" \
    --build-arg "RYK_COMMIT=${COMMIT}" \
    --build-arg "RYK_BUILD_DATE=${BUILD_DATE}" \
    --file "${REPO_ROOT}/packaging/docker/Dockerfile.release" \
    --output "type=local,dest=${arch_out}" \
    "${REPO_ROOT}"

  # Image root is /out/linux-$TARGETARCH → local export may nest as linux-$arch/...
  staged=""
  if [[ -x "${arch_out}/linux-${arch}/ryk" ]]; then
    staged="${arch_out}/linux-${arch}"
  elif [[ -x "${arch_out}/ryk" ]]; then
    staged="${arch_out}"
  elif [[ -x "${arch_out}/linux-${arch}/orca" ]]; then
    staged="${arch_out}/linux-${arch}"
  else
    echo "build-linux-release-docker: could not find ryk/orca under ${arch_out}" >&2
    find "${arch_out}" -type f 2>/dev/null | head -40 >&2 || true
    exit 1
  fi

  mkdir -p "${OUT_DIR}/linux-${arch}"
  if [[ -x "${staged}/ryk" ]]; then
    cp -p "${staged}/ryk" "${OUT_DIR}/linux-${arch}/ryk"
  elif [[ -x "${staged}/orca" ]]; then
    cp -p "${staged}/orca" "${OUT_DIR}/linux-${arch}/ryk"
  else
    echo "build-linux-release-docker: missing primary binary in ${staged}" >&2
    exit 1
  fi
  if [[ -x "${staged}/orca" ]]; then
    cp -p "${staged}/orca" "${OUT_DIR}/linux-${arch}/orca"
  else
    cp -p "${OUT_DIR}/linux-${arch}/ryk" "${OUT_DIR}/linux-${arch}/orca"
  fi
  chmod 0755 "${OUT_DIR}/linux-${arch}/ryk" "${OUT_DIR}/linux-${arch}/orca"

  if [[ -e "${OUT_DIR}/linux-${arch}/orca-daemon" ]]; then
    echo "build-linux-release-docker: unexpected orca-daemon under ${OUT_DIR}/linux-${arch}" >&2
    exit 1
  fi
  file "${OUT_DIR}/linux-${arch}/ryk"
done

echo "Docker-built Linux release binaries staged in ${OUT_DIR}"
