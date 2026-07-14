#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DESKTOP_DIR/.derivedData/build}"

DERIVED_DATA_PATH="$DERIVED_DATA_PATH" "$SCRIPT_DIR/build.sh"

APP="$DERIVED_DATA_PATH/Build/Products/Debug/Conductor Mobile Proxy (unofficial).app"
exec "$APP/Contents/MacOS/Conductor Mobile Proxy (unofficial)"
