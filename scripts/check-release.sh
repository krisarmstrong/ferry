#!/bin/bash
# Checks what only a release build must have (`make check-app CONFIG=Release`):
# - libmtp and libusb inside the bundle, their LGPL texts and source offer, Sparkle's MIT notice,
#   nothing from Homebrew;
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
  "$licenses/README.txt" "$licenses/Sparkle-LICENSE.txt"; do
  [ -s "$text" ] || fail "no $text"
done
grep -q "Andy Matuschak" "$licenses/Sparkle-LICENSE.txt" \
  || fail "$licenses/Sparkle-LICENSE.txt is not Sparkle's licence"
grep -q "attached to each Ferry release" "$licenses/README.txt" \
  || fail "$licenses/README.txt does not say where the exact tarballs are"
# The source offer names each exact tarball and its SHA-256.
for library in libusb libmtp; do
  grep -Eq "^https://github\.com/$library/$library/releases/download/v[0-9.]+/$library-[0-9.]+\.tar\.(bz2|gz)$" \
    "$licenses/README.txt" || fail "$licenses/README.txt does not name the $library tarball"
done
[ "$(grep -cE '^SHA-256: [0-9a-f]{64}$' "$licenses/README.txt")" = 2 ] \
  || fail "$licenses/README.txt does not give both tarballs' SHA-256"
echo "release build carries libmtp and libusb, their licences and where their source is, and Sparkle's licence"

# Command output is captured, then tested: `codesign … | grep -q` under pipefail can fail open
# when grep's early exit kills codesign. Each architecture of a universal binary (Sparkle's
# helpers are x86_64 and arm64) is checked on its own: codesign -d reads only the host's.
executables=()
while IFS= read -r -d '' file; do
  [[ "$(file -b "$file")" == *Mach-O* ]] && executables+=("$file")
done < <(find "$app" -type f -print0)
slices=0
for file in "${executables[@]}"; do
  for arch in $(lipo -archs "$file"); do
    slices=$((slices + 1))
    links="$(otool -arch "$arch" -L "$file" | tail -n +2)"
    if [[ "$links" == */opt/homebrew/* || "$links" == */usr/local/* ]]; then
      fail "$file ($arch) links a library outside the bundle and the system: $links"
    fi
    entitlements="$(codesign -d --entitlements - --xml --arch "$arch" "$file" 2> /dev/null || true)"
    [[ "$entitlements" != *get-task-allow* ]] \
      || fail "$file ($arch) is signed with com.apple.security.get-task-allow"
  done
done
echo "no executable (${#executables[@]}, $slices slices) links Homebrew or allows a debugger to attach"

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
  for arch in $(lipo -archs "$file"); do
    details="$(codesign -dv --verbose=2 --arch "$arch" "$file" 2>&1)"
    [[ "$details" =~ (^|$'\n')CodeDirectory[^$'\n']*flags=[^$'\n']*runtime ]] \
      || fail "$file ($arch) is not signed with the hardened runtime"
    [[ "$details" == *$'\n'"Authority=Developer ID Application:"* ]] \
      || fail "$file ($arch) is not signed with a Developer ID Application certificate"
    [[ "$details" == *$'\n'"Timestamp="* ]] || fail "$file ($arch) has no secure timestamp"
  done
done
codesign --verify --deep --strict "$app" || fail "$app does not verify"
echo "every executable is signed with Developer ID, the hardened runtime and a timestamp"
