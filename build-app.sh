#!/bin/bash
# Assembles PhotonMigrate.app from the three components.
#
# The app bundle is what makes this installable by anyone else: both helper
# binaries live in Contents/Resources and find each other relatively, so
# nothing depends on a particular checkout location.
#
# Note this produces an *ad-hoc signed* bundle, which runs on this machine
# but will be blocked by Gatekeeper elsewhere. Distributing it to others
# needs a Developer ID and notarisation -- see README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$ROOT/build/PhotonMigrate.app}"

echo "==> Building components"
(cd "$ROOT/go-uploader" && go build -o "$ROOT/build/photon-migrate" .)
(cd "$ROOT/swift-helper" && swift build -c release)
(cd "$ROOT/menubar-app" && swift build -c release)

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/menubar-app/.build/release/PhotonMigrateBar" "$APP/Contents/MacOS/PhotonMigrate"
cp "$ROOT/build/photon-migrate" "$APP/Contents/Resources/photon-migrate"
cp "$ROOT/swift-helper/.build/release/photos-helper" "$APP/Contents/Resources/photos-helper"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# NSPhotoLibraryUsageDescription must be on the bundle the user sees in the
# permission prompt, not just on the helper that makes the request.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.dustinleblanc.photon-migrate</string>
    <key>CFBundleName</key>
    <string>Photon Migrate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>PhotonMigrate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Photon Migrate reads your Photos library to copy it to Proton Drive.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo
echo "Built $APP"
echo "Run it with: open '$APP'"
