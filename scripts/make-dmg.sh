#!/bin/bash
# Packs build/Shotlate.app into a drag-to-install disk image.
#   scripts/make-dmg.sh             build/Shotlate.dmg
#   scripts/make-dmg.sh 0.2.3       build/Shotlate-0.2.3.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/Shotlate.app ] || { echo "build/Shotlate.app not found; run scripts/build-app.sh first" >&2; exit 1; }
DMG="build/Shotlate${1:+-$1}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Shotlate.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Shotlate -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Wrote $DMG"
