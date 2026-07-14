#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: deploy.sh [<xcodebuild-destination>] [--attach]

Examples:
  deploy.sh --attach
  deploy.sh id=22F507F3-FF8F-4909-BB21-ABDB8BB84AAA --attach
  deploy.sh 'platform=iOS Simulator,id=22F507F3-FF8F-4909-BB21-ABDB8BB84AAA'
USAGE
}

DESTINATION=""
ATTACH=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while (($#)); do
  case "$1" in
    --attach)
      ATTACH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$DESTINATION" ]]; then
        echo "error: unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      DESTINATION="$1"
      shift
      ;;
  esac
done

if [[ -z "$DESTINATION" ]]; then
  DESTINATION="$("$SCRIPT_DIR/worktree-sim.sh" destination)"
fi

IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$IOS_DIR/.derivedData/deploy}"
APP_NAME="ConductorMobile.app"
APP_BUNDLE_ID="com.gannonprudhomme.conductor-mobile-unofficial"

destination_id() {
  if [[ "$DESTINATION" =~ (^|,)id=([^,]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return
  fi

  printf '%s\n' "$DESTINATION"
}

DEVICE_ID="$(destination_id)"

if xcrun simctl list devices available | grep -Fq "($DEVICE_ID)"; then
  IS_SIMULATOR=true
  SDK_DIR="Debug-iphonesimulator"
else
  IS_SIMULATOR=false
  SDK_DIR="Debug-iphoneos"
fi

XCODEBUILD_ARGS=(
  -workspace "$IOS_DIR/ConductorMobile.xcworkspace"
  -scheme ConductorMobile
  -configuration Debug
  -skipMacroValidation
  -skipPackagePluginValidation
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ "$IS_SIMULATOR" == true ]]; then
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
else
  XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build | xcbeautify

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$SDK_DIR/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$DERIVED_DATA_PATH/Build/Products/$SDK_DIR" -type d -name "$APP_NAME" -print -quit)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found under $DERIVED_DATA_PATH/Build/Products" >&2
  exit 1
fi

if [[ "$IS_SIMULATOR" == true ]]; then
  xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE_ID" -b
  open -a Simulator --args -CurrentDeviceUDID "$DEVICE_ID"
  xcrun simctl install "$DEVICE_ID" "$APP_PATH"

  if [[ "$ATTACH" == true ]]; then
    SIMCTL_CHILD_OS_ACTIVITY_DT_MODE=1 \
      xcrun simctl launch --console --terminate-running-process "$DEVICE_ID" "$APP_BUNDLE_ID"
  else
    xcrun simctl launch "$DEVICE_ID" "$APP_BUNDLE_ID"
  fi
else
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

  if [[ "$ATTACH" == true ]]; then
    DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=1 xcrun devicectl device process launch \
      --device "$DEVICE_ID" \
      --console \
      --terminate-existing \
      "$APP_BUNDLE_ID"
  else
    xcrun devicectl device process launch --device "$DEVICE_ID" "$APP_BUNDLE_ID"
  fi
fi
