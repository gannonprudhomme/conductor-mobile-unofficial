# Conductor Mobile

This repository is the starting point for a monorepo around mobile access to
[Conductor](https://conductor.build).

The planned shape is:

- A native SwiftUI iOS app for interacting with Conductor from a phone.
- A local Tauri desktop companion that keeps its React UI and bridge installer
  in Tauri/Rust while a bundled Swift server talks to the mobile app.

The service is expected to handle pairing or authentication, likely through a QR
code scanned from the phone, then pass messages between the mobile app and the
running Conductor app.

Conductor is a third-party upstream app from this repository's perspective. The
desktop companion should not assume first-party changes to Conductor. Keep the
integration surface narrow: read local state from SQLite/local storage, and use
a small SidecarV2 send bridge only for operations that must enter Conductor's
live runtime.

## Current prototype

- `ios/`: native iOS app scaffold. The app target is intentionally thin; app
  logic lives in local Swift package modules under `ios/Modules`. Run
  `mise -C ios run gen`, then open `ios/ConductorMobile.xcworkspace`.
- `shared/`: Swift package containing `ConductorFoundation` and the
  `SharedConductorData` models that match Conductor's desktop database and mobile API.
- `ios/Modules/Foundations/ConductorMobileData`: iOS-only networking,
  persistence, mobile workspace state, previews, and queries.
- `desktop/`: Tauri/React app and Rust bridge installer. Its bundled Swift
  sidecar in `desktop/SwiftServer` reads Conductor's database and serves the
  mobile API.
- `desktop/sidecar-proxy/runtime-proxy.mts`: small TypeScript
  proxy for the reverse-engineered message-send path. It compiles to `.mjs`
  because the installed Conductor runtime wrapper runs plain Node. It should
  stay send-only; SQLite reads, local-storage drafts, pairing, and streaming
  belong in the Swift mobile server.

Install the local iOS tooling with Homebrew if needed:

```sh
brew install mise xcodegen xcbeautify
```

Generate the iOS Xcode project with:

```sh
mise -C ios run gen
```

Build the iOS app with:

```sh
mise -C ios run build
```

That task runs XcodeGen first, then runs `xcodebuild` for the
`ConductorMobile` scheme and pipes the output through `xcbeautify`.

Build and syntax-check the proxy with:

```sh
cd desktop
pnpm build:sidecar-proxy
node --check sidecar-proxy/dist/runtime-proxy.mjs
```
