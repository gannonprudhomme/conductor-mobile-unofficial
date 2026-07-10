#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: worktree-sim.sh <destination|clean>

Commands:
  destination  Print an xcodebuild destination for this worktree's simulator.
  clean        Delete this worktree's simulator.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if REPO_ROOT="$(git -C "$IOS_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
fi
WORKTREE_NAME="$(basename "$REPO_ROOT")"
BRANCH_NAME="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
BRANCH_NAME="${BRANCH_NAME:-$WORKTREE_NAME}"
SIMULATOR_SUFFIX=" ($WORKTREE_NAME)"
SIMULATOR_NAME="${CONDUCTOR_SIMULATOR_NAME:-$BRANCH_NAME$SIMULATOR_SUFFIX}"
SIMULATOR_DEVICE_TYPE="${CONDUCTOR_SIMULATOR_DEVICE_TYPE:-iPhone 17}"

simulator_ids() {
  local args=(devices)

  if [[ "${1:-}" == "available" ]]; then
    args+=(available)
  fi

  xcrun simctl list "${args[@]}" |
    awk -v exact="    $SIMULATOR_NAME (" -v marker="$SIMULATOR_SUFFIX (" '
      (index($0, exact) == 1 || index($0, marker) > 0) && match($0, /\([0-9A-F-]{36}\)/) {
        print substr($0, RSTART + 1, 36)
      }
    '
}

destination() {
  local simulator_id
  simulator_id="$(simulator_ids available | head -n 1)"

  if [[ -z "$simulator_id" ]]; then
    simulator_id="$(xcrun simctl create "$SIMULATOR_NAME" "$SIMULATOR_DEVICE_TYPE")"
    echo "created simulator $SIMULATOR_NAME ($simulator_id)" >&2
  fi

  printf 'id=%s\n' "$simulator_id"
}

clean() {
  local delete_output simulator_id simulator_ids_output
  simulator_ids_output="$(simulator_ids)"

  for simulator_id in $simulator_ids_output; do
    xcrun simctl shutdown "$simulator_id" 2>/dev/null || true

    if delete_output="$(xcrun simctl delete "$simulator_id" 2>&1)"; then
      echo "deleted simulator $SIMULATOR_NAME ($simulator_id)" >&2
    elif simulator_ids | grep -Fqx "$simulator_id"; then
      echo "$delete_output" >&2
      exit 1
    fi
  done
}

case "${1:-}" in
  destination)
    destination
    ;;
  clean)
    clean
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "error: unexpected command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
