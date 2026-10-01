#!/bin/bash
# Offline, pinned MTP helper build. No Homebrew libraries enter the app bundle.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_ROOT/Vendor/mtp"
BUILD="$PROJECT_ROOT/build/mtp"
PREFIX="$BUILD/install"
[[ "${ARCHES:-arm64}" == "arm64" ]] || { echo "MTP currently targets arm64 only." >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "pkg-config is required to build libmtp." >&2; exit 1; }
cd "$VENDOR"
shasum -a 256 -c SHA256SUMS
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0 -Werror=unguarded-availability-new"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
if [[ ! -f "$PREFIX/lib/libusb-1.0.a" || ! -f "$PREFIX/.macos14-no-pipe2" ]]; then
    tar -xf "$VENDOR/libusb-1.0.29.tar.bz2" -C "$BUILD"
    cd "$BUILD/libusb-1.0.29"
    # New SDKs expose pipe2 even though our macOS 14 deployment target lacks it.
    ac_cv_func_pipe2=no ./configure --prefix="$PREFIX" --disable-shared --enable-static
    make -j4
    make install
    touch "$PREFIX/.macos14-no-pipe2"
fi
if [[ ! -f "$PREFIX/lib/libmtp.a" ]]; then
    tar -xf "$VENDOR/libmtp-1.1.23.tar.gz" -C "$BUILD"
    cd "$BUILD/libmtp-1.1.23"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-mtpz --disable-nls
    make -C src -j4
    make -C src install
fi
xcrun clang $CFLAGS -Wall -Wextra -Werror \
    -I"$PREFIX/include" "$PROJECT_ROOT/Helpers/mtp/mtp-browser.c" \
    "$PREFIX/lib/libmtp.a" "$PREFIX/lib/libusb-1.0.a" \
    -liconv -lobjc -framework IOKit -framework CoreFoundation -framework Security \
    -o "$BUILD/mtp-browser"
echo "Built: $BUILD/mtp-browser"
