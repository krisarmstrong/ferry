#!/bin/bash
# Builds Ferry.app for release into .build/release/Build/Products/Release: libusb and libmtp
# from pinned sources (scripts/build-libmtp.sh) in Contents/Frameworks, every part signed with
# the team's Developer ID Application identity and the hardened runtime, then checks the bundle
# (`make check-app CONFIG=Release`). It does not notarize; the release workflow does.
#
# Usage: scripts/release-build.sh [team|adhoc]
#   team   (default) the Developer ID Application identity of FERRY_TEAM_ID in the keychain
#   adhoc  signs to run locally, for scripts/update-dry-run.sh
# FERRY_BUILD_SETTINGS adds xcodebuild settings (KEY=VALUE, space-separated), such as the dry
# run's version, feed and test key.
set -euo pipefail
cd "$(dirname "$0")/.."

sign="${1:-team}"
derived=.build/release
app="$derived/Build/Products/Release/Ferry.app"
read -r -a extra <<< "${FERRY_BUILD_SETTINGS:-}"

scripts/build-libmtp.sh .build/deps
deps="$PWD/.build/deps"

case "$sign" in
  team)
    team="$(sed -n 's/^ *FERRY_TEAM_ID: *\([A-Z0-9]\{10\}\)$/\1/p' project.yml)"
    identity="$(security find-identity -v -p codesigning \
      | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"Developer ID Application: .* ($team)\"$/\1/p" \
      | head -1)"
    [ -n "$identity" ] || {
      echo "error: no Developer ID Application identity of team $team in the keychain" >&2
      exit 1
    }
    signing=(CODE_SIGN_IDENTITY="$identity")
    runtime=(--options runtime --timestamp)
    ;;
  adhoc)
    identity=-
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
    runtime=(--timestamp=none)
    ;;
  *)
    echo "usage: $0 [team|adhoc]" >&2
    exit 2
    ;;
esac

xcodegen generate --quiet
# CLibMTP finds libmtp through pkg-config: the pinned build, not Homebrew's.
PKG_CONFIG_PATH="$deps/lib/pkgconfig" xcodebuild -project Ferry.xcodeproj -scheme Ferry \
  -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -quiet "${signing[@]}" ${extra[@]+"${extra[@]}"} build

# Inside out: the libraries the agent loads, Sparkle's helpers (Sparkle's documented order),
# then the app, whose seal covers them all.
frameworks="$app/Contents/Frameworks"
for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
  ditto "$deps/lib/$lib" "$frameworks/$lib"
  codesign --force --sign "$identity" "${runtime[@]}" "$frameworks/$lib"
done
# LGPL-2.1: their licence texts, and where their unmodified source is.
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
for source in "$deps"/src/libusb-*/ "$deps"/src/libmtp-*/; do
  [ -d "$source" ] || continue
  name="$(basename "$source")"
  ditto "$source/COPYING" "$licenses/$name-COPYING.txt"
done
{
  echo "Ferry links $(sed 's/ libmtp / and libmtp /' "$deps/versions"), unmodified, under the GNU Lesser"
  echo "General Public License 2.1 (see the COPYING files here). Their source code:"
  echo "https://github.com/libusb/libusb/releases"
  echo "https://github.com/libmtp/libmtp/releases"
} > "$licenses/README.txt"
sparkle="$frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$identity" "${runtime[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign --force --sign "$identity" "${runtime[@]}" --preserve-metadata=entitlements \
  "$sparkle/XPCServices/Downloader.xpc"
codesign --force --sign "$identity" "${runtime[@]}" "$sparkle/Autoupdate"
codesign --force --sign "$identity" "${runtime[@]}" "$sparkle/Updater.app"
codesign --force --sign "$identity" "${runtime[@]}" "$frameworks/Sparkle.framework"
codesign --force --sign "$identity" "${runtime[@]}" --preserve-metadata=entitlements "$app"

make check-app CONFIG=Release APP="$app" SIGN="$sign"
echo "$app"
