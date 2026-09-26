#!/bin/bash
# Builds Shotlate.app into ./build.
#   scripts/build-app.sh            release build for this Mac's architecture
#   ARCHS="arm64 x86_64" scripts/build-app.sh      universal binary
#   VERSION=0.2.3 BUILD_NUMBER=42 scripts/build-app.sh   overrides the versions in Info.plist
#
# Signing is done by scripts/sign-app.sh; see there for where the shared certificate comes from.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP=build/Shotlate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -n "${ARCHS:-}" ]; then
  SLICES=()
  for arch in $ARCHS; do
    swift build -c "$CONFIG" --arch "$arch"
    SLICES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Shotlate")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Shotlate"
else
  swift build -c "$CONFIG"
  cp "$(swift build -c "$CONFIG" --show-bin-path)/Shotlate" "$APP/Contents/MacOS/Shotlate"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Sparkle's binary target is already universal, so any slice's copy will do.
BIN_PATH="$(swift build -c "$CONFIG" ${ARCHS:+--arch "${ARCHS%% *}"} --show-bin-path)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$FW"
# The XPC services are only for sandboxed apps.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

scripts/sign-app.sh "$APP"
echo "Built $APP"
