# Conductor Mobile Proxy desktop app

The desktop companion is a native SwiftUI macOS app. Its window and mobile
server run in one Swift process. The bridge installer remains a small one-shot
Rust helper so the existing install, repair, status, and removal behavior does
not need to be rewritten in Swift.

The source boundaries are:

- `ConductorDesktop/`: the macOS app entry point and SwiftUI window.
- `Sources/ConductorBridge/`: the Swift client that invokes the bundled helper.
- `Sources/ConductorMobileServer/`: the HTTP and WebSocket server plus
  Conductor database access used by the phone.
- `Bridge/Installer/`: the retained Rust installer logic and CLI. It is a plain
  Cargo executable; no Rust window or app shell remains.
- `Bridge/Proxy/`: the narrow TypeScript/Node runtime proxy installed into
  Conductor.

The previous React, Vite, and Tauri app layers have been removed. Rust remains
only where it avoids rewriting the already-tested bridge installation behavior.

## Development

From the repository root:

```sh
mise run desktop
mise run xcode
```

Or, from this directory:

```sh
mise run build
mise run run
```

XcodeGen creates `ConductorDesktop.xcodeproj`. The app build compiles the
JavaScript runtime proxy and Rust installer helper, embeds both bridge assets,
and links the Swift bridge and server libraries directly into the app. The app is
intentionally unsandboxed because installation modifies the external
`/Applications/Conductor.app` bundle.

The Swift server listens on `0.0.0.0:3768` and opens Conductor's SQLite database
through a single queue. Mobile state arrives through resource-scoped WebSocket
streams; while a phone is subscribed, the server checks SQLite's `data_version`
every 3 milliseconds and only sends a new full snapshot when the queried
resource changes. Repository icons and message commands remain HTTP routes.
`PATCH /workspaces/{workspaceID}` accepts any combination of `unread`, `pinned`,
and `status`. The SwiftUI window polls the Rust helper for bridge status every
500 ms. The helper preserves the existing install, uninstall, and reachability
behavior.

Run the shared-model and Swift-server tests from the repository root:

```sh
swift test --package-path shared
swift test --package-path desktop
cargo test --manifest-path desktop/Bridge/Installer/Cargo.toml
pnpm --dir desktop/Bridge/Proxy run test
```

The build currently targets the Mac that runs it. A distributable universal app
will need arm64 and x86_64 slices for both the Swift app and Rust helper.
