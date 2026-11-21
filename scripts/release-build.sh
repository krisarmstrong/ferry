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
    # On the command line it reaches the package's resource bundles too, which need the team.
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team")
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
# CLibMTP finds libmtp through pkg-config: the pinned build, not Homebrew's. Clean first: an
# incremental build can keep an earlier copy of the agent in Contents/MacOS.
PKG_CONFIG_PATH="$deps/lib/pkgconfig" xcodebuild -project Ferry.xcodeproj -scheme Ferry \
  -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -quiet "${signing[@]}" ${extra[@]+"${extra[@]}"} clean build

# Inside out: the libraries the agent loads, Sparkle's helpers (Sparkle's documented order),
# then the app, whose seal covers them all.
frameworks="$app/Contents/Frameworks"
for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
  ditto "$deps/lib/$lib" "$frameworks/$lib"
  codesign --force --sign "$identity" "${runtime[@]}" "$frameworks/$lib"
done
# LGPL-2.1: their licence texts, and the exact source they were built from.
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
{
  echo "Ferry links these libraries, unmodified, under the GNU Lesser General Public License 2.1"
  echo "(see the COPYING files here). It builds them from these release tarballs with"
  echo "scripts/build-libmtp.sh in https://github.com/krisarmstrong/ferry. The exact tarballs"
  echo "are attached to each Ferry release on GitHub, beside the app:"
  echo "https://github.com/krisarmstrong/ferry/releases"
} > "$licenses/README.txt"
while read -r name version url sha256; do
  copying="$deps/src/$name-$version/COPYING"
  [ -f "$copying" ] || { echo "error: no licence text at $copying" >&2; exit 1; }
  ditto "$copying" "$licenses/$name-$version-COPYING.txt"
  printf '\n%s %s\n%s\nSHA-256: %s\n' "$name" "$version" "$url" "$sha256" >> "$licenses/README.txt"
done < "$deps/sources"
# MIT: Sparkle's notice, with the third-party notices its LICENSE lists, in every copy.
sparkle_license="$derived/SourcePackages/artifacts/sparkle/Sparkle/LICENSE"
[ -s "$sparkle_license" ] || { echo "error: no Sparkle licence at $sparkle_license" >&2; exit 1; }
ditto "$sparkle_license" "$licenses/Sparkle-LICENSE.txt"
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
