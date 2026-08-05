#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${RYK_DIST_DIR:-dist}"
VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

fail() {
  printf 'docker-install-layout-smoke: %s\n' "$1" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) fail "unsupported Docker host architecture" ;;
esac

command -v docker >/dev/null 2>&1 || fail "docker is required"
docker info >/dev/null 2>&1 || fail "docker daemon is unavailable"

# Phase 5a: prefer primary ryk-v* archive; accept dual-publish ryk-v* filename.
artifact=""
for prefix in ryk orca; do
  candidate="${prefix}-v${VERSION}-linux-${arch}.tar.gz"
  if [[ -f "${DIST_DIR}/${candidate}" ]]; then
    artifact="${candidate}"
    break
  fi
done
[[ -n "${artifact}" ]] || fail "missing Linux artifact: ${DIST_DIR}/ryk-v${VERSION}-linux-${arch}.tar.gz"
artifact_path="${DIST_DIR}/${artifact}"
checksums="${DIST_DIR}/checksums.txt"
[[ -f "${checksums}" ]] || fail "missing checksums file: ${checksums}"

expected="$(awk -v name="${artifact}" '$2 == name { print $1 }' "${checksums}")"
[[ -n "${expected}" ]] || fail "checksums file has no entry for ${artifact}"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${artifact_path}" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "${artifact_path}" | awk '{ print $1 }')"
fi
[[ "${actual}" == "${expected}" ]] || fail "artifact checksum mismatch"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/ryk-docker-smoke.XXXXXX")"
image="ryk-install-layout-smoke:${VERSION}-${arch}-$$"
cleanup() {
  docker image rm -f "${image}" >/dev/null 2>&1 || true
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM

tar -xzf "${artifact_path}" -C "${tmp_root}"
# Dual-publish ryk-v* filenames still unpack to ryk-v… root (byte copy of primary).
stage_root=""
for prefix in ryk orca; do
  if [[ -d "${tmp_root}/${prefix}-v${VERSION}-linux-${arch}" ]]; then
    stage_root="${tmp_root}/${prefix}-v${VERSION}-linux-${arch}"
    break
  fi
done
[[ -n "${stage_root}" ]] || fail "archive root not found after extract"
mv "${stage_root}" "${tmp_root}/orca"
cp "${REPO_ROOT}/packaging/docker/Dockerfile" "${tmp_root}/Dockerfile"

docker build --pull=false -t "${image}" "${tmp_root}" >/dev/null

version_output="$(docker run --rm "${image}" version)"
[[ "${version_output}" == *"ryk"* || "${version_output}" == *"ryk"* ]] || fail "container version output is missing the product name"
[[ "${version_output}" == *"${VERSION}"* ]] || fail "container version output is missing ${VERSION}"
run_output="$(docker run --rm --entrypoint sh "${image}" -ec '
  mkdir -p "$HOME/workspace"
  cd "$HOME/workspace"
  # Prefer primary binary; fall back to ryk alias.
  CLI=ryk
  command -v ryk >/dev/null 2>&1 || CLI=orca
  "$CLI" init --preset generic-agent >/dev/null
  "$CLI" policy check .ryk/policy.yaml >/dev/null
  "$CLI" run -- echo docker-smoke-ok
')"
[[ "${run_output}" == *"docker-smoke-ok"* ]] || fail "container could not protect and run a command"

printf '[docker-install-layout-smoke] passed for linux-%s\n' "${arch}"
