#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECOVERY_ROOT="$PROJECT_ROOT/../recovery"
BUILD_DIR="$PROJECT_ROOT/build/recovery-arm64"
command -v cmake >/dev/null || { echo "CMake 3.24+ is required to build the bundled recovery engine." >&2; exit 1; }
[[ "${ARCHES:-arm64}" == "arm64" ]] || { echo "The macOS app currently targets arm64 only." >&2; exit 1; }
cmake -S "$RECOVERY_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$BUILD_DIR" --target rz --parallel 4
mkdir -p "$PROJECT_ROOT/build/recovery"
cp "$BUILD_DIR/rz" "$PROJECT_ROOT/build/recovery/rz"
echo "Built: $PROJECT_ROOT/build/recovery/rz"
