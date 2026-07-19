# Conductor Mobile Companion desktop app

The desktop companion is a native SwiftUI macOS app. Its window and mobile
server run in one Swift process.

The source boundaries are:

- `ConductorDesktop/`: the macOS app entry point and SwiftUI window.
- `Sources/ConductorMobileServer/`: the HTTP and WebSocket server plus
  Conductor database access used by the phone.
- `workspace-hook/`: the saved-snippet loader and browser module that call
  Conductor's loaded frontend services.

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

XcodeGen creates `ConductorDesktop.xcodeproj`. The app bundles
`bootstrap-loader.js` and `browser-hook.mjs` as direct resources. It remains
unsandboxed because it reads Conductor's database outside its own container and
serves the mobile API.

The companion runs the mobile API on `0.0.0.0:3768` and the Workspace UI Hook
on a separate loopback-only listener at `127.0.0.1:3769`. Both ports are fixed.

The macOS window reports whether Conductor's browser is connected and lets the
user copy the loader. Each run makes one cache-busted import of the current
bundled hook. The hook keeps native `EventSource` reconnection.

Message sends and stops use correlated commands through Conductor's loaded
message-processing controller. `sent` messages call `sendMessageImmediately`,
`queued` messages call `enqueueMessage`, and stops call `cancelSession`. The
browser reports explicit command acceptance or rejection through
`POST /workspace-ui-hook/command-result`.

Message sends wait for bounded browser acceptance. If the callback is lost,
the API reports delivery as unknown so clients can inspect the conversation
before retrying. Stop requests hold the serialized UI-mutation slot until
SQLite reports a non-working canonical session or the shared command deadline
expires.

`PATCH /workspaces/{workspaceID}` accepts exactly one of `unread`, `pinned`, or
`status`. While the hook is connected, it sends a one-way SSE command and waits
for the requested SQLite state. A StructuredQueries SQLite fallback is allowed
only when the command was definitely not delivered. Once a command is enqueued,
an ambiguous failure never falls back.

Mobile state arrives through resource-scoped WebSocket streams backed by
SQLite observation. Run the desktop checks from the repository root:

```sh
swift test --package-path desktop
node --test desktop/workspace-hook/browser-hook.test.mjs
```

When upgrading from a proxy-based release, uninstall the proxy with the old
companion and restart Conductor first. If the old runtime was not restored,
reinstall Conductor before using this companion.
