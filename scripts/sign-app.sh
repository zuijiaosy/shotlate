#!/bin/bash
# Signs a built Shotlate.app, inside out: Sparkle's helpers, Sparkle.framework, then the app.
#   scripts/sign-app.sh build/Shotlate.app
#
# Every build, local or CI, is signed with the same self-signed "Shotlate Release" certificate, so the
# Screen Recording permission survives updates and Sparkle accepts the new build as coming from us.
# The certificate is read from SIGNING_P12 (default ~/.shotlate-signing/shotlate.p12; password in
# SIGNING_P12_PASSWORD or p12-password.txt next to it) through a throwaway keychain, so the login keychain
# is never touched. SIGN_IDENTITY="…" signs with an identity already in your keychains instead.
# Without either it falls back to ad-hoc: such a build can't auto-update or keep its permissions.
set -euo pipefail
APP="${1:?usage: scripts/sign-app.sh path/to/Shotlate.app}"
FW="$APP/Contents/Frameworks/Sparkle.framework"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

KEYCHAIN_FLAGS=()
IDENTITY="${SIGN_IDENTITY:-}"
P12="${SIGNING_P12:-$HOME/.shotlate-signing/shotlate.p12}"
if [ -z "$IDENTITY" ] && [ -f "$P12" ]; then
  P12_PASSWORD="${SIGNING_P12_PASSWORD:-$(cat "$(dirname "$P12")/p12-password.txt" 2>/dev/null || true)}"
  KC_DIR="$(mktemp -d)"
  KC="$KC_DIR/signing.keychain-db"
  KC_PASSWORD="$(uuidgen)"
  trap 'security delete-keychain "$KC" 2>/dev/null; rm -rf "$KC_DIR"' EXIT
  security create-keychain -p "$KC_PASSWORD" "$KC"
  security unlock-keychain -p "$KC_PASSWORD" "$KC"
  security import "$P12" -k "$KC" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASSWORD" "$KC" >/dev/null
  IDENTITY="Shotlate Release"
  KEYCHAIN_FLAGS=(--keychain "$KC")
fi

sign() {
  codesign --force --sign "${IDENTITY:--}" ${KEYCHAIN_FLAGS[@]+"${KEYCHAIN_FLAGS[@]}"} "$@"
}
if [ -d "$FW" ]; then
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
fi
sign --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
if [ -z "$IDENTITY" ]; then
  echo "warning: signed ad-hoc, not with the shared Shotlate Release certificate; this build can't auto-update" >&2
fi
echo "Signed $APP (with: ${IDENTITY:-ad-hoc})"
