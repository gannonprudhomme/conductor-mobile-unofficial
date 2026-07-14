# Conductor Mobile Proxy desktop app

The desktop app keeps Tauri and React for its window and bridge installer. A
bundled Swift executable reads Conductor's database and serves the mobile API.

## Development

From this directory:

```sh
pnpm install
pnpm tauri dev
```

The development command builds React, the existing JavaScript runtime proxy,
and `conductor-mobile-server`. Tauri bundles the Swift executable as a sidecar,
starts it with the app, forwards its logs, and stops it when the app exits.

The Swift server listens on `0.0.0.0:3768` and opens Conductor's SQLite database
through a single queue. Mobile state arrives through resource-scoped WebSocket
streams; while a phone is subscribed, the server checks SQLite's `data_version`
every 25 milliseconds and only sends a new full snapshot when the queried
resource changes. Repository icons and message commands remain HTTP routes.
`PATCH /workspaces/{workspaceID}` accepts any combination of `unread`, `pinned`,
and `status`. The React UI continues to call the Rust bridge installer through
Tauri IPC; it does not communicate with Swift.

Run the shared-model and Swift-server tests from the repository root:

```sh
swift test --package-path shared
swift test --package-path desktop/SwiftServer
```

The build script currently targets the Mac that runs it. A distributable
universal app will need both arm64 and x86_64 Swift server slices.
