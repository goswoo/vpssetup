#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(sed -n '1p' "$ROOT_DIR/version")"
ARCHIVE="$DIST_DIR/vpssetup.tar.gz"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$DIST_DIR" "$STAGING/vpssetup"
cp -a \
    "$ROOT_DIR/vpssetup.sh" \
    "$ROOT_DIR/install.sh" \
    "$ROOT_DIR/version" \
    "$ROOT_DIR/README.md" \
    "$ROOT_DIR/LICENSE" \
    "$ROOT_DIR/lib" \
    "$STAGING/vpssetup/"

find "$STAGING/vpssetup" -type f -name '*.sh' -exec bash -n {} \;
tar -czf "$ARCHIVE" -C "$STAGING" vpssetup
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"
printf 'Built VPSSetup %s:\n  %s\n  %s\n' "$VERSION" "$ARCHIVE" "$ARCHIVE.sha256"

