#!/bin/bash
# Builds libusb and libmtp from pinned release tarballs into a prefix, for release builds:
# arm64, the app's minimum macOS, and @rpath install names, so the agent loads the copies in
# Ferry.app/Contents/Frameworks. Development builds use Homebrew's instead.
#
# Usage: scripts/build-libmtp.sh [prefix]     (default .build/deps)
# Prints nothing but errors; the prefix then holds lib/, include/ and lib/pkgconfig/.
set -euo pipefail

LIBUSB_VERSION=1.0.30
LIBUSB_SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
LIBMTP_VERSION=1.1.23
LIBMTP_SHA256=74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
MINIMUM_MACOS=26.0

prefix="$(mkdir -p "${1:-.build/deps}" && cd "${1:-.build/deps}" && pwd)"
sources="$prefix/src"
mkdir -p "$sources"

# Downloads $2 to $sources/$1 unless it is there with checksum $3, and unpacks it.
fetch() {
  local file="$sources/$1"
  if ! { [ -f "$file" ] && echo "$3  $file" | shasum -a 256 -c --status; }; then
    curl -fsSL -o "$file" "$2"
    echo "$3  $file" | shasum -a 256 -c --status \
      || { echo "error: $1 does not match its pinned SHA-256" >&2; exit 1; }
  fi
  tar -xf "$file" -C "$sources"
}

if [ -f "$prefix/lib/libmtp.9.dylib" ] \
  && [ "$(cat "$prefix/versions" 2>/dev/null)" = "libusb $LIBUSB_VERSION libmtp $LIBMTP_VERSION" ]; then
  exit 0
fi

export CFLAGS="-arch arm64 -mmacosx-version-min=$MINIMUM_MACOS -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MINIMUM_MACOS"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
jobs="$(sysctl -n hw.ncpu)"

fetch "libusb-$LIBUSB_VERSION.tar.bz2" \
  "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" \
  "$LIBUSB_SHA256"
(
  cd "$sources/libusb-$LIBUSB_VERSION"
  ./configure --quiet --prefix="$prefix" --disable-static
  make --quiet -j "$jobs" install > /dev/null
)

fetch "libmtp-$LIBMTP_VERSION.tar.gz" \
  "https://github.com/libmtp/libmtp/releases/download/v$LIBMTP_VERSION/libmtp-$LIBMTP_VERSION.tar.gz" \
  "$LIBMTP_SHA256"
(
  cd "$sources/libmtp-$LIBMTP_VERSION"
  # No MTPZ, as in Homebrew's build: it needs libgcrypt, and only old Zune players use it.
  ./configure --quiet --prefix="$prefix" --disable-static --disable-mtpz \
    --with-udev="$prefix/lib/udev"
  make --quiet -j "$jobs" install > /dev/null
)

# The agent finds both in Contents/Frameworks through its @rpath.
lib="$prefix/lib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$lib/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libmtp.9.dylib \
  -change "$lib/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$lib/libmtp.9.dylib"
for dylib in "$lib/libusb-1.0.0.dylib" "$lib/libmtp.9.dylib"; do
  codesign --force --sign - "$dylib" 2> /dev/null
  if otool -L "$dylib" | tail -n +2 | grep -v -e '@rpath/' -e '/usr/lib/' -e '/System/Library/' >&2; then
    echo "error: $dylib links a library outside the system and the bundle" >&2
    exit 1
  fi
done
echo "libusb $LIBUSB_VERSION libmtp $LIBMTP_VERSION" > "$prefix/versions"
