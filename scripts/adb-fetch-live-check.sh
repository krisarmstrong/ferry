#!/bin/bash
# The live check of Get Android Platform Tools…: on a Mac user account with no adb of its own,
# Ferry fetches Google's adb after one Accept, and that adb sees the attached units.
#
# Run it as that user, with the Ferry build under test installed and its helper allowed, and the
# units connected over USB with USB debugging on. It never runs an adb it has not checked first.
#
# Usage:
#   scripts/adb-fetch-live-check.sh [--clear] [--expect N]
#     --clear     first remove Ferry's fetched adb and the recorded license acceptance (asks)
#     --expect N  how many units `adb devices` must list as ready (default 1)
#
# Steps: checks that the account has no adb (none on PATH, none where Ferry looks, no server
# answering on 5037); with --clear, clears Ferry's copy; then waits while you choose Get Android
# Platform Tools… in the Ferry menu and Accept; then checks the fetched copy (only adb and
# NOTICE.txt, 0755 and 0700, signed by Google's team EQHXZ8M8AV), the recorded acceptance, and
# that `adb devices -l` lists the units.
set -euo pipefail

version=37.0.3
team=EQHXZ8M8AV
requirement='identifier "adb" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "'"$team"'"'
folder="$HOME/Library/Application Support/Ferry/platform-tools"
defaults_domain=io.github.krisarmstrong.ferry
defaults_key=AndroidSDKLicenseAcceptance
clear=false
expect=1

while (($#)); do
  case "$1" in
    --clear) clear=true ;;
    --expect)
      expect="${2:?--expect needs a number}"
      shift
      ;;
    *)
      echo "usage: $0 [--clear] [--expect N]" >&2
      exit 2
      ;;
  esac
  shift
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== This account has no adb of its own"
if command -v adb >/dev/null; then
  fail "adb is on PATH at $(command -v adb): use an account without it"
fi
for other in /opt/homebrew/bin/adb /usr/local/bin/adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  ${ANDROID_HOME:+"$ANDROID_HOME/platform-tools/adb"}; do
  [[ -x "$other" ]] && fail "Ferry would use $other: use an account without it"
done
if nc -z 127.0.0.1 5037 2>/dev/null; then
  fail "an adb server answers on 5037: Ferry uses a running server as it is, so stop it first"
fi
echo "ok"

if $clear; then
  echo "== Clearing Ferry's fetched adb and the recorded acceptance"
  echo "This removes '$folder' and the $defaults_key default of $defaults_domain."
  read -r -p "Type yes to go on: " answer
  [[ "$answer" == yes ]] || fail "not cleared"
  rm -rf -- "$folder"
  defaults delete "$defaults_domain" "$defaults_key" 2>/dev/null || true
  echo "cleared"
fi

echo
echo "== In the Ferry menu: the line 'adb isn't on this Mac' shows. It shows once a unit is listed;"
echo "   if none is, open Connect by Address… and it shows. Choose Get Android Platform Tools…, read"
echo "   the license, click Accept, and wait until the line is gone."
read -r -p "Press Return when it is gone. " _

echo "== The fetched copy"
adb="$folder/$version/adb"
[[ -x "$adb" ]] || fail "no executable adb at $adb"
contents="$(cd "$folder" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
[[ "$contents" == "./$version ./$version/NOTICE.txt ./$version/adb " ]] \
  || fail "the folder holds more than adb and its notices: $contents"
[[ "$(/usr/bin/stat -f %Lp "$folder/$version")" == 700 ]] || fail "$folder/$version is not 0700"
[[ "$(/usr/bin/stat -f %Lp "$adb")" == 755 ]] || fail "$adb is not 0755"
codesign --verify --strict --verbose=2 -R="$requirement" "$adb" \
  || fail "$adb does not carry Google's signature"
signer="$(codesign -dv "$adb" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$signer" == "$team" ]] || fail "$adb is signed by team '$signer', not $team"
echo "ok: $adb, signed by $team"

echo "== The recorded acceptance"
defaults read "$defaults_domain" "$defaults_key" || fail "no acceptance recorded"

echo "== adb devices"
"$adb" devices -l
ready="$("$adb" devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ')"
((ready >= expect)) || fail "adb lists $ready ready units, expected $expect"
echo "PASS: adb from Google, fetched by Ferry, lists $ready ready units"
