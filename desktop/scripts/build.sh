#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DESKTOP_DIR/.derivedData/build}"
HOST_ARCH="$(uname -m)"

xcodebuild \
  -project "$DESKTOP_DIR/ConductorDesktop.xcodeproj" \
  -scheme ConductorDesktop \
  -configuration Debug \
  -destination "platform=macOS,arch=$HOST_ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify

APP="$DERIVED_DATA_PATH/Build/Products/Debug/Conductor Mobile Proxy (unofficial).app"
codesign --force --sign - "$APP/Contents/Helpers/conductor-bridge-installer"
codesign --force --sign - "$APP"
