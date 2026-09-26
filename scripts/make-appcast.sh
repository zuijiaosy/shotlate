#!/bin/bash
# Signs a DMG for Sparkle and prints an appcast with that one item; Sparkle only needs the newest release.
#   scripts/make-appcast.sh <version> <build number> <dmg> <download url> [release notes .md] > appcast.xml
#
# The EdDSA private key comes from SPARKLE_ED_PRIVATE_KEY, else ~/.shotlate-signing/sparkle_ed25519_private.txt.
# Its public half is SUPublicEDKey in Resources/Info.plist; the two must match or clients reject the update.
# sign_update ships inside the Sparkle package that `swift build` already fetched.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; BUILD="$2"; DMG="$3"; URL="$4"; NOTES="${5:-}"

SIGN_UPDATE="$(find .build/artifacts -path '*/bin/sign_update' -type f | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found; run swift build first" >&2; exit 1; }
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  ATTRS="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
  ATTRS="$("$SIGN_UPDATE" --ed-key-file "$HOME/.shotlate-signing/sparkle_ed25519_private.txt" "$DMG")"
fi
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
DESCRIPTION=""
if [ -n "$NOTES" ]; then
  DESCRIPTION="      <description sparkle:descriptionFormat=\"markdown\"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")]]></description>"
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Shotlate</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
$DESCRIPTION
      <enclosure url="$URL" type="application/octet-stream" $ATTRS/>
    </item>
  </channel>
</rss>
XML
