#!/bin/bash
# Renders the README's images (Design/README) from the app's own views: MenuSnapshotTests and
# HelpSnapshotTests draw the menu and Help offscreen, then Design/README/render.swift frames
# them and draws the hero and the Finder illustration. Run from anywhere; nothing needs a device,
# a signed build or a login session beyond what `make test` needs.
set -euo pipefail
cd "$(dirname "$0")/.."

snapshots="$(mktemp -d "${TMPDIR:-/tmp}/ferry-readme.XXXXXX")"
trap 'rm -rf "$snapshots"' EXIT
FERRY_MENU_SNAPSHOTS="$snapshots" FERRY_HELP_SNAPSHOTS="$snapshots" \
  swift test --filter 'MenuSnapshotTests|HelpSnapshotTests'
swift Design/README/render.swift "$snapshots"
