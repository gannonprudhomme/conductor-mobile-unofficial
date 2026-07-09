#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

xcodebuild \
  -workspace "$IOS_DIR/ConductorMobile.xcworkspace" \
  -scheme ConductorMobile \
  -configuration Debug \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify
