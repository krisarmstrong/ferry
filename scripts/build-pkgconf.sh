#!/bin/bash
# Builds the pinned pkgconf into <prefix>, with `pkg-config` beside it:
# scripts/build-pkgconf.sh <prefix>
#
# pkg-config runs inside `make release`, while the release job's Developer ID identity is
# unlocked, so the release builds it from a pinned, checked source rather than an unpinned
# `brew install`. CI runs the same script before its own `make release`, so the release path is
# exercised on every pull request. Its default search path is its own prefix: only the
# PKG_CONFIG_PATH release-build.sh sets (the pinned libmtp) is read, never Homebrew's.
#
# Upstream (distfiles.ariadne.space) publishes no checksum or signature. The SHA-256 below is the
# one Homebrew's pkgconf formula pins, and the tarball's SHA-512 matches Alpine's APKBUILD for
# pkgconf 3.0.11 (4265c810…3575): two packagers that fetched it independently.
set -euo pipefail

version=3.0.11
sha256=d0cd841bc8e55b9da888106c00dc256d05b7d1d8e5a46f4be4eb4c5125bd2dc4
prefix="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --proto '=https' -o "$work/pkgconf.tar.xz" \
  "https://distfiles.ariadne.space/pkgconf/pkgconf-$version.tar.xz"
echo "$sha256  $work/pkgconf.tar.xz" | shasum -a 256 -c --status \
  || { echo "::error::pkgconf-$version.tar.xz does not match its pinned SHA-256"; exit 1; }
mkdir "$work/src"
tar -xJf "$work/pkgconf.tar.xz" -C "$work/src" --strip-components 1
(
  cd "$work/src"
  ./configure --quiet --prefix="$prefix" --disable-shared \
    --with-system-libdir=/usr/lib --with-system-includedir=/usr/include > /dev/null
  make -s > /dev/null
  make -s install > /dev/null
)
ln -sf pkgconf "$prefix/bin/pkg-config"
built="$("$prefix/bin/pkg-config" --version)"
[ "$built" = "$version" ] || { echo "::error::the pkgconf built is $built, not $version"; exit 1; }
echo "pkgconf $version in $prefix/bin"
