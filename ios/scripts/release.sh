#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: release.sh [marketing-version]" >&2
  echo "Example: release.sh 0.2.0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conductor-mobile-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

XCODEBUILD_ARGUMENTS=(
  -workspace "$IOS_DIR/ConductorMobile.xcworkspace"
  -scheme ConductorMobile
  -configuration Release
  -destination "generic/platform=iOS"
  -derivedDataPath "$WORK_DIR/DerivedData"
  -onlyUsePackageVersionsFromResolvedFile
  -skipMacroValidation
  -skipPackagePluginValidation
  -allowProvisioningUpdates
)

if [[ $# -eq 1 ]]; then
  VERSION="$1"
  XCODEBUILD_ARGUMENTS+=(MARKETING_VERSION="$VERSION")
else
  VERSION="$(
    xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" -showBuildSettings \
      | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / && !found { print $2; found = 1 }'
  )"
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "The marketing version must contain two or three numeric components (for example, 0.2.0)." >&2
  exit 2
fi

mkdir -p "$IOS_DIR/dist"
ARCHIVE="$IOS_DIR/dist/ConductorMobile-$VERSION-$(date +%Y-%m-%d-%H%M%S)-$$.xcarchive"

xcodebuild \
  "${XCODEBUILD_ARGUMENTS[@]}" \
  -archivePath "$ARCHIVE" \
  archive | xcbeautify

LOCK_FILE="${TMPDIR:-/tmp}/com.gannonprudhomme.conductor-mobile-unofficial-testflight-release.lock"
exec 9>"$LOCK_FILE"
echo "Waiting for the TestFlight upload lock..."
lockf 9

PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$WORK_DIR/Export" \
  -exportOptionsPlist "$IOS_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates | xcbeautify

echo "Uploaded $ARCHIVE to App Store Connect."
