#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  source "$HOME/.nvm/nvm.sh"
fi

if [[ $# -ne 2 ]]; then
  echo "Usage: build-bridge-resources.sh <app-contents-directory> <configuration>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_CONTENTS="$1"
CONFIGURATION="$2"
BRIDGE_DIR="$DESKTOP_DIR/Bridge"
PROXY_DIR="$BRIDGE_DIR/Proxy"
INSTALLER_DIR="$BRIDGE_DIR/Installer"

pnpm --dir "$PROXY_DIR" install --frozen-lockfile
pnpm --dir "$PROXY_DIR" run build

CARGO_ARGUMENTS=(
  build
  --manifest-path "$INSTALLER_DIR/Cargo.toml"
  --bin conductor-bridge-installer
)
CARGO_PROFILE=debug
if [[ "$CONFIGURATION" == Release ]]; then
  CARGO_ARGUMENTS+=(--release)
  CARGO_PROFILE=release
fi
cargo "${CARGO_ARGUMENTS[@]}"

HELPERS="$APP_CONTENTS/Helpers"
PROXY_RESOURCES="$APP_CONTENTS/Resources/sidecar-proxy"
mkdir -p "$HELPERS" "$PROXY_RESOURCES/dist"
install -m 755 \
  "$INSTALLER_DIR/target/$CARGO_PROFILE/conductor-bridge-installer" \
  "$HELPERS/conductor-bridge-installer"
install -m 755 \
  "$PROXY_DIR/conductor-runtime" \
  "$PROXY_RESOURCES/conductor-runtime"
install -m 644 \
  "$PROXY_DIR/dist/runtime-proxy.mjs" \
  "$PROXY_RESOURCES/dist/runtime-proxy.mjs"
