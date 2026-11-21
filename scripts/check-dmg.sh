#!/bin/bash
# Checks Ferry's disk image (scripts/make-dmg.sh):
# - Ferry.app, a link named Applications to /Applications, the window's background and its
#   .DS_Store, which shows the background and places both icons;
# - the app inside verifies, and is the version of <Ferry.app> when one is given;
# - with --release: the image is signed and stapled, and so is the app inside it.
# It mounts the image read-only at a folder of its own, never in /Volumes, so a Ferry volume
# already mounted is left alone.
#
# Usage: scripts/check-dmg.sh <Ferry.dmg> [<Ferry.app> | --release]
set -euo pipefail
cd "$(dirname "$0")/.."

dmg="$1"
mode="${2:-}"
fail() {
  echo "error: $*" >&2
  exit 1
}

mount="$(mktemp -d "${TMPDIR:-/tmp}/ferry-dmg.XXXXXX")"
trap 'hdiutil detach -quiet "$mount" 2> /dev/null || true; rmdir "$mount" 2> /dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" \
  || fail "cannot mount $dmg"

[ -d "$mount/Ferry.app" ] || fail "$dmg has no Ferry.app"
[ "$(readlink "$mount/Applications")" = /Applications ] \
  || fail "$dmg has no Applications link to /Applications"
[ -s "$mount/.background.tiff" ] || fail "$dmg has no window background"
[ -s "$mount/.DS_Store" ] || fail "$dmg has no window layout (.DS_Store)"
# The layout, read with the pinned ds_store that wrote it.
.build/dmg-venv/bin/python3 - "$mount/.DS_Store" << 'PY' || fail "$dmg does not lay out its window"
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    entries = {(entry.filename, entry.code.decode()): entry.value for entry in store}
view = entries.get((".", "icvp"), {})
assert view.get("backgroundType") == 2 and view.get("backgroundImageAlias"), "no background"
assert entries.get(("Ferry.app", "Iloc")), "Ferry.app is not placed"
assert entries.get(("Applications", "Iloc")), "Applications is not placed"
PY
echo "disk image carries Ferry.app, the Applications link, its background and its layout"

codesign --verify --deep --strict "$mount/Ferry.app" || fail "Ferry.app in $dmg does not verify"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$mount/Ferry.app/Contents/Info.plist")"
case "$mode" in
  --release)
    codesign --verify --strict "$dmg" || fail "$dmg is not signed"
    xcrun stapler validate -q "$dmg" || fail "$dmg is not stapled"
    xcrun stapler validate -q "$mount/Ferry.app" || fail "Ferry.app in $dmg is not stapled"
    echo "disk image of Ferry $version is signed and stapled, as is the app inside it"
    ;;
  "")
    echo "disk image carries Ferry $version"
    ;;
  *)
    expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$mode/Contents/Info.plist")"
    [ "$version" = "$expected" ] || fail "$dmg carries Ferry $version, not $expected"
    echo "disk image carries Ferry $version, as built"
    ;;
esac
