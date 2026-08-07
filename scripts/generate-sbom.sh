#!/usr/bin/env sh
set -eu

ARTIFACT_DIR="${1:-dist}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${RYK_VERSION:-$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null || printf '1.2.9')}"
RELEASE_PRODUCT="${RYK_RELEASE_PRODUCT:-all}"
OUTPUT="${ARTIFACT_DIR}/sbom.json"

# SBOM inventory is emitted alongside checksum-verified release artifacts.
mkdir -p "$ARTIFACT_DIR"

# The release inventory covers the canonical ryk CLI and core library.
sbom_name="ryk-core"
sbom_format="ryk-core-release-inventory"
components='[
  {"name": "ryk", "type": "application", "language": "zig", "dependencies": []},
  {"name": "core", "type": "library", "language": "zig", "dependencies": []}
]'
build_targets='[
  "darwin-amd64",
  "darwin-arm64",
  "linux-amd64",
  "linux-arm64",
  "windows-amd64"
]'
runtime_assets='[
  "schemas",
  "policies",
  "examples",
  "integrations",
  "packaging"
]'
safety_boundary="ryk assets cover local CLI/runtime guardrails only; no hosted telemetry or cloud enforcement is included."

cat > "$OUTPUT" <<EOF
{
  "sbom_format": "$sbom_format",
  "name": "$sbom_name",
  "version": "$VERSION",
  "generator": "scripts/generate-sbom.sh",
  "status": "hook-only",
  "note": "This is a deterministic dependency, target, and runtime asset inventory. Replace it with CycloneDX or SPDX output in release environments when an SBOM tool is available; do not claim a complete third-party SBOM from this hook-only file.",
  "components": $components,
  "build_targets": $build_targets,
  "runtime_assets": $runtime_assets,
  "safety_boundary": "$safety_boundary"
}
EOF

printf 'Wrote %s\n' "$OUTPUT"
