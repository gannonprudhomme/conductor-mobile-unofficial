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
- `workspace-hook/`: the saved-snippet loader and browser module that call
  Conductor's loaded workspace and session services.
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

XcodeGen creates `ConductorDesktop.xcodeproj`. The app build links the Swift
bridge and server libraries, bundles `bootstrap-loader.js` and
`browser-hook.mjs` as direct app resources, and independently builds the
optional runtime proxy and Rust installer helper. The app is intentionally
unsandboxed because runtime-proxy installation modifies the external
`/Applications/Conductor.app` bundle.

The companion runs the mobile API on `0.0.0.0:3768` and the Workspace UI Hook
on a separate loopback-only listener at `127.0.0.1:3769`.

Debug and test builds may set `CONDUCTOR_MOBILE_API_PORT`. The hook uses the
next port, so an override of `3778` produces `127.0.0.1:3779`. Invalid values
fail before either listener starts. Release builds always use `3768` and
`3769`, and the companion never reads `CONDUCTOR_PORT`.

The macOS window's Workspace UI Hook row reports whether Conductor's browser is
connected. Copy Loader is user initiated; its information button explains how
to save and rerun the loader as a Web Inspector Console Snippet. Each run makes
one cache-busted import of the current bundled hook from the companion. The hook
keeps native `EventSource` reconnection; it does not substitute a WebSocket.

`PATCH /workspaces/{workspaceID}` accepts exactly one of `unread`, `pinned`, or
`status`. While the hook is connected, the broker sends a one-way SSE command
and returns `204 No Content` once Conductor's SQLite state reflects the requested
value. A StructuredQueries SQLite fallback is allowed only when the command was
definitely not delivered and returns `202 Accepted`. Once a command has been
enqueued, timeout or disconnection is ambiguous and never falls back.

Mobile state still arrives through resource-scoped WebSocket streams. While a
phone is subscribed, the server observes SQLite's `data_version` and the shared
queue's `totalChangesCount` every 3 milliseconds, then sends a full snapshot
only when that resource changes. The polling interval begins after persistence;
it is not a tap-to-UI latency guarantee. Repository icons and message commands
remain HTTP routes. The SwiftUI window polls the Rust helper for bridge status
every 500 ms. The helper preserves the existing install, uninstall, and
reachability behavior.

Run the shared-model and Swift-server tests from the repository root:

```sh
swift test --package-path shared
swift test --package-path desktop
cargo test --manifest-path desktop/Bridge/Installer/Cargo.toml
pnpm --dir desktop/Bridge/Proxy run test
node --test desktop/workspace-hook/browser-hook.test.mjs
```

The build currently targets the Mac that runs it. A distributable universal app
will need arm64 and x86_64 slices for both the Swift app and Rust helper.
