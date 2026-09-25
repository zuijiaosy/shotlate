#!/bin/bash
# Builds Snap.app into ./build.
#   scripts/build-app.sh            release build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Screen Recording permission is tied to the code signature. With ad-hoc signing (the default
# when no identity is found) macOS may ask for the permission again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Snap"

APP=build/Snap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
codesign --force --sign "${IDENTITY:--}" --identifier app.snap.Snap "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
