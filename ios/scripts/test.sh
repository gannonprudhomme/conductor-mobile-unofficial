#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${TEST_DESTINATION:-}" ]]; then
  TEST_DESTINATION="$("$SCRIPT_DIR/worktree-sim.sh" destination)"
  trap '"$SCRIPT_DIR/worktree-sim.sh" clean' EXIT
fi

TEST_SCHEMES=(
  ConductorChatTests
  ConductorDataTests
  ConductorSessionsTests
  ConductorWorkspacesTests
  ConductorMainTests
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
