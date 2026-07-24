#!/usr/bin/env sh
set -eu

ARTIFACT_DIR="${1:-dist}"
OUTPUT="${ARTIFACT_DIR}/checksums.txt"

[ -d "$ARTIFACT_DIR" ] || {
  printf 'generate-checksums: artifact directory not found: %s\n' "$ARTIFACT_DIR" >&2
  exit 1
}

tmp="${OUTPUT}.tmp"
: > "$tmp"

# Phase 5a: primary ryk-v* plus legacy orca-v* (dual-publish). Also Windows .zip.
hash_artifact() {
  file="$1"
  [ -f "$file" ] || return 0
  name="$(basename "$file")"
  case "$name" in
    *.tar.gz|*.zip)
      if command -v sha256sum >/dev/null 2>&1; then
        hash="$(sha256sum "$file" | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        hash="$(shasum -a 256 "$file" | awk '{print $1}')"
      else
        printf 'generate-checksums: sha256sum or shasum is required\n' >&2
        rm -f "$tmp"
        exit 1
      fi
      printf '%s  %s\n' "$hash" "$name" >> "$tmp"
      ;;
  esac
}

# Use nullglob-friendly loop: expand both brand prefixes; skip missing globs.
for pattern in "$ARTIFACT_DIR"/ryk-v* "$ARTIFACT_DIR"/orca-v*; do
  # When a glob matches nothing, the literal pattern remains; skip non-files.
  hash_artifact "$pattern"
done

[ -s "$tmp" ] || {
  printf 'generate-checksums: no release artifacts found in %s\n' "$ARTIFACT_DIR" >&2
  rm -f "$tmp"
  exit 1
}

# Stable order for reproducible checksums.txt
if command -v sort >/dev/null 2>&1; then
  sort -k2 "$tmp" -o "$tmp"
fi

mv "$tmp" "$OUTPUT"
printf 'Wrote %s\n' "$OUTPUT"
printf 'Verify with: cd %s && sha256sum -c checksums.txt\n' "$ARTIFACT_DIR"
