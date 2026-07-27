# Conductor Cloud: connect and browse

This slice adds the smallest usable Conductor Cloud path to the iOS app:

- Settings validates candidate API keys against `GET /me`.
- Valid keys are saved, replaced, loaded, and deleted through Keychain.
- A non-secret `cloud-credential-configured.json` marker controls whether the
  app should attempt Keychain and Cloud API access after relaunch.
- A non-secret account identifier lets the app reconcile cached rows when a
  credential is replaced.
- Either a local Mac pairing or a configured Cloud credential satisfies the
  first-launch connection gate; neither one depends on the other.
- The Cloud catalog follows project and workspace pagination, then loads
  workspace lifecycle status independently.
- Cloud API results are cached in the mobile SQLite database as canonical
  workspace and repository rows. A small mobile-only metadata row records
  Cloud provenance, lifecycle detail, and catalog reconciliation state.
- The existing `WorkspaceWithRepository` query left-joins desktop observation
  state and Cloud metadata, so every workspace follows the same
  `WorkspaceRow` rendering path.
- When the paired companion and Cloud API both observe the same workspace,
  there is one canonical row. Desktop observation enriches it with working and
  pull-request state while Cloud metadata supplies lifecycle state.
- Cached API-only workspaces survive relaunch and offline refresh failures.
  They remain display-only until the desktop companion observes the same ID.
- Replacing a credential removes rows owned only by another Cloud account.
  Deleting a credential, or discovering that its Keychain item is missing,
  removes API-only cached rows while retaining desktop-observed rows.

The transport difference remains below feature UI: local workspaces continue
to arrive as companion WebSocket snapshots, while cloud workspaces arrive
through an injected HTTP client. Both write their source-specific fields into
the same mobile persistence layer; `Workspaces` reads one typed query and owns
only transient loading and error state for the Cloud refresh.

This slice intentionally does not add Cloud navigation, chat, transcript
mapping or polling, send/cancel behavior, workspace creation, or additional
session creation. Cloud rows are display-only.

Run the end-to-end Cloud browse interaction test with:

```sh
mise -C ios run ui-test
```

The test creates and removes its own simulator. It launches the app with typed
database fixtures, verifies lifecycle, working, and draft pull-request status,
confirms that API-only rows stay display-only, navigates into locally observed
rows, opens Settings, types an intentionally invalid API key, and observes the
real Cloud API authentication error.

The original full spike, including later-slice work, is recoverable from
`origin/checkpoint/full-cloud-spike-2026-07-27` at commit
`f82912740e8e55e152662df380f7b5b077dae330`. Its third parent contains the
files that were untracked when the checkpoint was made.
