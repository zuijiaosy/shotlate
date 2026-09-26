#!/bin/bash
# End-to-end check of Sparkle updates, from a local appcast:
#   1. build 100 finds build 101, downloads it and installs it on quit;
#   2. build 101 refuses a build 102 whose DMG is signed with a different EdDSA key.
#   scripts/test-update.sh [work dir]      (after scripts/build-app.sh)
#   INSTALL_DIR=/Applications/ShotlateUpdateTest scripts/test-update.sh   installs the test copy there instead,
#                                          to see that macOS lets it replace itself under /Applications
#
# The copies use their own bundle ID (app.shotlate.UpdateTest), so the real app's settings and
# permissions are left alone. They still ask for Screen Recording at launch; that prompt can be ignored.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
[ -d build/Shotlate.app ] || { echo "build/Shotlate.app not found; run scripts/build-app.sh first" >&2; exit 1; }

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
BUNDLE_ID=app.shotlate.UpdateTest
PORT=8765
FEED="http://127.0.0.1:$PORT"
SERVE="$WORK/serve"
INSTALL_DIR="${INSTALL_DIR:-$WORK/installed}"
INSTALLED="$INSTALL_DIR/Shotlate.app"
# Never touch a real Shotlate.app: only a copy this script installed may be replaced.
if [ -e "$INSTALLED" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null)" != "$BUNDLE_ID" ]; then
  echo "$INSTALLED exists and is not a test copy; pick another INSTALL_DIR" >&2
  exit 1
fi
rm -rf "$SERVE" "$INSTALLED" "$WORK/variants"
mkdir -p "$SERVE" "$INSTALL_DIR" "$WORK/variants"

quit_app() {
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in $(seq 20); do pgrep -f "$INSTALLED/Contents/MacOS/Shotlate" >/dev/null || return 0; sleep 0.5; done
  pkill -f "$INSTALLED/Contents/MacOS/Shotlate" || true
}
cleanup() {
  quit_app
  if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; fi
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [ "$INSTALL_DIR" != "$WORK/installed" ]; then
    rm -rf "$INSTALLED"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# A copy of build/Shotlate.app with its own build number, pointed at the local feed.
variant() {
  local build="$1" app="$WORK/variants/$1/Shotlate.app"
  mkdir -p "$(dirname "$app")"
  ditto build/Shotlate.app "$app"
  local plist="$app/Contents/Info.plist" pb=/usr/libexec/PlistBuddy
  $pb -c "Set :CFBundleIdentifier $BUNDLE_ID" "$plist"
  $pb -c "Set :CFBundleVersion $build" "$plist"
  $pb -c "Set :CFBundleShortVersionString 0.0.$build" "$plist"
  $pb -c "Set :SUFeedURL $FEED/appcast.xml" "$plist"
  $pb -c "Set :SUScheduledCheckInterval 3600" "$plist"
  # Plain http to 127.0.0.1 needs an ATS exception; only these test copies get it.
  $pb -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
  scripts/sign-app.sh "$app" 2>&1 | { grep -v -e "replacing existing signature" -e "^Signed " >&2 || true; }
  echo "$app"
}

# Packs a variant into the served folder and writes the appcast for it.
publish() {
  local build="$1" app="$2"
  local stage="$WORK/variants/$build/dmg"
  mkdir -p "$stage" && ditto "$app" "$stage/Shotlate.app"
  hdiutil create -volname Shotlate -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$SERVE/Shotlate-$build.dmg" >/dev/null 2>&1
  scripts/make-appcast.sh "0.0.$build" "$build" "$SERVE/Shotlate-$build.dmg" "$FEED/Shotlate-$build.dmg" > "$SERVE/appcast.xml"
}

installed_build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist"; }

# Launches the installed copy with a check due right away and automatic install on quit,
# waits for Sparkle to have the update (or to give up), then quits so it can install.
run_check() {
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults write "$BUNDLE_ID" SUHasLaunchedBefore -bool true
  defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool true
  defaults write "$BUNDLE_ID" SUAutomaticallyUpdate -bool true
  defaults write "$BUNDLE_ID" SULastCheckTime -date "2001-01-01 00:00:00 +0000"
  local since
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  open -n "$INSTALLED"
  sleep "${WAIT_SECONDS:-25}"
  quit_app
  sleep 8   # Autoupdate replaces the bundle after the app exits
  log show --start "$since" --style compact \
    --predicate 'process == "Autoupdate" OR process == "Shotlate" AND (subsystem BEGINSWITH "org.sparkle-project" OR eventMessage CONTAINS[c] "sparkle")' \
    2>/dev/null | tail -25 > "$WORK/log-$1.txt" || true
}

(cd "$SERVE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1

FAILED=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; FAILED=1; }

echo "== build 100 → 101"
OLD="$(variant 100)"
NEW="$(variant 101)"
ditto "$OLD" "$INSTALLED"
publish 101 "$NEW"
run_check update
if [ "$(installed_build)" = 101 ]; then ok "installed build 100 was replaced by 101"; else bad "still build $(installed_build); see $WORK/log-update.txt"; fi
codesign --verify --strict "$INSTALLED" && ok "the installed update passes codesign --verify" || bad "codesign --verify"
if xattr "$INSTALLED" | grep -q com.apple.quarantine; then bad "the update is quarantined"; else ok "the update is not quarantined"; fi

echo "== build 101 → 102 signed with another EdDSA key"
BAD="$(variant 102)"
OTHER_KEY="$WORK/other-ed25519.txt"
swift - "$OTHER_KEY" <<'SWIFT'
import CryptoKit
import Foundation
try! Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
    .write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
SWIFT
SPARKLE_ED_PRIVATE_KEY="$(cat "$OTHER_KEY")" publish 102 "$BAD"
run_check reject
if [ "$(installed_build)" = 101 ]; then ok "the wrongly signed build 102 was refused"; else bad "build $(installed_build) got installed"; fi

echo "logs: $WORK/log-update.txt, $WORK/log-reject.txt"
[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
