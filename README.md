# Conductor Mobile

This repository is the starting point for a monorepo around mobile access to
[Conductor](https://conductor.build).

The planned shape is:

- A native SwiftUI iOS app for interacting with Conductor from a phone.
- A native SwiftUI macOS companion whose UI and mobile server share one process.
  It invokes the existing Rust bridge installer as a small helper executable.

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
  logic lives in local Swift package modules under `ios/Modules`.
- `shared/`: Swift package containing `ConductorFoundation`, the
  `SharedConductorData` models that match Conductor's desktop database and mobile API,
  and the colors and fonts shared by the iOS and macOS apps.
- `ios/Modules/Foundations/ConductorMobileData`: iOS-only networking,
  persistence, mobile workspace state, previews, and queries.
- `desktop/`: native SwiftUI macOS app plus separate Swift bridge-client and
  mobile-server modules. The server accesses Conductor's database and serves the
  mobile API from the app process.
- `desktop/Bridge/Installer/`: the retained Rust installer logic, packaged as a
  one-shot helper executable with no desktop UI framework.
- `desktop/Bridge/Proxy/runtime-proxy.mts`: small TypeScript
  proxy for the reverse-engineered message and stop paths. It compiles to `.mjs`
  because the installed Conductor runtime wrapper runs plain Node. It should
  stay control-only; SQLite access, local-storage drafts, pairing, and streaming
  belong in the Swift mobile server.

Install the local iOS tooling with Homebrew if needed:

```sh
brew install mise xcodegen xcbeautify
```

Generate both native projects and open them in Xcode with:

```sh
mise run xcode
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

Archive and upload the iOS app to TestFlight with its current marketing version:

```sh
mise run release
```

Pass a version to override `MARKETING_VERSION` for that upload:

```sh
mise run release 0.2.0
```

The release task uses the Apple account configured in Xcode for signing and
uploading. Xcode assigns the next App Store Connect build number. Uploads from
concurrent release tasks on the same Mac are serialized, while their archives
can build in parallel. The app record for
`com.gannonprudhomme.conductor-mobile-unofficial` must already exist in App
Store Connect.

Build and syntax-check the proxy with:

```sh
pnpm --dir desktop/Bridge/Proxy run build
node --check desktop/Bridge/Proxy/dist/runtime-proxy.mjs
```

Build and run the native macOS companion with:

```sh
mise run desktop
```
