#!/bin/bash
# Checks Ferry's disk image (scripts/make-dmg.sh):
# - Ferry.app, a link named Applications to /Applications and the window's background;
# - its .DS_Store shows the background and places both icons (read with the pinned ds_store
#   that wrote it, so only where make-dmg.sh ran: never in a job holding signing material);
# - the app inside verifies, and is the version of <Ferry.app> when one is given;
# - with --release: the image is signed, stapled and accepted by Gatekeeper, and the app inside
#   it is stapled.
# It mounts the image read-only at a folder of its own, never in /Volumes, so a Ferry volume
# already mounted is left alone.
#
# Usage: scripts/check-dmg.sh <Ferry.dmg> [<Ferry.app> | --release]
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 <Ferry.dmg> [<Ferry.app> | --release]" >&2; exit 2; }
dmg="$1"
mode="${2:-}"
venv="$(cd "$(dirname "$0")/.." && pwd)/.build/dmg-venv"

mount="$(mktemp -d "${TMPDIR:-/tmp}/ferry-dmg.XXXXXX")"
trap 'hdiutil detach -quiet "$mount" 2> /dev/null || true; rmdir "$mount" 2> /dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" \
  || fail "cannot mount $dmg"

[ -d "$mount/Ferry.app" ] || fail "$dmg has no Ferry.app"
[ "$(readlink "$mount/Applications")" = /Applications ] \
  || fail "$dmg has no Applications link to /Applications"
[ -s "$mount/.background.tiff" ] || fail "$dmg has no window background"
[ -s "$mount/.DS_Store" ] || fail "$dmg has no window layout (.DS_Store)"
if [ "$mode" != --release ]; then
  "$venv/bin/python3" -I - "$mount/.DS_Store" << 'PY' || fail "$dmg does not lay out its window"
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    entries = {(entry.filename, entry.code.decode()): entry.value for entry in store}
view = entries.get((".", "icvp"), {})
assert view.get("backgroundType") == 2 and view.get("backgroundImageAlias"), "no background"
assert entries.get(("Ferry.app", "Iloc")), "Ferry.app is not placed"
assert entries.get(("Applications", "Iloc")), "Applications is not placed"
PY
  echo "disk image lays out its window: background, Ferry.app and Applications placed"
fi
echo "disk image carries Ferry.app, the Applications link, its background and a layout"

codesign --verify --deep --strict "$mount/Ferry.app" || fail "Ferry.app in $dmg does not verify"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$mount/Ferry.app/Contents/Info.plist")"
case "$mode" in
  --release)
    codesign --verify --strict "$dmg" || fail "$dmg is not signed"
    xcrun stapler validate -q "$dmg" || fail "$dmg is not stapled"
    spctl -a -t open --context context:primary-signature "$dmg" 2> /dev/null \
      || fail "Gatekeeper does not accept $dmg"
    xcrun stapler validate -q "$mount/Ferry.app" || fail "Ferry.app in $dmg is not stapled"
    echo "disk image of Ferry $version is signed, stapled and accepted by Gatekeeper," \
      "and the app inside it is stapled"
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
