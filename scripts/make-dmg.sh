#!/bin/bash
# Packs build/Snap.app into a drag-to-install disk image.
#   scripts/make-dmg.sh             build/Snap.dmg
#   scripts/make-dmg.sh 0.2.3       build/Snap-0.2.3.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/Snap.app ] || { echo "build/Snap.app not found; run scripts/build-app.sh first" >&2; exit 1; }
DMG="build/Snap${1:+-$1}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Snap.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Snap -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Wrote $DMG"
