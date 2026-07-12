#!/bin/sh

set -eu

desktop_root=$(cd "$(dirname "$0")/.." && pwd)
package_root="$desktop_root/SwiftServer"
configuration=${1:-release}
target=$(rustc -vV | sed -n 's/^host: //p')

swift build --package-path "$package_root" --configuration "$configuration"
swift_bin_dir=$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)

mkdir -p "$desktop_root/src-tauri/binaries"
install -m 755 \
  "$swift_bin_dir/conductor-mobile-server" \
  "$desktop_root/src-tauri/binaries/conductor-mobile-server-$target"
