# Conductor Cloud API Spike

## Decision: GO

Proceed with the additive P0 UI.

The isolated `ConductorCloud` module decodes every stable public envelope,
preserves arbitrary transcript content, keeps unknown server-owned status
values, constructs authenticated requests without exposing credentials, and
passes focused contract tests. Its transport and Keychain boundaries do not
depend on the local SQLite schema or desktop companion.

Live authentication, one project/workspace/session hierarchy, its status
endpoints, and a nonempty transcript are verified read-only. Send and cancel
remain covered by deterministic transport and reducer tests rather than
mutating a live workspace.

## Baseline architecture

- `ConductorMain.Main` owns the root `NavigationStack`, presents settings, and
  pushes local workspace chats.
- `ConductorWorkspaces` observes complete workspace snapshots from the desktop
  companion and reconciles them into the mobile SQLite database.
- `ConductorChat.WorkspaceChat` observes sessions for one local workspace.
  `ConductorChat.Chat` observes messages for the selected session, writes
  canonical rows to mobile SQLite, and projects them into stable chat rows.
- `ConductorMobileData.DesktopClient` is the injected mutation and observation
  boundary. Reads ultimately come from Conductor's local SQLite database through
  the desktop companion; sends and stops use the installed desktop UI hook.
- `ConductorSettings` persists the local desktop address and optional display
  metadata in application-support files.
- The chat feed is a UIKit collection view hosting SwiftUI rows. It owns stable
  diffable identity, bottom-follow behavior, viewport restoration, and
  content-only row reconfiguration.
- `ConductorDesign` and `SharedConductorDesign` provide the dark Conductor theme,
  typography, icons, controls, network progress, and agent-work progress.

The additive boundary is a new iOS-only cloud module containing transport
models plus the API, Keychain, and catalog dependencies. `ConductorChat.Chat`
is the single chat reducer and view for desktop and cloud sessions. It selects
the transport at its dependency boundary and converts cloud transcript events
into the same canonical `Message`, `Turn`, and collection-view rows used by
desktop chat. Cloud transport values are not written into the local Conductor
schema.

## Public API surface relevant to P0

The live OpenAPI document was fetched from
`https://api.conductor.build/v0/openapi.json` on 2026-07-24. It currently
identifies itself as `Roundhouse public API` version `0.0.1`; every endpoint
used by this spike is marked experimental.

- `GET /me`: validate authentication.
- `GET /v0/projects`: paginated projects.
- `GET /v0/projects/{projectId}/workspaces`: paginated cloud workspaces.
- `POST /v0/workspaces`: create a cloud workspace and first session from a
  project or repository URL.
- `GET /v0/workspaces/{workspaceId}`: fetch current workspace metadata.
- `GET /v0/workspaces/{workspaceId}/status`: workspace lifecycle.
- `GET /v0/workspaces/{workspaceId}/sessions`: paginated sessions.
- `GET /v0/sessions/{sessionId}/messages`: paginated transcript or incremental
  messages with `after`.
- `GET /v0/sessions/{sessionId}/status`: agent activity.
- `POST /v0/sessions/{sessionId}/messages`: enqueue a prompt.
- `POST /v0/sessions/{sessionId}/cancel`: idempotently cancel work and queued
  messages.

List responses are `{ data, offset, hasMore }`. Errors use a structured body
whose only required field is the human-readable `userMessage`.

## Schema uncertainties

- Transcript `content` has no OpenAPI schema and must remain lossless.
- Transcript `type`, lifecycle status, session status, and several other
  server-owned strings may gain new values.
- The contract describes `offset` and `sessionIndex` as JSON numbers, not
  explicitly integers.
- Workspace list items do not include lifecycle state; status requires another
  request.
- Session list items do not include activity state; status requires another
  request.
- A session can remain `idle` after a prompt is queued. Completion cannot be
  inferred until work or a relevant transcript update has been observed.

## Smallest credible vertical slice

1. Store one optional API key in Keychain while retaining local pairing.
2. Validate the key with `GET /me`.
3. Load all project/workspace pages and add API-only cloud rows to the existing
   workspace list without copying them into SQLite. Deduplicate cloud
   workspaces already observed from the paired Mac.
4. Open one workspace, load its lifecycle and sessions, then open one session.
5. Decode transcript envelopes losslessly and adapt understood user, assistant,
   tool, result, and error events into the canonical chat model.
6. Poll transcript and activity conservatively, send plain text with a client
   message ID, and cancel active work through the shared chat actions.
7. Add a cloud toggle to workspace creation when the selected repository can be
   represented by the public create contract.

This intentionally excludes additional-session creation, rename/archive, PR
review, terminal access, and background execution for API-only workspaces.

## Risks that trigger NO-GO

- Stable envelopes cannot be decoded from contract-valid fixtures without
  discarding unknown content.
- The API client cannot isolate credentials and a fixed production base URL.
- Cloud navigation requires local SQLite models or changes the desktop
  companion path.
- Accurate queued/working/settled behavior cannot be represented.
- The existing local build or tests regress after adding the isolated module.

## Baseline verification

Run before production Swift changes on 2026-07-24:

- `mise -C ios run build`: passed in 118.23 seconds.
- `mise -C ios run test`: passed all seven module schemes in 265.59 seconds.
- The test build emitted existing `UIWindow(frame:)` deprecation warnings in
  chat, workspace, and main tests.
- Root `mise run xcode` was not run because it opens the host Xcode application;
  `mise -C ios run build` performed project generation and the command-line app
  build without controlling a host window.

## Live verification so far

Using a valid API key without opting into mutation requests:

- `GET /me`: authentication succeeded with API-key authentication.
- `GET /v0/projects?limit=100&offset=0`: decoded one project in a valid
  pagination envelope.
- The project workspace page decoded one workspace, its session page decoded
  one session, and both status endpoints returned recognized states.
- The session message pages returned a nonempty transcript using PostgreSQL
  timestamp strings such as `2026-07-24 15:24:17.562275+00`.
- The observed envelope uses top-level `userMessage` and `agent` records. Agent
  events included assistant text, command execution, file changes, image views,
  MCP calls, reasoning, and protocol lifecycle events.
- Send and cancel were not exercised.

No account identifiers, repository names, transcript content, or credentials
were saved.

## Final architecture

The cloud implementation has four boundaries:

- `CloudAPIClient` owns the fixed official production URL, bearer
  authentication, typed stable envelopes, pagination, incremental transcript
  cursors, structured errors, and injectable test transport.
- `CloudCredentialClient` owns the API key in a
  `kSecClassGenericPassword` Keychain item. The only non-secret persisted cloud
  value is a Boolean marker used to decide whether cloud UI should load.
- `CloudWorkspaceCatalog` fetches cloud projects/workspaces and their lifecycle
  status. `ConductorWorkspaces` renders API-only rows in the existing list and
  deduplicates IDs already present in the local SQLite observation.
- `CloudWorkspaceFeature` owns API-only workspace/session navigation.
  `ConductorChat.Chat` is shared by desktop and cloud backends and owns the
  common feed, composer, send, stop, polling/observation, and row projection.

Conductor's installed desktop app already includes cloud-hosted workspaces in
its local database. A nonempty `hosting_server_url` identifies those local
rows and adds the dotted cloud badge. Every locally observed row continues
through the paired desktop backend, including cloud-hosted workspaces.
API-only catalog rows use the public cloud backend and are never inserted into
Conductor's or the mobile app's SQLite tables.

Workspace creation remains one surface. The Cloud toggle is available only
when a Keychain credential exists and the selected repository matches a cloud
project or has a URL accepted by the public create endpoint. Fast Mode is
disabled for cloud creation because the current contract does not accept it.

## State-model mapping

| Concern | State | Visual treatment |
| --- | --- | --- |
| Client request | initial load, refresh, send, cancel, polling failure | Native network `ProgressView`, retry, or stale warning |
| Workspace lifecycle | initializing, ready, sleeping, updating, archived, deleted, unknown | Cloud badge plus lifecycle text |
| Agent activity | idle, working, error, unknown | Conductor activity animation only for `working`; explicit error text |
| Turn delivery | sending, working, settled | Shared composer and activity controls |
| Transcript content | user, assistant, tools, result, error, unsupported | Canonical `Message` and `Turn` rows; unknown protocol events remain lossless at the transport boundary |

Polling uses the last confirmed server message ID with `after`. Active or
working sessions poll every 3 seconds and idle sessions every 8 seconds. The
polling effect is canceled when the view disappears.

## Files changed

- Configuration: `.gitignore`, `.conductor/settings.toml`.
- Project wiring: `ios/Modules/Package.swift`, `ios/project.yml`,
  `ios/scripts/test.sh`.
- New cloud module: `ios/Modules/ConductorCloud/Sources/` and
  `ios/Modules/ConductorCloud/Tests/`.
- Existing integration:
  `ios/Modules/ConductorSettings/Sources/ConductorSettings.swift`,
  `ios/Modules/ConductorSettings/Tests/ConductorSettingsTests.swift`,
  `ios/Modules/ConductorWorkspaces/Sources/`,
  `ios/Modules/ConductorWorkspaces/Tests/CreateWorkspaceTests.swift`,
  `ios/Modules/ConductorMain/Sources/MainView.swift`, and
  `ios/Modules/ConductorMain/Tests/MainTests.swift`.
- Design/data support:
  `ios/Modules/ConductorDesign/Sources/CloudWorkspaceIcon.swift` and
  `ios/Modules/Foundations/ConductorMobileData/Sources/Workspace/Workspace+Display.swift`.
- Public documentation: `README.md` and this file.

## Fixture-only verification

Synthetic tests cover:

- authorization/User-Agent headers, paths, query construction, cursor
  requests, multi-page loading, create/send bodies, and structured 401 errors;
- unknown statuses, fractional ISO-8601 dates, heterogeneous JSON content,
  unsupported transcript rows, ordering, and deduplication;
- mock Keychain load/save/delete;
- Settings connection testing and saving a cloud credential while still
  validating and preserving local pairing;
- cloud creation using a matching project;
- catalog loading and lifecycle separation;
- incremental polling, send failure and retry, queued-to-working-to-idle,
  immediate idle remaining queued, duplicate-prompt reconciliation, and
  idempotent cancellation;
- routing locally observed and API-known hosted workspaces to cloud chat.

All fixtures use synthetic IDs, URLs, and transcript text.

## Known API limitations

- The authenticated live account returned one project, workspace, and session,
  but no transcript messages. Nonempty transcript, send, and cancel behavior is
  not live verified.
- The public workspace contract does not expose the CPU and memory runtime
  statistics shown by the current desktop UI.
- The create endpoint has no Fast Mode field.
- Transcript content remains intentionally untyped beyond recognized text
  shapes.
- API status and transcript changes require polling; the public contract does
  not expose a push stream.

## Known app limitations

- Cloud rows that are not also observed from the paired Mac appear in a
  dedicated Cloud section of the same list rather than participating in
  Conductor's manual workflow-status groups, because the public API does not
  expose those manual statuses.
- Only the first session created with a cloud workspace is created here.
  Additional-session creation, rename, archive, and deep-link actions remain
  out of scope.
- Cloud transcript rendering covers plain user/assistant/error text and a safe
  fallback, not every rich tool or event shape used by the local chat.
- The Keychain API-key flow is appropriate for this prototype, not a
  production user-authentication system.

## Recommended next steps

1. Use an account with a disposable cloud project to run the guarded mutation
   smoke test and validate the real queued/working/reply/cancel sequence.
2. Compare sanitized real transcript shapes with the tolerant mapper and add
   only well-understood rows.
3. If runtime statistics become public, add them to the lifecycle header
   without conflating them with agent activity.
4. Consider merging API-only cloud rows into project/status grouping only if a
   future public field supplies Conductor's workflow status.

## Final command verification

Run during final validation on 2026-07-24:

- `mise -C ios run gen`: passed.
- `mise -C ios run build`: passed in 55.64 seconds.
- `mise -C ios run test`: passed all eight module schemes in 381.48 seconds,
  including 18 `ConductorCloudTests`.
- After the last naming-only simplification, `ConductorSettingsTests` and
  `ConductorMainTests` were rerun and passed again.
- The full test build emitted only the pre-existing `UIWindow(frame:)`
  deprecation warnings in chat, workspace, and main test targets.
- Root `mise run xcode` remained intentionally unrun because it opens the host
  Xcode application.
