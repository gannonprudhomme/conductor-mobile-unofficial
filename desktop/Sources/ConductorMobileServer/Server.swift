//
//  Server.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import HummingbirdWebSocket
import SharedConductorData
import SQLiteData

public enum Server {
    /// Runs the LAN mobile API and loopback browser-hook listener for the desktop companion.
    ///
    /// The executable calls this once. Both listeners retry independently so losing the browser
    /// hook does not take down mobile reads, and a transient bind failure does not exit the app.
    public static func run(
        databaseURL: URL,
        workspaceUIHookSource: String
    ) async throws {
        @Dependency(\.workspaceUIHook) var workspaceUIHookDependency
        let workspaceUIHook = workspaceUIHookDependency

        // Keep the LAN mobile API separate from the loopback-only browser hook.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await retryingServer(name: "conductor-mobile-api") {
                    let database = try ConductorDatabase.open(at: databaseURL)
                    let pullRequestCacheURL = databaseURL
                        .deletingLastPathComponent()
                        .appending(path: "local-storage.entries/git-service-pr-v1")
                    try await makeApplication(
                        database: database,
                        pullRequestCacheURL: pullRequestCacheURL
                    )
                    .run()
                }
            }

            group.addTask {
                try await retryingServer(name: "workspace-ui-hook") {
                    await workspaceUIHook.listenerUnavailable()
                } run: {
                    try await makeWorkspaceUIHookApplication(
                        hookSource: workspaceUIHookSource
                    )
                    .run()
                }
            }
            try await group.waitForAll()
        }
    }

    /// Builds the LAN API used by every mobile HTTP and WebSocket client endpoint.
    ///
    /// `run` starts the returned application; server tests call this directly with an isolated
    /// database and port. The message WebSocket route delegates its stateful protocol to
    /// `streamMessages`.
    static func makeApplication( // only non-private for tests
        database: DatabaseQueue,
        // Five seconds tolerates a slow Conductor UI command without holding the request indefinitely.
        uiCommandTimeout: Duration = .seconds(5),
        // Workspace creation can run setup and worktree scripts, so it gets a separate timeout.
        workspaceCreationTimeout: Duration = .seconds(300),
        userSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".conductor/settings.toml"),
        managedSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".conductor/settings.managed.toml"),
        port: Int = 3_768,
        allowedOrigin: String? = nil,
        pullRequestCacheURL: URL? = nil,
        workspacePollInterval: Duration = .seconds(1)
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)
        let webSocketRouter = Router(context: RequestContext.self)
        let databaseChanges = DatabaseChangeObserver(database: database)
        let workspaceSnapshots = DatabaseSnapshotCache<String, WorkspaceListSnapshot>()
        let sessionSnapshots = DatabaseSnapshotCache<String, [Session]>()
        let messageSnapshots = DatabaseSnapshotCache<String, TranscriptSnapshot>()

        router.get("/ping") { _, _ in
            HTTPResponse.Status.noContent
        }

        router.get("/settings") { request, context in
            let settings = try modelSettings(
                userSettingsURL: userSettingsURL,
                managedSettingsURL: managedSettingsURL
            )
            guard let settings else {
                throw HTTPError(.notFound)
            }
            return try JSONEncoder.conductor.encode(
                settings,
                from: request,
                context: context
            )
        }

        let shouldUpgradeToWebSocket: @Sendable (Request, RequestContext) async throws -> RouterShouldUpgrade = { request, _ in
            if originIsAllowed(request, allowedOrigin: allowedOrigin) {
                // Accept the HTTP-to-WebSocket switch and start the matching route handler.
                .upgrade()
            } else {
                // Keep the connection as HTTP; the WebSocket route handler never starts.
                .dontUpgrade
            }
        }

        #if canImport(AppKit)
        router.get("/repositories/{repositoryID}/icon") { request, context in
            try await IconRoute.response(
                request: request,
                context: context,
                database: database
            )
        }
        #endif

        router.post("/workspaces") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await WorkspaceRoute.post(
                request: request,
                context: context,
                database: database,
                creationTimeout: workspaceCreationTimeout,
                uiMutationTimeout: uiCommandTimeout
            )
        }

        router.patch("/workspaces/{workspaceID}") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await WorkspaceRoute.patch(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        webSocketRouter.ws("/workspaces", shouldUpgrade: shouldUpgradeToWebSocket) { inbound, outbound, _ in
            let loadSnapshot: @Sendable () async throws -> WorkspaceListSnapshot = {
                let (repositories, workspaces) = try await database.read { database in
                    let workspaces = try WorkspaceSnapshot.mostRecentlyUpdated.fetchAll(database)
                    return (
                        try Repository.orderedByDisplayOrder.fetchAll(database),
                        workspaces
                    )
                }
                return WorkspaceListSnapshot(
                    repositories: repositories,
                    workspaces: workspaces,
                    pullRequests: PullRequestCache.readConductorPRCacheJSON(
                        for: workspaces.map(\.workspace.id),
                        at: pullRequestCacheURL
                    )
                )
            }

            if pullRequestCacheURL == nil {
                try await streamSnapshots(
                    inbound: inbound,
                    outbound: outbound,
                    databaseChanges: databaseChanges,
                    snapshotCache: workspaceSnapshots,
                    snapshotKey: "workspaces",
                    loadSnapshot: loadSnapshot
                )
            } else {
                // Conductor updates its normalized PR cache independently of SQLite. Poll the
                // combined snapshot so both database and cache-only changes reach the phone.
                try await streamPolledSnapshots(
                    inbound: inbound,
                    outbound: outbound,
                    interval: workspacePollInterval,
                    loadSnapshot: loadSnapshot
                )
            }
        }

        webSocketRouter.ws(
            "/workspaces/{workspaceID}/sessions",
            shouldUpgrade: shouldUpgradeToWebSocket
        ) { inbound, outbound, context in
            let workspaceID = try context.requestContext.parameters.require("workspaceID")
            try await streamSnapshots(
                inbound: inbound,
                outbound: outbound,
                databaseChanges: databaseChanges,
                snapshotCache: sessionSnapshots,
                snapshotKey: workspaceID
            ) {
                try await database.read { database in
                    try Session.all(forWorkspaceID: workspaceID).fetchAll(database)
                }
            }
        }

        webSocketRouter.ws(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages",
            shouldUpgrade: shouldUpgradeToWebSocket
        ) { inbound, outbound, context in
            let workspaceID = try context.requestContext.parameters.require("workspaceID")
            let sessionID = try context.requestContext.parameters.require("sessionID")
            let requestedResumeCursor = resumeCursor(
                fromPercentEncodedQuery: context.request.uri.query.map { query in
                    String(query)
                }
            )
            try await streamMessages(
                inbound: inbound,
                outbound: outbound,
                databaseChanges: databaseChanges,
                requestedResumeCursor: requestedResumeCursor,
                snapshotCache: messageSnapshots,
                snapshotKey: "\(workspaceID)/\(sessionID)"
            ) {
                try await database.read { database in
                    TranscriptSnapshot(
                        messages: try Message
                            .all(forWorkspaceID: workspaceID, sessionID: sessionID)
                            .fetchAll(database)
                    )
                }
            }
        }

        router.patch(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.patch(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.post(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue/{messageID}/edit"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.beginEditing(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.post(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue/{messageID}/steer"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.steer(
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.patch(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue/{messageID}"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.finishEditing(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.delete(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue/{messageID}"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.delete(
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.post(
            "/workspaces/{workspaceID}/sessions/{sessionID}/messages/queue/resume"
        ) { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await QueueRoute.resume(
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        // Apply the same browser boundary to commands. The native app sends no Origin, while
        // browser JavaScript does, so an arbitrary webpage cannot mutate a workspace or session.
        router.post("/workspaces/{workspaceID}/sessions/{sessionID}/messages") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await MessageRoute.post(
                request: request,
                context: context,
                database: database,
                commandTimeout: uiCommandTimeout
            )
        }

        router.post("/workspaces/{workspaceID}/sessions") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await CreateSessionRoute.post(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.patch("/workspaces/{workspaceID}/sessions/{sessionID}") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await SessionRoute.patch(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        router.post("/workspaces/{workspaceID}/sessions/{sessionID}/stop") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await StopRoute.post(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: uiCommandTimeout
            )
        }

        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter),
            configuration: .init(
                address: .hostname("0.0.0.0", port: port),
                serverName: "Conductor Mobile Server"
            )
        )
    }

    /// Builds the loopback-only bridge that lets the desktop browser UI execute supported writes.
    ///
    /// `run` hosts this separately from the LAN API because its JavaScript and command-result
    /// endpoints must never be exposed to other devices.
    static func makeWorkspaceUIHookApplication( // only non-private for tests
        hookSource: String,
        port: Int = 3_769
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)
        let hookRevision = WorkspaceUIHookRoute.revision(for: hookSource)
        router.get("/workspace-ui-hook/hook.js") { request, _ in
            WorkspaceUIHookRoute.getHookFileContents(
                request: request,
                source: hookSource,
                revision: hookRevision
            )
        }
        router.get("/workspace-ui-hook/events") { request, _ in
            await WorkspaceUIHookRoute.events(
                request: request,
                revision: hookRevision
            )
        }
        // A JSON POST from Conductor's `tauri://localhost` page crosses origins, so Chromium
        // automatically sends this CORS preflight before the command-result request. Hummingbird
        // has no `options` convenience method; `on` registers a route for an explicit HTTP method.
        router.on(
            "/workspace-ui-hook/command-result",
            method: .options
        ) { request, _ in
            WorkspaceUIHookRoute.commandResultPreflight(request: request)
        }
        // After the browser hook runs a message or stop command, it posts the correlated success
        // or failure here so the waiting mobile API request can finish with a definite result.
        router.post("/workspace-ui-hook/command-result") { request, context in
            try await WorkspaceUIHookRoute.commandResult(
                request: request,
                context: context
            )
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "Conductor Mobile Workspace UI Hook"
            )
        )
    }

    /// Restarts one long-lived listener after transient startup or runtime failures.
    ///
    /// `run` wraps both applications with this helper so either listener can recover without
    /// cancelling its sibling.
    private static func retryingServer(
        name: String,
        onFailure: @Sendable () async -> Void = {},
        run: @Sendable () async throws -> Void
    ) async throws {
        // Both listeners recover from transient startup failures without restarting the companion.
        while !Task.isCancelled {
            do {
                try await run()
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                await onFailure()
                FileHandle.standardError.write(
                    Data("\(name) unavailable; retrying: \(error)\n".utf8)
                )
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Sends an initial route snapshot and each distinct snapshot after a SQLite invalidation.
    ///
    /// Workspace and session WebSocket routes call this because their entire selected state is
    /// small enough to replace on every change.
    private static func streamSnapshots<Key, Snapshot>(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        databaseChanges: DatabaseChangeObserver,
        snapshotCache: DatabaseSnapshotCache<Key, Snapshot>,
        snapshotKey: Key,
        loadSnapshot: @escaping @Sendable () async throws -> Snapshot
    ) async throws where Key: Hashable & Sendable, Snapshot: Encodable & Equatable & Sendable {
        let changes = try await databaseChanges.changes()
        try await snapshotCache.withSubscriber(for: snapshotKey) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Phone -> desktop: discard application data while waiting for close or failure.
                group.addTask {
                    for try await _ in inbound {}
                }

                // Desktop -> phone: send current state immediately, then watch Conductor's database
                // and push each changed route-specific snapshot.
                group.addTask {
                    let encoder = JSONEncoder.conductor
                    var previousRevision: UInt64?

                    // One observer polls SQLite for every socket. Slow snapshot consumers retain
                    // only the newest pending change instead of creating an unbounded update
                    // backlog. The cache gives slightly staggered sockets for the same resource
                    // one shared SQLite read per change.
                    for try await generation in changes {
                        let value = try await snapshotCache.value(
                            for: snapshotKey,
                            generation: generation,
                            load: loadSnapshot
                        )

                        // data_version covers the whole database, so an unrelated table write can
                        // wake this route. Only send when this route's actual snapshot changed.
                        guard value.revision != previousRevision else {
                            continue
                        }
                        previousRevision = value.revision

                        try await outbound.writeTextMessage(
                            String(
                                decoding: try encoder.encode(value.snapshot),
                                as: UTF8.self
                            )
                        )
                    }
                }

                // Return as soon as one direction closes or fails, then stop its surviving sibling.
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// Sends an initial route snapshot and polls sources SQLite cannot invalidate.
    ///
    /// The workspace list uses this when pull-request cache files can change independently of the
    /// database observer used by `streamSnapshots`.
    private static func streamPolledSnapshots<Snapshot>(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        interval: Duration,
        loadSnapshot: @escaping @Sendable () async throws -> Snapshot
    ) async throws where Snapshot: Encodable & Equatable & Sendable {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in inbound {}
            }

            group.addTask {
                let encoder = JSONEncoder.conductor
                var previousSnapshot = try await loadSnapshot()
                try await outbound.writeTextMessage(
                    String(decoding: try encoder.encode(previousSnapshot), as: UTF8.self)
                )

                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    let snapshot = try await loadSnapshot()

                    guard snapshot != previousSnapshot else {
                        continue
                    }

                    try await outbound.writeTextMessage(
                        String(decoding: try encoder.encode(snapshot), as: UTF8.self)
                    )
                    previousSnapshot = snapshot
                }
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Runs for each accepted `/workspaces/{workspaceID}/sessions/{sessionID}/messages`
    /// WebSocket connection. It immediately sends a complete history or the suffix after a valid
    /// cursor, together with the complete queue. It then reloads selected rows after each database
    /// invalidation and sends completed-history changes or a changed complete queue.
    ///
    /// This is separate from `streamSnapshots` because message histories continually grow. Sending
    /// only incremental batches after the initial snapshot avoids repeatedly transferring and
    /// storing the entire history while still letting the mobile client upsert every change.
    private static func streamMessages(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        databaseChanges: DatabaseChangeObserver,
        requestedResumeCursor: Message.ID?,
        snapshotCache: DatabaseSnapshotCache<String, TranscriptSnapshot>,
        snapshotKey: String,
        loadSnapshot: @escaping @Sendable () async throws -> TranscriptSnapshot
    ) async throws {
        let changes = try await databaseChanges.changes()
        try await snapshotCache.withSubscriber(for: snapshotKey) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await _ in inbound {}
                }

                group.addTask {
                    let encoder = JSONEncoder.conductor
                    var previousRevision: UInt64?
                    var previousState: TranscriptSnapshot?

                    for try await generation in changes {
                        let value = try await snapshotCache.value(
                            for: snapshotKey,
                            generation: generation,
                            load: loadSnapshot
                        )
                        guard value.revision != previousRevision else {
                            continue
                        }
                        previousRevision = value.revision
                        let state = value.snapshot
                        guard let priorState = previousState else {
                            let initialEvent: MessageSyncEvent
                            // Only a cursor found in completed history can anchor an incremental
                            // suffix. Missing, malformed, queued, and unknown IDs intentionally
                            // take the snapshot branch so an untrusted baseline recovers at once.
                            if let requestedResumeCursor,
                               let cursorIndex = state.history.firstIndex(where: {
                                   RawUTF8Key($0.id) == RawUTF8Key(requestedResumeCursor)
                               }) {
                                initialEvent = .changes(
                                    upserting: Array(
                                        state.history[
                                            state.history.index(after: cursorIndex)...
                                        ]
                                    ),
                                    cursor: state.cursor,
                                    queuedMessages: state.queue
                                )
                            } else {
                                initialEvent = .snapshot(
                                    state.history,
                                    cursor: state.cursor,
                                    queuedMessages: state.queue
                                )
                            }
                            try await outbound.writeTextMessage(
                                String(
                                    decoding: try encoder.encode(initialEvent),
                                    as: UTF8.self
                                )
                            )
                            previousState = state
                            continue
                        }

                        // History is append-only while disconnected for v1, but mutations observed
                        // on this live connection still need upsert/delete events. Queue state is
                        // mutable, so any queue difference sends the entire current queue.
                        let previousMessagesByID = Dictionary(
                            uniqueKeysWithValues: priorState.history.map {
                                (RawUTF8Key($0.id), $0)
                            }
                        )
                        let messageIDs = Set(state.history.map {
                            RawUTF8Key($0.id)
                        })
                        let changedMessages = state.history.filter {
                            guard let previous = previousMessagesByID[RawUTF8Key($0.id)] else {
                                return true
                            }
                            return $0 != previous
                        }
                        let deletedMessageIDs = previousMessagesByID.keys
                            .filter { !messageIDs.contains($0) }
                            .sorted()
                            .compactMap { previousMessagesByID[$0]?.id }
                        let queuedMessages = state.hasSameQueue(as: priorState)
                            ? nil
                            : state.queue
                        previousState = state

                        guard !changedMessages.isEmpty
                                || !deletedMessageIDs.isEmpty
                                || queuedMessages != nil else {
                            continue
                        }

                        try await outbound.writeTextMessage(
                            String(
                                decoding: try encoder.encode(
                                    MessageSyncEvent.changes(
                                        upserting: changedMessages,
                                        deleting: deletedMessageIDs,
                                        cursor: state.cursor,
                                        queuedMessages: queuedMessages
                                    )
                                ),
                                as: UTF8.self
                            )
                        )
                    }
                }

                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// Extracts the optional `after` ID used by the message WebSocket route.
    ///
    /// Returning nil is deliberate: an absent, empty, duplicate, or malformed value
    /// makes `streamMessages` send a recoverable full snapshot. Parsing manually avoids assigning
    /// untrusted malformed percent escapes to `URLComponents.percentEncodedQuery`, which can trap.
    private static func resumeCursor(
        fromPercentEncodedQuery percentEncodedQuery: String?
    ) -> Message.ID? {
        guard let percentEncodedQuery else {
            return nil
        }

        var values: [String] = []
        for item in percentEncodedQuery.split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            let pair = item.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let name = String(pair[0]).removingPercentEncoding,
                  name == "after" else {
                continue
            }
            guard pair.count == 2,
                  let value = String(pair[1]).removingPercentEncoding else {
                return nil
            }
            values.append(value)
        }

        guard values.count == 1,
              let cursor = values.first,
              !cursor.isEmpty else {
            return nil
        }
        return cursor
    }

    /// Requires an exact Origin match. Production passes `nil`, so optional equality
    /// intentionally accepts only requests whose Origin header is absent.
    private static func originIsAllowed(
        _ request: Request,
        allowedOrigin: String?
    ) -> Bool {
        request.headers[.origin] == allowedOrigin
    }

    /// Resolves the effective model defaults served by the mobile `/settings` route.
    ///
    /// `makeApplication` calls this per request so edits to user or managed TOML take effect
    /// without restarting the companion.
    private static func modelSettings(
        userSettingsURL: URL,
        managedSettingsURL: URL
    ) throws -> SettingsResponse? {
        let userSettings = try modelSettings(from: userSettingsURL)
        let managedSettings = try modelSettings(from: managedSettingsURL)
        let defaultModelSettings = managedSettings.defaultModel == nil
            ? userSettings
            : managedSettings
        guard let defaultModel = defaultModelSettings.defaultModel else {
            return nil
        }
        let defaultAgentType = defaultModelSettings.defaultAgentType
            ?? Session.Model(rawValue: defaultModel).agentType?.rawValue
        let configuredReasoningEffort: String? = switch defaultAgentType {
        case Session.AgentType.claude.rawValue:
            managedSettings.defaultClaudeReasoningEffort
                ?? userSettings.defaultClaudeReasoningEffort
        case Session.AgentType.codex.rawValue:
            managedSettings.defaultCodexReasoningEffort
                ?? userSettings.defaultCodexReasoningEffort
        default:
            nil
        }
        return SettingsResponse(
            defaultModel: defaultModel,
            defaultFastMode: managedSettings.defaultFastMode
                ?? userSettings.defaultFastMode
                ?? false,
            defaultReasoningEffort: configuredReasoningEffort
                ?? Session.Model(rawValue: defaultModel).defaultReasoningEffort.rawValue
        )
    }

    /// Parses only the TOML keys the mobile settings response needs.
    ///
    /// The two-file resolver above calls this for user and managed settings, then applies managed
    /// precedence. Avoiding a general TOML dependency keeps this narrow desktop helper lightweight.
    private static func modelSettings(from settingsURL: URL) throws -> ParsedModelSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return ParsedModelSettings()
        }

        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        var section: ModelSettingsSection?
        var parsedSettings = ParsedModelSettings()

        for line in settings.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if let parsedSection = ModelSettingsSection(rawValue: line) {
                section = parsedSection
                continue
            }
            if line.hasPrefix("[") {
                section = nil
                continue
            }
            switch section {
            case .models:
                if let match = line.firstMatch(of: /^default\s*=\s*"([^"]+)"/) {
                    let components = match.1.split(separator: ":", maxSplits: 1)
                    parsedSettings.defaultAgentType = components.count == 2
                        ? String(components[0])
                        : nil
                    parsedSettings.defaultModel = components.last.map(String.init)
                } else if let match = line.firstMatch(
                    of: /^default_fast_mode\s*=\s*(true|false)/
                ) {
                    parsedSettings.defaultFastMode = match.1 == "true"
                }

            case .claude:
                if let match = line.firstMatch(
                    of: /^default_(?:thinking|effort)_level\s*=\s*"([^"]+)"/
                ) {
                    parsedSettings.defaultClaudeReasoningEffort = String(match.1)
                }

            case .codex:
                if let match = line.firstMatch(
                    of: /^default_(?:thinking|effort)_level\s*=\s*"([^"]+)"/
                ) {
                    parsedSettings.defaultCodexReasoningEffort = String(match.1)
                }

            case nil:
                break
            }
        }
        return parsedSettings
    }

    private enum ModelSettingsSection: String {
        case models = "[models]"
        case claude = "[models.claude]"
        case codex = "[models.codex]"
    }

    private struct ParsedModelSettings {
        var defaultAgentType: String?
        var defaultClaudeReasoningEffort: String?
        var defaultCodexReasoningEffort: String?
        var defaultModel: String?
        var defaultFastMode: Bool?
    }

    private struct SettingsResponse: Encodable {
        let defaultModel: String
        let defaultFastMode: Bool
        let defaultReasoningEffort: String
    }

    /// A deterministic partition of the rows selected for one message-stream refresh.
    ///
    /// `streamMessages` creates one after every database invalidation, then diffs it against the
    /// preceding value. The queue predicate is shared with mobile persistence through `isQueued`.
    private struct TranscriptSnapshot: Equatable, Sendable {
        let history: [Message]
        let queue: [Message]

        /// The opaque ID mobile sends back as `after`; nil means completed history is empty.
        var cursor: Message.ID? {
            history.last?.id
        }

        /// Separates mutable queue rows and establishes stable protocol order for both partitions.
        init(messages: [Message]) {
            history = messages
                .filter { !$0.isQueued }
                .sorted(by: Self.historyPrecedes)
            queue = messages
                .filter(\.isQueued)
                .sorted(by: Self.queuePrecedes)
        }

        /// Compares queues without Swift's Unicode-normalized identifier equality.
        ///
        /// A raw-ID replacement must send a queue snapshot even when the two IDs are canonically
        /// equivalent as Swift strings.
        func hasSameQueue(as other: Self) -> Bool {
            Self.haveSameMessages(queue, other.queue)
        }

        /// Makes cache revisions sensitive to raw identifier bytes, not canonical Unicode equality.
        static func == (lhs: Self, rhs: Self) -> Bool {
            haveSameMessages(lhs.history, rhs.history)
                && haveSameMessages(lhs.queue, rhs.queue)
        }

        /// Orders completed history by actual send time and deterministic fallback values.
        private static func historyPrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
            if lhs.sentAt != rhs.sentAt {
                switch (lhs.sentAt, rhs.sentAt) {
                case let (lhs?, rhs?):
                    return lhs < rhs
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return RawUTF8Key(lhs.id) < RawUTF8Key(rhs.id)
        }

        private static func haveSameMessages(
            _ lhs: [Message],
            _ rhs: [Message]
        ) -> Bool {
            lhs.count == rhs.count
                && zip(lhs, rhs).allSatisfy { lhs, rhs in
                    RawUTF8Key(lhs.id) == RawUTF8Key(rhs.id) && lhs == rhs
                }
        }

        /// Orders mutable rows by queue position with deterministic fallbacks for malformed ties.
        private static func queuePrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
            if let lhsOrder = lhs.queueOrder,
               let rhsOrder = rhs.queueOrder,
               lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return historyPrecedes(lhs, rhs)
        }
    }

    struct RequestContext: Hummingbird.RequestContext, WebSocketRequestContext {
        var coreContext: CoreRequestContextStorage
        let webSocket: WebSocketHandlerReference<Self>

        /// Gives each Hummingbird request the storage and WebSocket upgrade reference it requires.
        init(source: Source) {
            coreContext = .init(source: source)
            webSocket = .init()
        }
    }

}
