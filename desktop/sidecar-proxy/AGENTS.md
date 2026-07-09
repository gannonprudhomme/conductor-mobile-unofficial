# Sidecar Proxy Notes

This directory contains the small Node/TypeScript proxy that sits between the
installed Conductor desktop app and the real `conductor-runtime` sidecar.

Keep this proxy narrow. It exists only to preserve Conductor's normal sidecar
traffic while providing a minimal `/message` injection path for the local
companion app. Do not move pairing, mobile auth, SQLite reads, session browsing,
streaming UI, or broader product logic into this directory.

## How It Works

`runtime-proxy.mts` is compiled to plain Node ESM because the installed
Conductor runtime wrapper runs JavaScript directly.

Startup flow:

- Conductor starts this wrapper instead of the real runtime.
- The wrapper spawns `conductor-runtime.real` with Conductor's original args.
- The real runtime creates its own Unix socket, named from its process id.
- The proxy creates a public Unix socket, named from the proxy process id.
- The proxy suppresses the real `SOCKET_PATH=` stdout line and prints its own
  `SOCKET_PATH=` line instead, so Conductor connects to the proxy.

Runtime flow:

- Bytes from Conductor are forwarded to the real sidecar unchanged.
- Lines from the real sidecar are parsed as newline-delimited JSON when
  possible.
- Replies matching an injected `/message` JSON-RPC id are returned to that HTTP
  caller.
- All other sidecar messages are forwarded back to Conductor unchanged.
- Non-JSON sidecar output is forwarded back to Conductor instead of being
  treated as a proxy error.

Control API:

- `GET /status` writes and returns the current info file.
- `POST /message` validates a JSON body, builds the reverse-engineered
  SidecarV2 `query` JSON-RPC request, writes it to the active real-sidecar
  socket, and waits for the matching response id.

## Editing Rules

- Keep the source as a single `runtime-proxy.mts` unless there is a clear second
  caller or a large independent protocol surface. The current one-file shape is
  intentional and easier to debug.
- Preserve transparent forwarding. Normal Conductor traffic should not be
  modified, delayed, or reinterpreted unless it is the exact response to an
  injected request.
- Do not write directly to Conductor's SQLite database as a send path. SQLite
  writes may affect persisted feed state but do not steer the live agent.
- Do not require first-party Conductor changes, private cloud credentials, or
  cooperation from the Conductor app.
- If changing `buildQueryRequest`, keep the wire shape compatible with observed
  Conductor `query` messages unless the caller contract is deliberately updated.
- When writing injected messages, hold a local socket reference and handle both
  synchronous and callback write failures. A dead socket should fail the HTTP
  request promptly, not wait for the 120 second timeout.
- Keep comments for Conductor-specific behavior and failure modes. Avoid
  call-graph comments that only restate function names.

## Files And Outputs

- `runtime-proxy.mts`: source entrypoint and all proxy logic.
- `tsconfig.json`: sidecar-proxy-only TypeScript build config.
- `dist/runtime-proxy.mjs`: generated build output; do not hand edit.

Build and syntax-check from `desktop/`:

```sh
pnpm build:sidecar-proxy
node --check sidecar-proxy/dist/runtime-proxy.mjs
```
