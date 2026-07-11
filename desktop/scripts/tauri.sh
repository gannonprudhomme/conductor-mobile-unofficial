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
  shift 2

  bundle="$(dirname "$binary")/.tauri-dev/$name.app"
  executable="$bundle/Contents/MacOS/$name"

  mkdir -p "$bundle/Contents/MacOS"
  cp "$root/src-tauri/Info.plist" "$bundle/Contents/Info.plist"
  ln -sfn "$binary" "$executable"

  exec "$executable" "$@"
fi

if [ "${1:-}" = dev ] && [ "$(uname -s)" = Darwin ]; then
  runner="$script __runner"
  export CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER=$runner
  export CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER=$runner
fi

exec "$root/node_modules/.bin/tauri" "$@"
