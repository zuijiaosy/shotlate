#!/bin/bash
# Compiles Resources/AppIcon.icon (Icon Composer format: icon.json + SVG layers) into Resources/Assets.car,
# which macOS 26+ renders with Liquid Glass and its clear / tinted looks, plus Resources/AppIcon.icns for
# macOS 14 / 15. Needs Xcode for actool; both outputs are committed, so building the app needs only the CLT.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODE="${XCODE:-/Applications/Xcode.app}"
ACTOOL="$XCODE/Contents/Developer/usr/bin/actool"
[ -x "$ACTOOL" ] || { echo "actool not found; set XCODE=/path/to/Xcode.app" >&2; exit 1; }

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$ACTOOL" "$PWD/Resources/AppIcon.icon" --compile "$OUT" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$OUT/partial.plist" >/dev/null
cp "$OUT/Assets.car" Resources/Assets.car
cp "$OUT/AppIcon.icns" Resources/AppIcon.icns
echo "Wrote Resources/Assets.car and Resources/AppIcon.icns"
