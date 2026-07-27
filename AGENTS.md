# Agent Notes

This is an early monorepo for Conductor mobile access. Keep changes aligned with
two planned pieces:

- A native SwiftUI iOS app for interacting with https://conductor.build.
- A local desktop service that pairs with the phone and controls or relays
  messages to the Conductor desktop app.

## Native iOS app

The native app lives in `ios/`. Follow `ios/AGENTS.md` for iOS-specific build,
module, architecture, and dependency rules.

## Shared Swift modules

Swift modules used by both iOS and desktop live in the standalone package under
`shared/`. Shared database records must match Conductor's actual schema; keep
mobile persistence, computed mobile state, UI, and lifecycle code in the iOS
package.

## Repository skills

Detailed Swift and iOS conventions live in repo-local skills under
`.agents/skills/`. Use every skill matching the work rather than relying on
memory or duplicating its rules in `AGENTS.md`.

- Use `$swift-style` for any Swift source or test file.
- Use `$swift-data` for records, persistence, database access, and typed queries.
- Use `$swift-testing` for Swift tests and test targets.
- Follow `ios/AGENTS.md` for the additional skills that apply under `ios/`.

## Investigations

Note that Conductor is a Tauri app even though this companion is a native SwiftUI
app. Conductor exposes its dev tools / HTML inspector.
As a result of this, if you want to know specifics you can give me a script to run in its console rather than guessing e.g. CSS values

Conductor's local SQLite database is at
`~/Library/Application Support/com.conductor.app/conductor.db`. Inspect it
read-only with `sqlite3 -readonly "$HOME/Library/Application Support/com.conductor.app/conductor.db"`.
