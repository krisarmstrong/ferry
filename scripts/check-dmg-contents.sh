#!/bin/bash
# Checks that a disk image holds exactly the app it was made from, before anything signs it.
# The image comes from a job that runs third-party code (dmgbuild) with no signing material, so
# the job that signs it must not trust it:
# - its root holds Ferry.app, the Applications link, the window's background and its layout,
#   and nothing else (.fseventsd, which macOS may write, aside);
# - the Ferry.app inside verifies, and has the code directory hash and team of <Ferry.app>;
# - every file, link and folder in it has the type, mode, target and SHA-256 it has in
#   <Ferry.app>, with none added or missing.
# It mounts the image read-only at a folder of its own, as scripts/check-dmg.sh does.
#
# Usage: scripts/check-dmg-contents.sh <Ferry.dmg> <Ferry.app>
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}
[ $# -eq 2 ] || { echo "usage: $0 <Ferry.dmg> <Ferry.app>" >&2; exit 2; }
dmg="$1"
app="$2"
[ -d "$app" ] || fail "$app is not an app bundle"

work="$(mktemp -d "${TMPDIR:-/tmp}/ferry-dmg-contents.XXXXXX")"
mount="$work/mount"
mkdir "$mount"
trap 'hdiutil detach -quiet "$mount" 2> /dev/null || true; rm -rf "$work"' EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" \
  || fail "cannot mount $dmg"

root="$(cd "$mount" && find . -mindepth 1 -maxdepth 1 ! -name .fseventsd | LC_ALL=C sort | tr '\n' ' ')"
[ "$root" = "./.DS_Store ./.background.tiff ./Applications ./Ferry.app " ] \
  || fail "$dmg holds $root, not exactly Ferry.app, Applications, .background.tiff and .DS_Store"
[ "$(readlink "$mount/Applications")" = /Applications ] \
  || fail "Applications in $dmg is not a link to /Applications"

codesign --verify --deep --strict "$mount/Ferry.app" || fail "Ferry.app in $dmg does not verify"
signature() {
  codesign -d --verbose=4 "$1" 2>&1 | sed -nE 's/^(CDHash|TeamIdentifier)=//p'
}
[ "$(signature "$mount/Ferry.app")" = "$(signature "$app")" ] \
  || fail "Ferry.app in $dmg is not signed as $app (code directory hash or team differ)"

# mtree reports, and fails on, any entry that differs, is missing or is extra.
keywords=type,link,mode,size,sha256digest
mtree -c -k "$keywords" -p "$app" > "$work/app.spec"
mtree -k "$keywords" -p "$mount/Ferry.app" -f "$work/app.spec" > "$work/diff" 2>&1 \
  || fail "Ferry.app in $dmg differs from $app: $(head -20 "$work/diff")"
echo "disk image holds exactly Ferry.app as built ($(signature "$app" | head -1))"
