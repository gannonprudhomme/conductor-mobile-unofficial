#!/bin/sh

set -eu

# `tauri dev` runs the Cargo executable directly instead of launching a macOS
# app bundle. The Dock therefore shows the Cargo target name and ignores
# Tauri's productName/mainBinaryName. All other Tauri commands pass through.
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/tauri.sh"
name='Conductor Mobile Proxy (unofficial)'

# Cargo calls this branch as its macOS runner. Executing the same binary from
# an ignored development .app lets Launch Services read our friendly name from
# Info.plist without changing Cargo, release builds, or the shared mise task.
if [ "${1:-}" = __runner ]; then
  binary=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
  sidecar="$(dirname "$binary")/conductor-mobile-server"
  shift 2

  bundle="$(dirname "$binary")/.tauri-dev/$name.app"
  executable="$bundle/Contents/MacOS/$name"

  mkdir -p "$bundle/Contents/MacOS"
  cp "$root/src-tauri/Info.plist" "$bundle/Contents/Info.plist"
  rm -f "$executable"
  install -m 755 "$binary" "$executable"
  install -m 755 "$sidecar" "$bundle/Contents/MacOS/conductor-mobile-server"

  exec "$executable" "$@"
fi

if [ "${1:-}" = dev ] && [ "$(uname -s)" = Darwin ]; then
  web_port=${CONDUCTOR_PORT:-1420}
  server_port=3768
  export CONDUCTOR_MOBILE_SERVER_PORT=$server_port

  for port in "$web_port" "$server_port"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Cannot start Tauri development: port $port is already in use:" >&2
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2
      exit 1
    fi
  done

  # Tauri runs its Cargo process at the same time as beforeDevCommand. Build
  # the proxy and Swift sidecar first so neither can be stale when Vite starts.
  (
    cd "$root"
    pnpm build:sidecar-proxy
    pnpm build:swift-server:debug
  )

  runner="$script __runner"
  export CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER=$runner
  export CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER=$runner

  dev_config=$(printf \
    '{"build":{"beforeDevCommand":"pnpm dev --port %s","devUrl":"http://localhost:%s"}}' \
    "$web_port" "$web_port")
  set -- "$@" --config "$dev_config"
fi

exec "$root/node_modules/.bin/tauri" "$@"
