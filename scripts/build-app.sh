#!/usr/bin/env bash
# Builds "CMStorm Lights.app" (universal: Apple silicon + Intel) into ./build.
#
# Environment:
#   VERSION            version string to stamp into Info.plist (default 1.0.0)
#   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CMStorm Lights"
EXECUTABLE="CMStormLights"
VERSION="${VERSION:-1.0.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/${APP_NAME}.app"

echo "==> Compiling (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Rendering icon"
if ! swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"; then
    echo "warning: icon generation failed; continuing without a custom icon" >&2
fi

echo "==> Signing (${IDENTITY})"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/$EXECUTABLE"

echo "==> Zipping"
rm -f build/CMStormLights.zip
ditto -c -k --keepParent "$APP" build/CMStormLights.zip

echo "Done: $APP"
