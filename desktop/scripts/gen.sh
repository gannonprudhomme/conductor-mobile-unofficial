#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVED_PACKAGES_FILE="$DESKTOP_DIR/ConductorDesktop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

xcodegen generate --spec "$DESKTOP_DIR/project.yml" --project "$DESKTOP_DIR"
mkdir -p "$(dirname "$RESOLVED_PACKAGES_FILE")"
cp "$DESKTOP_DIR/Package.resolved" "$RESOLVED_PACKAGES_FILE"
