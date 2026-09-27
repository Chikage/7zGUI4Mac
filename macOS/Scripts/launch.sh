#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "$PROJECT_ROOT/build/7-Zip for Mac.app" ]]; then "$PROJECT_ROOT/Scripts/package_app.sh"; fi
open "$PROJECT_ROOT/build/7-Zip for Mac.app"
