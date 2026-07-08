# Agent Notes

This is an early monorepo for Conductor mobile access. Keep changes aligned with
two planned pieces:

- A React Native mobile app for interacting with https://conductor.build.
- A local desktop service that pairs with the phone and controls or relays
  messages to the Conductor desktop app.

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