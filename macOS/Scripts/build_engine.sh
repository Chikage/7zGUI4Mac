#!/bin/bash
# Build the unmodified, pinned upstream C/C++ source. No network required.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ARCHIVE="$PROJECT_ROOT/Vendor/7zip/7z2603-src.tar.xz"
SOURCE_HASH="9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4"
ACTUAL_HASH="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_HASH" == "$SOURCE_HASH" ]] || { echo "7-Zip source checksum mismatch" >&2; exit 1; }
SOURCE_ROOT="$PROJECT_ROOT/.build/7zip-source"
mkdir -p "$SOURCE_ROOT" "$PROJECT_ROOT/build/engine"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"
ARCH_LIST=(${ARCHES:-arm64})
BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
    case "$ARCH" in
        arm64) MAKE_ARCH=arm64; OBJECT_ARCH=arm64 ;;
        x86_64) MAKE_ARCH=x64; OBJECT_ARCH=x64 ;;
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
    MACOSX_DEPLOYMENT_TARGET=14.0 make -C "$SOURCE_ROOT/CPP/7zip/Bundles/Alone2" \
        -j "${JOBS:-$(sysctl -n hw.ncpu)}" -f "../../cmpl_mac_${MAKE_ARCH}.mak"
    BINARIES+=("$SOURCE_ROOT/CPP/7zip/Bundles/Alone2/b/m_${OBJECT_ARCH}/7zz")
done
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$PROJECT_ROOT/build/engine/7zz"
else
    lipo -create "${BINARIES[@]}" -output "$PROJECT_ROOT/build/engine/7zz"
fi
codesign --force --sign - "$PROJECT_ROOT/build/engine/7zz"
echo "Built: $PROJECT_ROOT/build/engine/7zz"
