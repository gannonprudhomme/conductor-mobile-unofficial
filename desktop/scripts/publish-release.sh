#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: publish-release.sh <marketing-version>" >&2
  echo "Example: publish-release.sh 0.1.0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$1"
TAG="v$VERSION"
DMG="$DESKTOP_DIR/dist/Conductor-Mobile-Proxy-$VERSION.dmg"

gh auth status
"$SCRIPT_DIR/release.sh" "$VERSION"

gh release create \
  "$TAG" \
  "$DMG" \
  --draft \
  --generate-notes \
  --target "$(git -C "$DESKTOP_DIR" rev-parse HEAD)" \
  --title "Conductor Mobile Proxy $VERSION"
