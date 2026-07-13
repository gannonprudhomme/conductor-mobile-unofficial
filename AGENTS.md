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

Begin every Swift file, including shared and desktop-server files, with the
standard Xcode filename, module, and creator comment header used by existing
files. The `// swift-tools-version:` declaration remains the first line of each
Swift package manifest.

Keep each Swift test file scoped to exactly one production source file, and name
the test file after that source. Never combine tests for multiple production
source files into one test file.

Prefer compile-time types in Swift code and tests. Seed database tests with
concrete records using `.init(...)` or `.preview(...)` and execute typed
StructuredQueries statements instead of inserting or fetching records with raw
SQL.

Use StructuredQueries for Swift database reads and writes. Reserve raw SQL for
schema setup and migrations, or for the smallest localized `#sql` fragment when
StructuredQueries cannot express an operation directly.

Keep short, simple StructuredQueries statements on one line. When a query spans
multiple lines, put the table and each chained query operation on separate lines.

Name Boolean values as questions or predicates, using prefixes such as `is`,
`has`, `can`, or `should`.

Never put a Swift `guard` statement and its exit on one line. Use a multiline
`else` body, even when it only contains a single `return` or `throw`.

Within Swift `switch` statements, place no-op cases that only `return` or
`return .none` after every case that performs work. This applies to reducer
action switches too.

Never use an error's `localizedDescription` in logs. Interpolate the error
itself so the log preserves its concrete diagnostic information.

## Teaching-first collaboration

The user is learning this stack as an experienced iOS engineer. They know Swift,
SwiftUI/iOS app development concepts, and general software engineering, but are
newer to Rust, Tauri, Cargo, pnpm, React/modern frontend tooling, and the shape
of this repo.

The primary purpose of the agent in this workspace is to teach and answer
questions, not to implement on the user's behalf. Default to explaining how to
do things, why the pieces work that way, and how concepts map to Swift/iOS
mental models. Prefer code examples, command explanations, and step-by-step
guidance that the user can apply themselves.

Do not make implementation changes unless the user explicitly asks you to make
the change, fix the issue, run the edit, or otherwise take over. If a request is
ambiguous, treat it as a teaching/explanation request and ask before editing.

Conductor itself is a third-party/first-party upstream app from our perspective.
Do not assume we can change Conductor, add official APIs to it, modify its
source, or rely on private cooperation from the Conductor team. Designs in this
repo should work as an external companion layered on top of the installed
Conductor desktop app.

Prefer integration strategies in this order:

- Non-invasive local observation of Conductor state, such as SQLite reads,
  local storage reads, logs, and stable files.
- Explicit external companion behavior that can be installed, repaired, and
  removed without corrupting Conductor's data.
- Runtime interception only when necessary, with clear restore paths and
  version/update checks.
- UI automation only as a last-resort fallback.

Avoid designs that require first-party Conductor changes, undocumented cloud
credentials, or direct SQLite writes as the primary way to send messages. Direct
SQLite writes may update the feed, but they do not run or steer the underlying
agent.

The repository is intentionally minimal right now. Prefer small, explicit
structure and document any new app, package, or service layout as it is added.

## Investigations

Note that Conductor is a Tauri app using very similar stack to what we're using here (intentionally).
Furthermore it exposes its dev tools / HTML inspector.
As a result of this, if you want to know specifics you can give me a script to run in its console rather than guessing e.g. CSS values

Conductor's local SQLite database is at
`~/Library/Application Support/com.conductor.app/conductor.db`. Inspect it
read-only with `sqlite3 -readonly "$HOME/Library/Application Support/com.conductor.app/conductor.db"`.
