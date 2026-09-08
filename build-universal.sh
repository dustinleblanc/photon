#!/bin/bash
# Merges per-architecture binaries (arm64 + x86_64) into a universal .app
# and a lipo'd standalone Go CLI binary.
#
# Run after the two build legs have produced the per-arch components. Expects
# a directory layout like:
#
#   build/arm64/{photon-migrate-arm64,photos-helper-arm64,PhotonMigrateBar-arm64}
#   build/x86_64/{photon-migrate-x86_64,photos-helper-x86_64,PhotonMigrateBar-x86_64}
#
# Outputs:
#   build/dist/PhotonMigrate.app        universal (fat) app bundle, ad-hoc signed
#   build/dist/PhotonMigrate.app.tar.gz tarball of the above
#   build/dist/photon-migrate           universal standalone CLI binary
#   build/dist/photos-helper            universal standalone helper binary
#
# Usage: build-universal.sh [artifact-root]
set -euo pipefail

ROOT="${1:-.}"
IN="$ROOT/build"
OUT="$ROOT/build/dist"
VERSION="${PHOTON_MIGRATE_VERSION:-0.1.0}"

mkdir -p "$OUT/PhotonMigrate.app/Contents/MacOS" "$OUT/PhotonMigrate.app/Contents/Resources"

echo "==> Creating universal binaries with lipo"
lipo -create \
  "$IN/arm64/photon-migrate-arm64" \
  "$IN/x86_64/photon-migrate-x86_64" \
  -output "$OUT/photon-migrate"

lipo -create \
  "$IN/arm64/photos-helper-arm64" \
  "$IN/x86_64/photos-helper-x86_64" \
  -output "$OUT/photos-helper"

lipo -create \
  "$IN/arm64/PhotonMigrateBar-arm64" \
  "$IN/x86_64/PhotonMigrateBar-x86_64" \
  -output "$OUT/PhotonMigrate.app/Contents/MacOS/PhotonMigrate"

cp "$OUT/photon-migrate" "$OUT/PhotonMigrate.app/Contents/Resources/photon-migrate"
cp "$OUT/photos-helper"  "$OUT/PhotonMigrate.app/Contents/Resources/photos-helper"

echo "==> Writing Info.plist"
cat > "$OUT/PhotonMigrate.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.dustinleblanc.photon-migrate</string>
    <key>CFBundleName</key>
    <string>Photon Migrate</string>
    <key>CFBundleExecutable</key>
    <string>PhotonMigrate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Photon Migrate reads your Photos library to copy it to Proton Drive.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$OUT/PhotonMigrate.app"
codesign --verify --deep --strict "$OUT/PhotonMigrate.app"

echo "==> Archiving"
tar -C "$OUT" -czf "$OUT/PhotonMigrate.app.tar.gz" PhotonMigrate.app

echo
echo "Distributables in $OUT:"
ls -lh "$OUT"
file "$OUT/PhotonMigrate.app/Contents/MacOS/PhotonMigrate"
