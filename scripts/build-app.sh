#!/bin/bash
# Builds Snap.app into ./build.
#   scripts/build-app.sh            release build for this Mac's architecture
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#   ARCHS="arm64 x86_64" scripts/build-app.sh      universal binary
#   VERSION=0.2.3 BUILD_NUMBER=42 scripts/build-app.sh   overrides the versions in Info.plist
#
# Screen Recording permission is tied to the code signature. With ad-hoc signing (the default
# when no identity is found) macOS may ask for the permission again after every rebuild.
# A "Developer ID Application" identity is signed with the hardened runtime, as notarization requires.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP=build/Snap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -n "${ARCHS:-}" ]; then
  SLICES=()
  for arch in $ARCHS; do
    swift build -c "$CONFIG" --arch "$arch"
    SLICES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Snap")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Snap"
else
  swift build -c "$CONFIG"
  cp "$(swift build -c "$CONFIG" --show-bin-path)/Snap" "$APP/Contents/MacOS/Snap"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
FLAGS=()
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  FLAGS=(--options runtime --timestamp)
fi
codesign --force --sign "${IDENTITY:--}" ${FLAGS[@]+"${FLAGS[@]}"} --identifier app.snap.Snap "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
