# Rename Workspace Branch

## Goal

Let a user rename the actual Git branch for the current workspace from the workspace chat menu. Conductor must perform the rename so its Git state and persisted workspace state remain consistent.

## User experience

- Add a **Rename branch** item to the workspace chat overflow menu.
- Use the Lucide pencil icon for the menu item.
- Present a native alert titled **Rename branch** with a text field prefilled from the workspace's current branch.
- Provide **Cancel** and **Rename** actions.
- Trim surrounding whitespace and do not submit an empty or unchanged branch name.
- Dismiss the rename alert when the request begins.
- If Conductor rejects or cannot complete the rename, show an alert titled **Failed to rename branch** with the returned error message.
- Let existing workspace observation update the navigation title after a successful rename.

## Architecture and data flow

1. `WorkspaceChat` owns the rename draft, presentation state, request-in-flight state, and reducer actions.
2. `WorkspaceChatView` renders the menu item and the SwiftUI alert containing the text field.
3. `DesktopClient` sends the requested branch name to the existing workspace endpoint.
4. `ConductorMobileServer` validates the non-empty branch name and dispatches a rename command through `WorkspaceUIHook`.
5. The browser hook calls Conductor's existing `GitService.renameBranch` method, then marks the name as user-set through `WorkspaceService.markUserSetBranchName`.
6. The server completes the request only after Conductor's SQLite database reports the requested branch name.
7. The existing workspace WebSocket snapshot updates the mobile database and visible title.

The rename command has no direct-SQLite, raw-Git, or UI-automation fallback. If the Conductor UI hook is unavailable, the request fails without partially renaming state.

## Error handling

- Empty input is rejected before making a request.
- An unchanged name produces no request.
- Missing workspaces return the existing not-found response.
- UI-hook delivery, persistence timeout, Git validation, and Conductor service failures surface through the request and become the user-facing failure alert.
- The server continues to serialize this mutation with other workspace UI-hook mutations.

## Testing and release

- Reducer tests cover presenting and prefilling the alert, canceling, successful submission, unchanged or empty input, and request failure.
- Desktop-client tests cover the request body and response handling.
- Server tests cover decoding, validation, UI-hook dispatch, persistence waiting, and the lack of an unsafe fallback.
- Browser-hook tests verify the rename command calls Conductor's service with the expected arguments and preserves command ordering.
- Run the repository's focused JavaScript and Swift tests, the iOS test suite, and the iOS build.
- Visually inspect the menu item and rename alert in the iOS simulator.
- Upload the validated build using the repository's `mise -C ios run release -- --summary ...` workflow.
