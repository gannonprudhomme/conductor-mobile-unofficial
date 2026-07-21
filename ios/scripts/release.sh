#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: release.sh [marketing-version] [--summary summary]" >&2
  echo "Examples:" >&2
  echo "  release.sh 0.2.0" >&2
  echo "  release.sh 0.2.0 --summary 'Test the new workspace flow'" >&2
}

VERSION=""
SUMMARY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary)
      if [[ $# -lt 2 ]]; then
        echo "--summary requires a value." >&2
        usage
        exit 2
      fi
      SUMMARY="$2"
      shift 2
      ;;
    --summary=*)
      SUMMARY="${1#*=}"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Only one marketing version may be provided." >&2
        usage
        exit 2
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(git -C "$IOS_DIR" rev-parse --show-toplevel)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conductor-mobile-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -f "$REPO_DIR/.env.testflight.local" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env.testflight.local"
fi

app_store_connect_token() {
  if ! ASC_API_KEY_ID="$ASC_API_KEY_ID" \
    ASC_API_ISSUER_ID="$ASC_API_ISSUER_ID" \
    ASC_API_KEY_PATH="$ASC_API_KEY_PATH" \
    ruby -ropenssl -rjson -rbase64 <<'RUBY'
def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

now = Time.now.to_i
header = base64url(JSON.generate(alg: "ES256", kid: ENV.fetch("ASC_API_KEY_ID"), typ: "JWT"))
payload = base64url(
  JSON.generate(
    iss: ENV.fetch("ASC_API_ISSUER_ID"),
    iat: now,
    exp: now + 600,
    aud: "appstoreconnect-v1"
  )
)
unsigned_token = "#{header}.#{payload}"
key = OpenSSL::PKey::EC.new(File.read(ENV.fetch("ASC_API_KEY_PATH")))
der_signature = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned_token))
signature = OpenSSL::ASN1.decode(der_signature).value
  .map { |integer| integer.value.to_s(2).rjust(32, "\0") }
  .join
print "#{unsigned_token}.#{base64url(signature)}"
RUBY
  then
    echo "Could not generate an App Store Connect token." >&2
    return 1
  fi
}

app_store_connect_get() {
  local endpoint="$1"
  local response="$2"
  shift 2

  local token
  token="$(app_store_connect_token)"

  local status
  status="$(
    curl \
      --silent \
      --show-error \
      --globoff \
      --get \
      --output "$response" \
      --write-out '%{http_code}' \
      --header "Authorization: Bearer $token" \
      "$@" \
      "https://api.appstoreconnect.apple.com/v1/$endpoint"
  )"

  if [[ "$status" != 200 ]]; then
    echo "App Store Connect request failed with HTTP $status." >&2
    jq -r '.errors[0].detail // empty' "$response" >&2
    return 1
  fi
}

latest_build() {
  local version="$1"
  local response="$WORK_DIR/latest-build.json"

  app_store_connect_get builds "$response" \
    --data-urlencode "filter[app]=$APP_ID" \
    --data-urlencode "filter[preReleaseVersion.version]=$version" \
    --data-urlencode "sort=-uploadedDate" \
    --data-urlencode "limit=1"
  jq -r '.data[0] | select(.) | [.id, .attributes.processingState] | @tsv' "$response"
}

set_testflight_notes() {
  local build_id="$1"
  local notes="$2"
  local localizations="$WORK_DIR/testflight-localizations.json"
  local payload="$WORK_DIR/testflight-notes.json"
  local response="$WORK_DIR/testflight-notes-response.json"
  local endpoint="https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations"
  local expected_status=201
  local method=POST

  app_store_connect_get "builds/$build_id/betaBuildLocalizations" "$localizations"

  local localization_id
  localization_id="$(
    jq -r '[.data[] | select(.attributes.locale == "en-US")][0].id // empty' "$localizations"
  )"

  if [[ -n "$localization_id" ]]; then
    endpoint="$endpoint/$localization_id"
    expected_status=200
    method=PATCH
    jq --null-input --arg id "$localization_id" --arg notes "$notes" '{
      data: {
        type: "betaBuildLocalizations",
        id: $id,
        attributes: {whatsNew: $notes}
      }
    }' > "$payload"
  else
    jq --null-input --arg build_id "$build_id" --arg notes "$notes" '{
      data: {
        type: "betaBuildLocalizations",
        attributes: {locale: "en-US", whatsNew: $notes},
        relationships: {build: {data: {type: "builds", id: $build_id}}}
      }
    }' > "$payload"
  fi

  local token
  token="$(app_store_connect_token)"

  local http_status
  http_status="$(
    curl \
      --silent \
      --show-error \
      --output "$response" \
      --write-out '%{http_code}' \
      --request "$method" \
      --header "Authorization: Bearer $token" \
      --header "Content-Type: application/json" \
      --data-binary "@$payload" \
      "$endpoint"
  )"

  if [[ "$http_status" != "$expected_status" ]]; then
    echo "Could not set TestFlight notes (HTTP $http_status)." >&2
    jq -r '.errors[0].detail // empty' "$response" >&2
    return 1
  fi
}

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

if [[ -n "$VERSION" ]]; then
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

if [[ -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" ]]; then
  echo "TestFlight metadata requires ASC_API_KEY_ID and ASC_API_ISSUER_ID." >&2
  echo "Set them in $REPO_DIR/.env.testflight.local or in the environment." >&2
  exit 2
fi

ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_API_KEY_ID.p8}"
if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
  echo "App Store Connect API key not found at $ASC_API_KEY_PATH." >&2
  echo "Set ASC_API_KEY_PATH to the key's .p8 file." >&2
  exit 2
fi

AUTHENTICATION_ARGUMENTS=(
  -authenticationKeyPath "$ASC_API_KEY_PATH"
  -authenticationKeyID "$ASC_API_KEY_ID"
  -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
)
XCODEBUILD_ARGUMENTS+=("${AUTHENTICATION_ARGUMENTS[@]}")

APP_RESPONSE="$WORK_DIR/app.json"
app_store_connect_get apps "$APP_RESPONSE" \
  --data-urlencode "filter[bundleId]=com.gannonprudhomme.conductor-mobile-unofficial" \
  --data-urlencode "limit=1"

APP_ID="$(jq -r '.data[0].id // empty' "$APP_RESPONSE")"
if [[ -z "$APP_ID" ]]; then
  echo "The Conductor Mobile app was not found in App Store Connect." >&2
  exit 1
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

BRANCH="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD || git -C "$REPO_DIR" rev-parse --short HEAD)"
COMMIT_NOTES="$(git -C "$REPO_DIR" log -5 --format='- %s')"
TESTFLIGHT_NOTES="Branch: $BRANCH"$'\n'"$COMMIT_NOTES"
if [[ -n "$SUMMARY" ]]; then
  TESTFLIGHT_NOTES="$SUMMARY"$'\n'"$TESTFLIGHT_NOTES"
fi
printf 'TestFlight notes:\n\n%s\n\n' "$TESTFLIGHT_NOTES"

PREVIOUS_VERSION_BUILD="$(latest_build "$VERSION")"
IFS=$'\t' read -r PREVIOUS_BUILD_ID _ <<< "$PREVIOUS_VERSION_BUILD"

PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$WORK_DIR/Export" \
  -exportOptionsPlist "$IOS_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  "${AUTHENTICATION_ARGUMENTS[@]}" | xcbeautify

echo "Waiting for the uploaded build to finish processing..."
NEW_BUILD_ID=""
DEADLINE=$((SECONDS + 1200))
while (( SECONDS < DEADLINE )); do
  CURRENT_BUILD="$(latest_build "$VERSION")"
  if [[ -n "$CURRENT_BUILD" ]]; then
    IFS=$'\t' read -r CURRENT_BUILD_ID CURRENT_BUILD_STATE <<< "$CURRENT_BUILD"

    if [[ "$CURRENT_BUILD_ID" != "$PREVIOUS_BUILD_ID" ]]; then
      if [[ "$CURRENT_BUILD_STATE" == VALID ]]; then
        NEW_BUILD_ID="$CURRENT_BUILD_ID"
        break
      fi

      if [[ "$CURRENT_BUILD_STATE" == FAILED || "$CURRENT_BUILD_STATE" == INVALID ]]; then
        echo "The uploaded TestFlight build failed processing." >&2
        exit 1
      fi
    fi
  fi

  sleep 10
done

if [[ -z "$NEW_BUILD_ID" ]]; then
  echo "Timed out waiting for the uploaded TestFlight build." >&2
  exit 1
fi

set_testflight_notes "$NEW_BUILD_ID" "$TESTFLIGHT_NOTES"

echo "Uploaded $ARCHIVE to App Store Connect with TestFlight notes."
