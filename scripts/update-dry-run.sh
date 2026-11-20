#!/bin/bash
# The live check of automatic updates, without the release secrets: builds Ferry 0.0.1 and 0.0.2
# signed ad hoc, signs a feed for 0.0.2 with a throwaway EdDSA key (never the release key, and
# never in the keychain), serves it on 127.0.0.1, installs 0.0.1 into a temporary folder and lets
# Sparkle update it.
#
# The two copies take their own bundle identifier and a team no agent serves, and leave out the
# helper and the extensions, so they cannot reach the Ferry you use: its agent, its Finder
# extensions and its settings stay as they are. The helper's restart after an update is covered by AppModelAgentRestartTests and
# by the first real update.
#
# Usage:
#   scripts/update-dry-run.sh prepare   build, sign the feed, serve it, open Ferry 0.0.1
#   (wait until Sparkle's installer waits for Ferry to quit: pgrep -f "Autoupdate.*dry-run")
#   scripts/update-dry-run.sh finish    quit Ferry 0.0.1, wait for the install, check 0.0.2
# Everything lives in .build/dry-run; `finish` stops the server.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$PWD/.build/dry-run"
bundle_id=io.github.krisarmstrong.ferry.dry-run
port=8765
sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

# Builds version $1 with the test feed and key, and copies it to $2 as a copy that cannot reach
# the installed Ferry.
build() {
  FERRY_BUILD_SETTINGS="MARKETING_VERSION=$1 CURRENT_PROJECT_VERSION=$1 \
FERRY_FEED_URL=http://127.0.0.1:$port/appcast.xml FERRY_SPARKLE_PUBLIC_KEY=$(cat "$work/public-key")" \
    scripts/release-build.sh adhoc > "$work/build-$1.log"
  rm -rf "$2"
  ditto .build/release/Build/Products/Release/Ferry.app "$2"
  rm -r "$2/Contents/PlugIns" "$2/Contents/Library/LaunchAgents" "$2/Contents/MacOS/FerryAgent"
  # A team no agent serves, so the copy never connects to the installed Ferry's agent.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" \
    -c "Set :FerryTeamID DRYRUN0000" "$2/Contents/Info.plist"
  codesign --force --sign - --preserve-metadata=entitlements "$2"
}

prepare() {
  mkdir -p "$work"
  rm -rf "$work/feed" "$work/installed"
  mkdir -p "$work/feed" "$work/installed"

  if [ ! -x "$work/sparkle/bin/generate_appcast" ]; then
    curl -fsSL -o "$work/sparkle.tar.xz" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
    echo "$sparkle_sha256  $work/sparkle.tar.xz" | shasum -a 256 -c --status \
      || { echo "error: Sparkle's tools do not match their pinned SHA-256" >&2; exit 1; }
    mkdir -p "$work/sparkle"
    tar -xJf "$work/sparkle.tar.xz" -C "$work/sparkle"
  fi

  # A throwaway Ed25519 key, as Sparkle reads it: the 32-byte seed, base64.
  xcrun swift - > "$work/keys" << 'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
  sed -n 1p "$work/keys" > "$work/private-key"
  sed -n 2p "$work/keys" > "$work/public-key"
  rm "$work/keys"

  build 0.0.2 "$work/Ferry-0.0.2.app"
  ditto -c -k --keepParent "$work/Ferry-0.0.2.app" "$work/feed/Ferry-0.0.2.zip"
  printf '%s\n' '## Dry run' '' '- The update the dry run installs.' > "$work/feed/Ferry-0.0.2.md"
  "$work/sparkle/bin/generate_appcast" --ed-key-file "$work/private-key" --embed-release-notes \
    --download-url-prefix "http://127.0.0.1:$port/" "$work/feed"
  build 0.0.1 "$work/installed/Ferry.app"

  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" \
    > "$work/server.log" 2>&1 &
  echo $! > "$work/server.pid"

  # As if Ferry had run before and last checked long ago, so Sparkle checks at launch.
  defaults write "$bundle_id" SUHasLaunchedBefore -bool YES
  defaults write "$bundle_id" SULastCheckTime -date 2000-01-01T00:00:00Z
  open -n "$work/installed/Ferry.app"
  echo "Ferry 0.0.1 is open from $work/installed; its feed is http://127.0.0.1:$port/appcast.xml"
}

finish() {
  osascript -e "tell application id \"$bundle_id\" to quit"
  # Sparkle's installer replaces the bundle once Ferry has quit, then exits: wait for it.
  for installer in $(pgrep -f "Autoupdate.*$bundle_id"); do
    caffeinate -w "$installer"
  done
  kill "$(cat "$work/server.pid")" 2> /dev/null || true
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$work/installed/Ferry.app/Contents/Info.plist")"
  codesign --verify --strict "$work/installed/Ferry.app"
  echo "installed Ferry is $version"
  defaults delete "$bundle_id" 2> /dev/null || true
  [ "$version" = 0.0.2 ]
}

case "${1:-}" in
  prepare) prepare ;;
  finish) finish ;;
  *)
    echo "usage: $0 prepare|finish" >&2
    exit 2
    ;;
esac
