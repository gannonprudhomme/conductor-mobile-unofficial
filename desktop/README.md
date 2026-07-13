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

The Swift server listens on `0.0.0.0:3768` and preserves the existing HTTP
routes. Its GET routes read Conductor's SQLite database, while its PATCH route
update workspace read, pin, and status metadata. `PATCH /workspaces/{workspaceID}`
accepts any combination of `unread`, `pinned`, and `status` in one request. The
React UI continues to call the Rust bridge installer through Tauri IPC; it does
not communicate with Swift.

Run the shared-model and Swift-server tests from the repository root:

```sh
swift test --package-path shared
swift test --package-path desktop/SwiftServer
```

The build script currently targets the Mac that runs it. A distributable
universal app will need both arm64 and x86_64 Swift server slices.
