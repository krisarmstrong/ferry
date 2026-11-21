#!/bin/bash
# Packages Ferry.app as Ferry's disk image: the app, a link to /Applications and the designed
# window (Design/DMG), then checks it (scripts/check-dmg.sh). dmgbuild, pinned by hash in
# scripts/dmg-requirements.txt, lays out the window and writes its .DS_Store itself, so neither
# Finder nor AppleScript is involved and it runs on a runner with no login session.
#
# It is third-party code, so it never runs where signing material is: CI runs it on the ad hoc
# release build, and the release workflow in a job of its own with no secrets, on the stapled
# app. A later job signs, notarizes and staples the image.
#
# Usage: scripts/make-dmg.sh <Ferry.app> <out.dmg>
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <Ferry.app> <out.dmg>" >&2; exit 2; }
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
dmg="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$app" ] || { echo "error: no app at $app" >&2; exit 1; }

# A virtual environment without pip, rebuilt whenever the pins change: each wheel is downloaded,
# checked against its SHA-256 and unpacked into it.
venv="$root/.build/dmg-venv"
requirements="$root/scripts/dmg-requirements.txt"
if ! cmp -s "$requirements" "$venv/requirements.txt"; then
  rm -rf "$venv"
  python3 -m venv --without-pip "$venv"
  site="$("$venv/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  wheels="$(mktemp -d "${TMPDIR:-/tmp}/ferry-wheels.XXXXXX")"
  trap 'rm -rf "$wheels"' EXIT
  while read -r name version url sha256; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    wheel="$wheels/$name-$version.whl"
    curl -fsSL --proto '=https' -o "$wheel" "$url"
    echo "$sha256  $wheel" | shasum -a 256 -c - > /dev/null \
      || { echo "error: $name $version does not match its pinned SHA-256" >&2; exit 1; }
    unzip -q -o "$wheel" -d "$site"
  done < "$requirements"
  cp "$requirements" "$venv/requirements.txt"
fi

mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"
# The volume is always named Ferry: the window's background is found through an alias that
# names the volume.
"$venv/bin/python3" -I -m dmgbuild -s "$root/scripts/dmg-settings.py" -D app="$app" \
  -D background="$root/Design/DMG/background.tiff" Ferry "$dmg"
"$root/scripts/check-dmg.sh" "$dmg" "$app"
