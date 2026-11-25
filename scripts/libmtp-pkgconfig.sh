#!/bin/bash
# Writes libmtp.pc, without the `-framework IOKit` its Cflags carry, into <dir>:
# scripts/libmtp-pkgconfig.sh <dir>
#
# libmtp's configure puts a linker flag in Cflags, and SwiftPM refuses -framework from a
# pkg-config file: every build warns "prohibited flag(s): -framework, IOKit" and drops it. The
# flag does nothing here, since the targets that use IOKit import it. Point PKG_CONFIG_PATH at
# <dir> to build without the warning; the installed file stays as it is.
set -euo pipefail

out="$1"
pcfile="$(pkg-config --variable=pcfiledir libmtp)/libmtp.pc"
mkdir -p "$out"
sed 's/ -framework IOKit//' "$pcfile" > "$out/libmtp.pc.tmp"
mv "$out/libmtp.pc.tmp" "$out/libmtp.pc"
