#!/bin/bash
# Adapted from the macos-spm-app-packaging template. Local ad-hoc signing by default.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
CONFIGURATION="${1:-release}"
ARCH_LIST=(${ARCHES:-arm64})
APP="$PROJECT_ROOT/build/7-Zip for Mac.app"
ENGINE="${SEVENZIP_ENGINE:-$PROJECT_ROOT/Vendor/7zip/7zz}"
IDENTITY="${APP_IDENTITY:--}"
[[ -x "$ENGINE" ]] || { echo "Missing executable engine: $ENGINE" >&2; exit 1; }
if [[ -z "${RECOVERY_ENGINE:-}" ]]; then
    "$PROJECT_ROOT/Scripts/build_recovery_engine.sh"
fi
RZ_ENGINE="${RECOVERY_ENGINE:-$PROJECT_ROOT/build/recovery/rz}"
[[ -x "$RZ_ENGINE" ]] || { echo "Missing recovery engine: $RZ_ENGINE" >&2; exit 1; }
if [[ -z "${MTP_ENGINE:-}" ]]; then
    "$PROJECT_ROOT/Scripts/build_mtp_engine.sh"
fi
MTP_HELPER="${MTP_ENGINE:-$PROJECT_ROOT/build/mtp/mtp-browser}"
[[ -x "$MTP_HELPER" ]] || { echo "Missing MTP helper: $MTP_HELPER" >&2; exit 1; }
RAR_DIR="$PROJECT_ROOT/Vendor/rar"
for RAR_FILE in rar unrar default.sfx; do
    [[ -x "$RAR_DIR/$RAR_FILE" ]] || { echo "Missing RAR component: $RAR_FILE" >&2; exit 1; }
done
mkdir -p "$PROJECT_ROOT/build"
BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
    swift build -c "$CONFIGURATION" --arch "$ARCH" -Xswiftc -warnings-as-errors
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)"
    cp "$BIN_DIR/SevenZipMac" "$PROJECT_ROOT/build/SevenZipMac-$ARCH"
    BINARIES+=("$PROJECT_ROOT/build/SevenZipMac-$ARCH")
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/SevenZipMac"
else
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SevenZipMac"
fi
cp "$ENGINE" "$APP/Contents/MacOS/7zz"
cp "$RZ_ENGINE" "$APP/Contents/MacOS/rz"
cp "$MTP_HELPER" "$APP/Contents/MacOS/mtp-browser"
cp "$RAR_DIR/rar" "$RAR_DIR/unrar" "$RAR_DIR/default.sfx" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources/RAR"
cp "$RAR_DIR/"*.txt "$RAR_DIR/order.htm" "$RAR_DIR/rarfiles.lst" "$RAR_DIR/PROVENANCE.md" "$APP/Contents/Resources/RAR/"
cp "$PROJECT_ROOT/docs/RAR.md" "$APP/Contents/Resources/RAR/GUI.md"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_ROOT/Vendor/7zip/License.txt" "$APP/Contents/Resources/7zip-License.txt"
cp "$PROJECT_ROOT/../LICENSE" "$APP/Contents/Resources/LGPL.txt"
tar -xOf "$PROJECT_ROOT/Vendor/7zip/7z2603-src.tar.xz" DOC/copying.txt > "$APP/Contents/Resources/7zip-LGPL-2.1.txt"
cp "$PROJECT_ROOT/README.md" "$APP/Contents/Resources/使用说明.md"
cp "$PROJECT_ROOT/Vendor/7zip/7z2603-src.tar.xz" "$APP/Contents/Resources/7z2603-src.tar.xz"
cp "$PROJECT_ROOT/Vendor/7zip/PROVENANCE.md" "$APP/Contents/Resources/PROVENANCE.md"
cp -R "$PROJECT_ROOT/Vendor/mtp" "$APP/Contents/Resources/MTP"
cp -R "$PROJECT_ROOT/../recovery/vendor/licenses" "$APP/Contents/Resources/Recovery-Licenses"
cp "$PROJECT_ROOT/../recovery/vendor/PROVENANCE.md" "$APP/Contents/Resources/Recovery-PROVENANCE.md"
cp "$PROJECT_ROOT/../recovery/README.md" "$APP/Contents/Resources/Recovery-README.md"
tar -czf "$APP/Contents/Resources/Recovery-source.tar.gz" \
    -C "$PROJECT_ROOT/../recovery" CMakeLists.txt src tests docs README.md vendor \
    -C "$PROJECT_ROOT/.." LICENSE
tar -czf "$APP/Contents/Resources/SevenZipMac-source.tar.gz" \
    -C "$PROJECT_ROOT" Package.swift Sources Tests Scripts Helpers Resources README.md docs \
    -C "$PROJECT_ROOT/.." LICENSE
swift "$PROJECT_ROOT/Scripts/make_icon.swift" "$PROJECT_ROOT/build/AppIcon.png"
ICONSET="$PROJECT_ROOT/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$PROJECT_ROOT/build/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$PROJECT_ROOT/build/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/SevenZipMac" "$APP/Contents/MacOS/7zz" "$APP/Contents/MacOS/rz"
# Remove inherited download quarantine only from the new local build artifact.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/7zz"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/rz"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/mtp-browser"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/rar"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/unrar"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/default.sfx"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PROJECT_ROOT/build/7-Zip-for-Mac.zip"
echo "Built: $APP"
