# Conductor Cloud: connect and browse

This slice adds the smallest usable Conductor Cloud path to the iOS app:

- Settings validates candidate API keys against `GET /me`.
- Valid keys are saved, replaced, loaded, and deleted through Keychain.
- One optional, non-secret Cloud configuration records the last validated
  account and lets the app reconcile cached rows when a credential is replaced.
- Either a local Mac pairing or a configured Cloud credential satisfies the
  first-launch connection gate; neither one depends on the other.
- The Cloud observer follows project and workspace pagination, then loads
  coarse workspace status independently.
- Cloud API results are cached in the mobile SQLite database as canonical
  workspace and repository rows. A small mobile-only metadata row records
  Cloud provenance and catalog reconciliation state.
- The existing `WorkspaceWithRepository` query left-joins desktop observation
  state and Cloud metadata, so every workspace follows the same
  `WorkspaceRow` rendering path.
- When the paired companion and Cloud API both observe the same workspace,
  there is one canonical row. Desktop observation enriches it with working and
  pull-request state while Cloud supplies coarse workspace state.
- Cached API-only workspaces survive relaunch and offline refresh failures.
  They remain display-only until the desktop companion observes the same ID.
- Replacing a credential removes rows owned only by another Cloud account.
  Deleting a credential, or discovering that its Keychain item is missing,
  removes API-only cached rows while retaining desktop-observed rows.

The transport difference remains below feature UI: local workspaces continue
to arrive as companion WebSocket snapshots, while cloud workspaces arrive
through an injected HTTP client. Both observation loops write their
source-specific fields into the same mobile persistence layer; `Workspaces`
reads one typed query and owns their independent connection state.

The [official Conductor API](https://www.conductor.build/docs/api#endpoints)
offers offset-based list endpoints rather than an incremental workspace change
feed. The client therefore paginates projects and workspaces from offset zero
after each completed polling cycle, combines them with cached workspace
statuses, and emits a snapshot only when that combined value changes. Active
and unknown statuses refresh every 2.5 seconds; stable statuses refresh every
10 seconds. Polls never overlap, and status requests are limited to eight at a
time.

This slice intentionally does not add Cloud navigation, chat, transcript
mapping or polling, send/cancel behavior, workspace creation, or additional
session creation. Cloud rows are display-only.

Run the end-to-end Cloud browse interaction test with:

```sh
mise -C ios run ui-test
```

The tests create and remove their own simulator. They launch the app with typed
database and transport fixtures, verify the connected/loading/failed navigation
subtitle states, working and draft pull-request status, confirm that
API-only rows stay display-only, and navigate into locally observed rows. They
also cover Cloud-only and Local-only presentation, the observation
authentication alert, the Cloud-first Settings layout, and replacement-key
validation through the Settings Save action.

The original full spike, including later-slice work, is recoverable from
`origin/checkpoint/full-cloud-spike-2026-07-27` at commit
`f82912740e8e55e152662df380f7b5b077dae330`. Its third parent contains the
files that were untracked when the checkpoint was made.
