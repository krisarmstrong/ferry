#!/bin/bash
# Packages Ferry.app as Ferry's disk image: the app, a link to /Applications and the designed
# window (Design/DMG), then checks it (scripts/check-dmg.sh). dmgbuild, pinned by hash in
# scripts/dmg-requirements.txt, lays out the window and writes its .DS_Store itself, so neither
# Finder nor AppleScript is involved and it runs on a runner with no login session.
#
# The release workflow runs it on the stapled app, then signs, notarizes and staples the image.
# scripts/release-build.sh runs it too, so CI builds and checks the image on every change.
#
# Usage: scripts/make-dmg.sh <Ferry.app> <out.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 2 ] || { echo "usage: $0 <Ferry.app> <out.dmg>" >&2; exit 2; }
app="$1"
dmg="$2"
[ -d "$app" ] || { echo "error: no app at $app" >&2; exit 1; }

# A virtual environment of its own, rebuilt whenever the pinned requirements change.
venv=.build/dmg-venv
requirements=scripts/dmg-requirements.txt
if ! cmp -s "$requirements" "$venv/requirements.txt"; then
  rm -rf "$venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check --no-deps --require-hashes \
    --only-binary=:all: -r "$requirements"
  cp "$requirements" "$venv/requirements.txt"
fi

mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"
# The volume is always named Ferry: the window's background is found through an alias that
# names the volume.
"$venv/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$app" \
  -D background=Design/DMG/background.tiff Ferry "$dmg"
scripts/check-dmg.sh "$dmg" "$app"
