#!/bin/bash
# Exercises scripts/check-dmg-contents.sh on a disk image made from <Ferry.app>, as CI makes one:
# it must accept that image, and refuse it against a copy of the app with one byte changed, and
# refuse an image holding one entry more. The publish job relies on it before signing, and runs
# only on a release, so CI is where it is tried.
#
# Usage: scripts/check-dmg-contents-test.sh <Ferry.dmg> <Ferry.app>
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}
[ $# -eq 2 ] || { echo "usage: $0 <Ferry.dmg> <Ferry.app>" >&2; exit 2; }
dmg="$1"
app="$2"
check="$(cd "$(dirname "$0")" && pwd)/check-dmg-contents.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/ferry-dmg-contents-test.XXXXXX")"
mount="$work/mount"
mkdir "$mount"
trap 'hdiutil detach -quiet "$mount" 2> /dev/null || true; rm -rf "$work"' EXIT

"$check" "$dmg" "$app"

ditto "$app" "$work/changed/Ferry.app"
printf 'x' >> "$work/changed/Ferry.app/Contents/Resources/Ferry.icns"
if "$check" "$dmg" "$work/changed/Ferry.app" 2> "$work/changed.err"; then
  fail "an image was accepted against an app with a changed resource"
fi
echo "refused against an app with one byte changed: $(head -1 "$work/changed.err")"

hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg"
ditto "$mount" "$work/extra"
hdiutil detach -quiet "$mount"
printf 'not Ferry\n' > "$work/extra/payload"
hdiutil create -quiet -fs HFS+ -format UDZO -volname Ferry -srcfolder "$work/extra" \
  "$work/extra.dmg"
if "$check" "$work/extra.dmg" "$app" 2> "$work/extra.err"; then
  fail "an image holding an extra entry was accepted"
fi
echo "refused an image with an extra entry: $(head -1 "$work/extra.err")"
