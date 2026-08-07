#!/usr/bin/env sh
set -eu

# Builds the checksum-covered ryk release archive set.
RYK_RELEASE_PRODUCT=cli exec ./scripts/build-release.sh "$@"
