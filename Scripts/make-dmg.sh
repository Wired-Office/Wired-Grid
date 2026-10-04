#!/bin/zsh
# Builds a universal Release build of Wired Grid and packages it as
# dist/Wired-Grid-<version>.dmg (app + Applications shortcut).
#
# Usage: Scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUILD_DIR="build/DMG"
APP="$BUILD_DIR/Build/Products/Release/Wired Grid.app"

xcodebuild -project WiredGrid.xcodeproj -scheme WiredGrid -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$BUILD_DIR" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Wired-Grid-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Wired Grid.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Wired Grid $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "$DMG"
