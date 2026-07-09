#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
TEST_SCHEMES=(
  ConductorDataTests
  ConductorWorkspacesTests
)

for scheme in "${TEST_SCHEMES[@]}"; do
  xcodebuild test \
    -workspace "$IOS_DIR/ConductorMobile.xcworkspace" \
    -scheme "$scheme" \
    -destination "$TEST_DESTINATION" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO | xcbeautify
done
