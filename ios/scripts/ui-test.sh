#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="$IOS_DIR/.derivedData/ui-test"

if [[ -n "${TEST_DESTINATION:-}" ]]; then
  DESTINATION="$TEST_DESTINATION"
else
  DEVICE_ID="$(
    xcrun simctl create \
      "Conductor Cloud UI Tests $$" \
      "${CONDUCTOR_SIMULATOR_DEVICE_TYPE:-iPhone 17}"
  )"
  DESTINATION="id=$DEVICE_ID"
  trap 'xcrun simctl delete "$DEVICE_ID"' EXIT
fi

xcodebuild test \
  -workspace "$IOS_DIR/ConductorMobile.xcworkspace" \
  -scheme ConductorMobileUITests \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO | xcbeautify
