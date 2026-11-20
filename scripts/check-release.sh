#!/bin/bash
# Checks what only a release build must have (`make check-app CONFIG=Release`): libmtp and
# libusb inside the bundle and nothing loaded from Homebrew; and, for a build signed by the team,
# the real Sparkle key, the HTTPS feed, and the hardened runtime, a Developer ID signature and a
# secure timestamp on every executable. An ad hoc build (scripts/update-dry-run.sh) has a test
# key and a local feed, and no Developer ID signature.
#
# Usage: scripts/check-release.sh <Ferry.app> <team|adhoc>
set -euo pipefail

app="$1"
sign="$2"
fail() {
  echo "error: $*" >&2
  exit 1
}

for lib in libmtp.9.dylib libusb-1.0.0.dylib; do
  [ -f "$app/Contents/Frameworks/$lib" ] || fail "no $lib in $app/Contents/Frameworks"
done
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  if otool -L "$file" | tail -n +2 | grep -E '/opt/homebrew/|/usr/local/' >&2; then
    fail "$file links a library outside the bundle and the system"
  fi
done < <(find "$app" -type f -print0)
echo "release build carries libmtp and libusb and links nothing from Homebrew"

[ "$sign" = adhoc ] && exit 0

info="$app/Contents/Info.plist"
key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")"
[ "$key" != FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER ] \
  || fail "SUPublicEDKey is still the placeholder: set FERRY_SPARKLE_PUBLIC_KEY in project.yml" \
    "to the public key scripts/release-secrets.sh prints"
[ "$(printf '%s' "$key" | base64 -D 2> /dev/null | wc -c | tr -d ' ')" = 32 ] \
  || fail "SUPublicEDKey is not an Ed25519 public key (32 bytes, base64): $key"
feed="https://github.com/krisarmstrong/ferry/releases/latest/download/appcast.xml"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")" = "$feed" ] \
  || fail "SUFeedURL is not $feed"
echo "release build carries the Sparkle key and its HTTPS feed"

for code in "$app" "$app/Contents/MacOS/FerryAgent" "$app/Contents/PlugIns/FerryProvider.appex" \
  "$app/Contents/PlugIns/FerrySync.appex"; do
  details="$(codesign -dv --verbose=2 "$code" 2>&1)"
  grep -q '^CodeDirectory.*flags=.*runtime' <<< "$details" \
    || fail "$code is not signed with the hardened runtime"
  grep -q '^Authority=Developer ID Application:' <<< "$details" \
    || fail "$code is not signed with a Developer ID Application certificate"
  grep -q '^Timestamp=' <<< "$details" || fail "$code has no secure timestamp"
done
codesign --verify --deep --strict "$app" || fail "$app does not verify"
echo "release build is signed with Developer ID, the hardened runtime and timestamps"
