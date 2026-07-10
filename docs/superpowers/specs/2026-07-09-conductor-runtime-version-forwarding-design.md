# Conductor 0.74 Runtime Version Forwarding

## Problem

Conductor 0.74 verifies its bundled runtime by invoking
`.internal/conductor-runtime --version` before copying the runtime into
Application Support. The bridge installer replaces that bundled binary with a
wrapper, but stores `conductor-runtime.real` only in Application Support. The
bundled wrapper therefore exits because it cannot find an adjacent real
runtime, and Conductor reports that the runtime could not be verified.

## Design

Keep the existing runtime proxy architecture. When the wrapper receives
`--version` and its adjacent `conductor-runtime.real` is absent, forward the
command to:

`~/Library/Application Support/com.conductor.app/bin/.internal/conductor-runtime.real`

All other behavior remains unchanged. The Application Support wrapper keeps
using its adjacent real runtime, and only the `sidecar` subcommand starts the
Node proxy. The wrapper must execute the genuine runtime rather than print a
hard-coded version so the result stays correct across Conductor updates.

Stage updates to `conductor-runtime.real` at a temporary path and atomically
rename them into place. This avoids overwriting a signed executable inode while
an existing sidecar may still have it mapped.

If neither real runtime exists, preserve the current explicit error and exit
status. Do not add version parsing, persistent metadata, or another service.

## Verification

1. Build and syntax-check the sidecar proxy.
2. Exercise the repository wrapper from a temporary app-bundle-like directory
   and confirm `--version` reaches the genuine runtime fallback.
3. Install the bridge and relaunch Conductor once.
4. Confirm Conductor no longer reports runtime verification failure, the
   bridge `/status` endpoint is reachable, and the real sidecar connection is
   active.
5. If Conductor still rejects the bundled wrapper, uninstall immediately and
   investigate a non-runtime interception point instead of weakening its
   verification.
