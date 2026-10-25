#!/bin/bash
# Rebuilds Resources/wow64cpu-<version>-rosetta.dll: Wine's wow64cpu.dll with
# WinePatches/wow64cpu-rosetta2-workaround.patch applied (see WinePatches/README.md).
#
#   Scripts/build-wow64cpu.sh            # builds for the Wine version PortKit pins
#   WINE_VERSION=11.18 Scripts/build-wow64cpu.sh
#
# Needs: Xcode Command Line Tools, curl, ~2 GB of disk, ~10 minutes.
# Downloads llvm-mingw (Windows cross compiler), GNU bison 3 and the Wine source into a work folder.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

WINE_VERSION="${WINE_VERSION:-11.18}"
LLVM_MINGW="${LLVM_MINGW:-20261020}"
BISON="${BISON:-3.8.2}"
WORK="${WORK:-$ROOT/.build/wow64cpu}"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d "llvm-mingw-$LLVM_MINGW-ucrt-macos-universal" ]; then
  curl -fL -o llvm.tar.xz "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW/llvm-mingw-$LLVM_MINGW-ucrt-macos-universal.tar.xz"
  tar -xJf llvm.tar.xz && rm llvm.tar.xz
fi

if [ ! -x tools/bin/bison ]; then
  curl -fL -o bison.tar.xz "https://ftp.gnu.org/gnu/bison/bison-$BISON.tar.xz"
  tar -xJf bison.tar.xz && rm bison.tar.xz
  (cd "bison-$BISON" && ./configure --prefix="$WORK/tools" --disable-nls >/dev/null && make -j8 >/dev/null && make install >/dev/null)
fi

rm -rf "wine-$WINE_VERSION" build
MAJOR="${WINE_VERSION%%.*}"
curl -fL -o wine.tar.xz "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$WINE_VERSION.tar.xz"
tar -xJf wine.tar.xz && rm wine.tar.xz
(cd "wine-$WINE_VERSION" && patch -p1 < "$ROOT/WinePatches/wow64cpu-rosetta2-workaround.patch")

export PATH="$WORK/tools/bin:$WORK/llvm-mingw-$LLVM_MINGW-ucrt-macos-universal/bin:$PATH"
mkdir build && cd build
"../wine-$WINE_VERSION/configure" --enable-archs=i386,x86_64 --disable-tests \
  --without-x --without-freetype --without-gnutls --without-gstreamer --without-sdl --without-vulkan \
  --without-opencl --without-pcap --without-usb --without-cups --without-sane --without-capi --without-krb5 \
  --without-netapi --without-gphoto --without-pulse --without-alsa --without-oss --without-udev --without-dbus \
  --without-inotify --without-unwind --without-ffmpeg > configure.log
make -j8 dlls/wow64cpu/x86_64-windows/wow64cpu.dll > make.log

OUT="$ROOT/Resources/wow64cpu-$WINE_VERSION-rosetta.dll"
llvm-strip -o "$OUT" dlls/wow64cpu/x86_64-windows/wow64cpu.dll
echo "Built $OUT"
shasum -a 256 "$OUT"
