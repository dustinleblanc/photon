#!/bin/bash
# Builds all three components for a single architecture.
#
# Used by the release GitHub Actions workflow, which runs this on both an
# arm64 and an x86_64 runner, then merges the per-arch binaries into a
# universal .app. On a labels/architecture mismatch (e.g. GOARCH=arm64 on
# an Intel runner) `file` will report only the host arch, not the requested
# one, so this fails fast with a clear message.
#
# Usage: build-arch.sh <arm64|x86_64> [output-dir]
set -euo pipefail

ARCH="${1:?usage: build-arch.sh <arm64|x86_64> [output-dir]}"
OUT="${2:-build}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$ARCH" in
  arm64)  GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) echo "unknown arch: $ARCH (want arm64 or x86_64)" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/$OUT"

echo "==> Building Go uploader ($ARCH)"
(cd "$ROOT/go-uploader" && GOOS=darwin GOARCH="$GOARCH" go build -o "$ROOT/$OUT/photon-migrate-$ARCH" .)

echo "==> Building photos-helper ($ARCH)"
(cd "$ROOT/swift-helper" && swift build -c release)
cp "$ROOT/swift-helper/.build/release/photos-helper" "$ROOT/$OUT/photos-helper-$ARCH"

echo "==> Building photon-migrate bar ($ARCH)"
(cd "$ROOT/menubar-app" && swift build -c release)
cp "$ROOT/menubar-app/.build/release/PhotonMigrateBar" "$ROOT/$OUT/PhotonMigrateBar-$ARCH"

echo
echo "Built for $ARCH:"
ls -l "$ROOT"/$OUT/*-"$ARCH"
file "$ROOT"/$OUT/*-"$ARCH"
