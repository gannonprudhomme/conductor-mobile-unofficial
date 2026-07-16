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
                    try await makeApplication(database: database).run()
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

    static func makeApplication( // only non-private for tests
        database: DatabaseQueue,
        // Five seconds tolerates a slow Conductor UI write without holding the request indefinitely.
        workspaceMutationTimeout: Duration = .seconds(5),
        port: Int = 3_768,
        allowedOrigin: String? = nil
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)
        let webSocketRouter = Router(context: RequestContext.self)
        let databaseChanges = DatabaseChangeObserver(database: database)

        router.get("/ping") { _, _ in
            HTTPResponse.Status.noContent
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

        router.patch("/workspaces/{workspaceID}") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await WorkspaceRoute.patch(
                request: request,
                context: context,
                database: database,
                persistenceTimeout: workspaceMutationTimeout
            )
        }

        webSocketRouter.ws("/workspaces", shouldUpgrade: shouldUpgradeToWebSocket) { inbound, outbound, _ in
            try await streamSnapshots(
                inbound: inbound,
                outbound: outbound,
                databaseChanges: databaseChanges
            ) {
                try await database.read { database in
                    try WorkspaceListSnapshot(
                        repositories: Repository.orderedByDisplayOrder.fetchAll(database),
                        workspaces: WorkspaceSnapshot.mostRecentlyUpdated.fetchAll(database)
                    )
                }
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
                databaseChanges: databaseChanges
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
            try await streamMessages(
                inbound: inbound,
                outbound: outbound,
                databaseChanges: databaseChanges
            ) {
                try await database.read { database in
                    try Message.all(forWorkspaceID: workspaceID, sessionID: sessionID)
                        .fetchAll(database)
                }
            }
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
                database: database
            )
        }

        router.post("/workspaces/{workspaceID}/sessions/{sessionID}/stop") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await StopRoute.post(
                request: request,
                context: context,
                database: database
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

    static func makeWorkspaceUIHookApplication( // only non-private for tests
        hookSource: String,
        port: Int = 3_769
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)
        router.get("/workspace-ui-hook/hook.js") { request, _ in
            WorkspaceUIHookRoute.getHookFileContents(request: request, source: hookSource)
        }
        router.get("/workspace-ui-hook/events") { request, _ in
            await WorkspaceUIHookRoute.events(request: request)
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "Conductor Mobile Workspace UI Hook"
            )
        )
    }

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

    private static func streamSnapshots<Snapshot>(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        databaseChanges: DatabaseChangeObserver,
        loadSnapshot: @escaping @Sendable () async throws -> Snapshot
    ) async throws where Snapshot: Encodable & Equatable & Sendable {
        let changes = try await databaseChanges.changes()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Phone -> desktop: discard application data while waiting for close or failure.
            group.addTask {
                for try await _ in inbound {}
            }

            // Desktop -> phone: send current state immediately, then watch Conductor's database
            // and push each changed route-specific snapshot.
            group.addTask {
                let encoder = JSONEncoder.conductor
                var previousSnapshot = try await loadSnapshot()

                // Every subscriber receives state immediately instead of waiting for a write.
                try await outbound.writeTextMessage(
                    String(decoding: try encoder.encode(previousSnapshot), as: UTF8.self)
                )

                // One observer polls SQLite for every socket. Slow snapshot consumers retain only
                // the newest pending change instead of creating an unbounded update backlog.
                for try await _ in changes {
                    let snapshot = try await loadSnapshot()

                    // data_version covers the whole database, so an unrelated table write can
                    // wake this route. Only send when this route's actual snapshot changed.
                    guard snapshot != previousSnapshot else {
                        // No changes to the table(s) we're observing, ignore
                        continue
                    }

                    try await outbound.writeTextMessage(
                        String(decoding: try encoder.encode(snapshot), as: UTF8.self)
                    )
                    previousSnapshot = snapshot
                }
            }

            // Return as soon as one direction closes or fails, then stop its surviving sibling.
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Runs for each accepted `/workspaces/{workspaceID}/sessions/{sessionID}/messages`
    /// WebSocket connection. It immediately sends the session's complete message history, then
    /// reloads that history after each database invalidation and sends only messages that were
    /// added or updated.
    ///
    /// This is separate from `streamSnapshots` because message histories continually grow. Sending
    /// only incremental batches after the initial snapshot avoids repeatedly transferring and
    /// storing the entire history while still letting the mobile client upsert every change.
    private static func streamMessages(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        databaseChanges: DatabaseChangeObserver,
        loadMessages: @escaping @Sendable () async throws -> [Message]
    ) async throws {
        let changes = try await databaseChanges.changes()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in inbound {}
            }

            group.addTask {
                let encoder = JSONEncoder.conductor
                var previousMessages = try await loadMessages()
                try await outbound.writeTextMessage(
                    String(decoding: try encoder.encode(previousMessages), as: UTF8.self)
                )

                for try await _ in changes {
                    let messages = try await loadMessages()
                    let previousMessagesByID = Dictionary(
                        uniqueKeysWithValues: previousMessages.map { ($0.id, $0) }
                    )
                    let changedMessages = messages.filter {
                        previousMessagesByID[$0.id] != $0
                    }
                    previousMessages = messages

                    guard !changedMessages.isEmpty else {
                        continue
                    }

                    try await outbound.writeTextMessage(
                        String(decoding: try encoder.encode(changedMessages), as: UTF8.self)
                    )
                }
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Requires an exact Origin match. Production passes `nil`, so optional equality
    /// intentionally accepts only requests whose Origin header is absent.
    private static func originIsAllowed(
        _ request: Request,
        allowedOrigin: String?
    ) -> Bool {
        request.headers[.origin] == allowedOrigin
    }

    struct RequestContext: Hummingbird.RequestContext, WebSocketRequestContext {
        var coreContext: CoreRequestContextStorage
        let webSocket: WebSocketHandlerReference<Self>

        init(source: Source) {
            coreContext = .init(source: source)
            webSocket = .init()
        }
    }

}
