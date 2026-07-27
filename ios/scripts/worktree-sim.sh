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
CLOUD_WORKSPACE_ID=""

# Conductor's Mac mirror for a cloud workspace is a detached worktree whose
# directory is the workspace UUID. Recover the cloud branch and original
# workspace directory from Conductor's local database so Simulator gets the
# same useful title as it does for a local workspace.
if [[ -z "$BRANCH_NAME" && "$WORKTREE_NAME" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  CLOUD_WORKSPACE_ID="$WORKTREE_NAME"
  CONDUCTOR_DATABASE_PATH="${CONDUCTOR_DATABASE_PATH:-$HOME/Library/Application Support/com.conductor.app/conductor.db}"

  if [[ -f "$CONDUCTOR_DATABASE_PATH" ]] && command -v sqlite3 >/dev/null; then
    CONDUCTOR_WORKSPACE_METADATA="$(
      sqlite3 -readonly -separator $'\t' "$CONDUCTOR_DATABASE_PATH" \
        "SELECT COALESCE(branch, ''), COALESCE(workspace_path, '') FROM workspaces WHERE id = '$WORKTREE_NAME' LIMIT 1;" \
        2>/dev/null || true
    )"
    IFS=$'\t' read -r CONDUCTOR_BRANCH_NAME CONDUCTOR_WORKSPACE_PATH \
      <<< "$CONDUCTOR_WORKSPACE_METADATA"

    if [[ -n "$CONDUCTOR_BRANCH_NAME" ]]; then
      BRANCH_NAME="$CONDUCTOR_BRANCH_NAME"
    fi

    if [[ -n "$CONDUCTOR_WORKSPACE_PATH" ]]; then
      WORKTREE_NAME="$(basename "$CONDUCTOR_WORKSPACE_PATH")"
    fi
  fi
fi

BRANCH_NAME="${BRANCH_NAME:-$WORKTREE_NAME}"
SIMULATOR_SUFFIX=" ($WORKTREE_NAME)"
SIMULATOR_NAME="${CONDUCTOR_SIMULATOR_NAME:-$BRANCH_NAME$SIMULATOR_SUFFIX}"
SIMULATOR_DEVICE_TYPE="${CONDUCTOR_SIMULATOR_DEVICE_TYPE:-iPhone 17}"

current_simulator_ids() {
  local args=(devices)
  local match_suffix=true

  # Cloud workspaces for the same repository share an original directory name,
  # so their branch distinguishes their simulators.
  if [[ -n "$CLOUD_WORKSPACE_ID" ]]; then
    match_suffix=false
  fi

  if [[ "${1:-}" == "available" ]]; then
    args+=(available)
  fi

  xcrun simctl list "${args[@]}" |
    awk \
      -v exact="    $SIMULATOR_NAME (" \
      -v marker="$SIMULATOR_SUFFIX (" \
      -v match_suffix="$match_suffix" '
      (index($0, exact) == 1 || (match_suffix == "true" && index($0, marker) > 0)) &&
        match($0, /\([0-9A-F-]{36}\)/) {
        print substr($0, RSTART + 1, 36)
      }
    '
}

legacy_simulator_ids() {
  local args=(devices)

  if [[ -z "$CLOUD_WORKSPACE_ID" ]]; then
    return
  fi

  if [[ "${1:-}" == "available" ]]; then
    args+=(available)
  fi

  xcrun simctl list "${args[@]}" |
    awk -v exact="    $CLOUD_WORKSPACE_ID ($CLOUD_WORKSPACE_ID) (" '
      index($0, exact) == 1 && match($0, /\([0-9A-F-]{36}\)/) {
        print substr($0, RSTART + 1, 36)
      }
    '
}

simulator_ids() {
  current_simulator_ids "${1:-}"
  legacy_simulator_ids "${1:-}"
}

destination() {
  local simulator_id
  simulator_id="$(current_simulator_ids available | head -n 1)"

  if [[ -z "$simulator_id" ]]; then
    simulator_id="$(legacy_simulator_ids available | head -n 1)"

    if [[ -n "$simulator_id" ]]; then
      xcrun simctl rename "$simulator_id" "$SIMULATOR_NAME"
      echo "renamed simulator $SIMULATOR_NAME ($simulator_id)" >&2
    fi
  fi

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
