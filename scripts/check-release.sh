#!/bin/bash
# Checks what only a release build must have (`make check-app CONFIG=Release`):
# - libmtp and libusb inside the bundle, their LGPL texts and source offer, nothing from Homebrew;
# - no executable allowing a debugger to attach (get-task-allow), which notarization refuses;
# - for a build signed by the team: the real Sparkle key, the HTTPS feed, and on every
#   executable the hardened runtime, a Developer ID signature and a secure timestamp.
# An ad hoc build (CI, scripts/update-dry-run.sh) has a test key or none, a local feed or the
# real one, and no Developer ID signature.
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
licenses="$app/Contents/Resources/Licenses"
for text in "$licenses"/libusb-*-COPYING.txt "$licenses"/libmtp-*-COPYING.txt \
  "$licenses/README.txt"; do
  [ -s "$text" ] || fail "no $text"
done
echo "release build carries libmtp and libusb, their licences and where their source is"

executables=()
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' && executables+=("$file")
done < <(find "$app" -type f -print0)
for file in "${executables[@]}"; do
  if otool -L "$file" | tail -n +2 | grep -E '/opt/homebrew/|/usr/local/' >&2; then
    fail "$file links a library outside the bundle and the system"
  fi
  if codesign -d --entitlements - --xml "$file" 2> /dev/null | grep -q 'get-task-allow'; then
    fail "$file is signed with com.apple.security.get-task-allow"
  fi
done
echo "no executable (${#executables[@]}) links Homebrew or allows a debugger to attach"

[ "$sign" = adhoc ] && exit 0

info="$app/Contents/Info.plist"
key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")"
[ "$key" != FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER ] \
  || fail "SUPublicEDKey is still the placeholder: set FERRY_SPARKLE_PUBLIC_KEY in project.yml" \
    "to the public key scripts/release-secrets.sh prints"
[ "$(printf '%s' "$key" | base64 --decode 2> /dev/null | wc -c | tr -d ' ')" = 32 ] \
  || fail "SUPublicEDKey is not an Ed25519 public key (32 bytes, base64): $key"
feed="https://github.com/krisarmstrong/ferry/releases/latest/download/appcast.xml"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")" = "$feed" ] \
  || fail "SUFeedURL is not $feed"
echo "release build carries the Sparkle key and its HTTPS feed"

for file in "${executables[@]}"; do
  details="$(codesign -dv --verbose=2 "$file" 2>&1)"
  grep -q '^CodeDirectory.*flags=.*runtime' <<< "$details" \
    || fail "$file is not signed with the hardened runtime"
  grep -q '^Authority=Developer ID Application:' <<< "$details" \
    || fail "$file is not signed with a Developer ID Application certificate"
  grep -q '^Timestamp=' <<< "$details" || fail "$file has no secure timestamp"
done
codesign --verify --deep --strict "$app" || fail "$app does not verify"
echo "every executable is signed with Developer ID, the hardened runtime and a timestamp"
