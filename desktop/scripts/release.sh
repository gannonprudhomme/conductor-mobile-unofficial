#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: release.sh <marketing-version>" >&2
  echo "Example: release.sh 0.1.0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_ARCH="$(uname -m)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-conductor-mobile}"
VERSION="$1"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="Conductor Mobile Companion"
OUTPUT_DIR="$DESKTOP_DIR/dist"
DMG="$OUTPUT_DIR/Conductor-Mobile-Companion-$VERSION.dmg"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "The marketing version must contain two or three numeric components (for example, 0.1.0)." >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be a nonnegative integer." >&2
  exit 2
fi

if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
  cat >&2 <<EOF
No matching code-signing identity was found for "$SIGNING_IDENTITY".

In Xcode, open Settings > Accounts, select your team, choose Manage
Certificates, and create a Developer ID Application certificate. Set
SIGNING_IDENTITY if you need to select a specific identity.
EOF
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

XCODEBUILD_ARGUMENTS=(
  -project "$DESKTOP_DIR/ConductorDesktop.xcodeproj"
  -scheme ConductorDesktop
  -configuration Release
  -destination "platform=macOS,arch=$HOST_ARCH"
  -onlyUsePackageVersionsFromResolvedFile
  -skipMacroValidation
  -skipPackagePluginValidation
  CODE_SIGNING_ALLOWED=NO
  ARCHS="$HOST_ARCH"
  ONLY_ACTIVE_ARCH=YES
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

TARGET_BUILD_DIR="$(
  xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" -showBuildSettings \
    | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / && !found { print $2; found = 1 }'
)"

if [[ -z "$TARGET_BUILD_DIR" ]]; then
  echo "Xcode did not report a target build directory." >&2
  exit 1
fi

APP="$TARGET_BUILD_DIR/$APP_NAME.app"
xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" build | xcbeautify

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

ditto "$APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$OUTPUT_DIR"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG"

codesign \
  --force \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$DMG"

xcrun notarytool submit \
  "$DMG" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

echo "Release ready: $DMG"
