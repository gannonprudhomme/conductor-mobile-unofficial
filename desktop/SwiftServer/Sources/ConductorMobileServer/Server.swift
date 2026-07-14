//
//  Server.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import Hummingbird
import HummingbirdWebSocket
import SharedConductorData
import SQLiteData

public enum Server {
    /// Starts the server and its parent-process monitor. The executable calls this once at launch;
    /// when either task ends, the other is cancelled so the sidecar has one coordinated lifetime.
    public static func run(databaseURL: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await retryingServer(databaseURL: databaseURL, port: 3768)
            }
            group.addTask {
                try await waitForParentToExit()
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    static func makeApplication( // only non-private for tests
        database: DatabaseQueue,
        port: Int = 3768,
        allowedOrigin: String? = nil
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)
        let webSocketRouter = Router(context: RequestContext.self)

        let shouldUpgradeToWebSocket: @Sendable (Request, RequestContext) async throws -> RouterShouldUpgrade = { request, _ in
            if originIsAllowed(request, allowedOrigin: allowedOrigin) {
                // Accept the HTTP-to-WebSocket switch and start the matching route handler.
                .upgrade()
            } else {
                // Keep the connection as HTTP; the WebSocket route handler never starts.
                .dontUpgrade
            }
        }

        router.get("/repositories/{repositoryID}/icon") { request, context in
            try await IconRoute.response(
                request: request,
                context: context,
                database: database
            )
        }

        router.patch("/workspaces/{workspaceID}") { request, context in
            guard originIsAllowed(request, allowedOrigin: allowedOrigin) else {
                throw HTTPError(.forbidden)
            }

            return try await WorkspaceRoute.patch(
                request: request,
                context: context,
                database: database
            )
        }

        webSocketRouter.ws("/workspaces", shouldUpgrade: shouldUpgradeToWebSocket) { inbound, outbound, _ in
            try await streamSnapshots(
                inbound: inbound,
                outbound: outbound,
                database: database
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
                database: database
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
            try await streamSnapshots(
                inbound: inbound,
                outbound: outbound,
                database: database
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

    /// Opens Conductor's database and runs Hummingbird. This retries while the Tauri sidecar is
    /// alive because Conductor may still be starting or temporarily replacing its database.
    private static func retryingServer(databaseURL: URL, port: Int) async throws {
        while !Task.isCancelled {
            do {
                let database = try ConductorDatabase.open(at: databaseURL)
                try await makeApplication(database: database, port: port).run()
            } catch  where Task.isCancelled {
                throw CancellationError()
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "conductor-mobile-server unavailable; retrying: \(error)\n"
                            .utf8
                    )
                )
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Waits for EOF on the stdin pipe inherited from Tauri. EOF means the parent app exited, so
    /// returning from this task causes `run` to cancel the server instead of leaving an orphan.
    private static func waitForParentToExit() async throws {
        let input = FileHandle.standardInput
        try await withTaskCancellationHandler {
            do {
                for try await _ in input.bytes {}
                try Task.checkCancellation()
            } catch  where Task.isCancelled {
                throw CancellationError()
            }
        } onCancel: {
            try? input.close()
        }
    }

    private static func streamSnapshots<Snapshot>(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        database: DatabaseQueue,
        loadSnapshot: @escaping @Sendable () async throws -> Snapshot
    ) async throws where Snapshot: Encodable & Equatable & Sendable {
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Phone -> desktop: discard application data while waiting for close or failure.
            group.addTask {
                for try await _ in inbound {}
            }

            // Desktop -> phone: send current state immediately, then watch Conductor's database
            // and push each changed route-specific snapshot.
            group.addTask {
                let encoder = JSONEncoder.conductor
                var dataVersion = try readCurrentDataVersion(in: database)
                var previousSnapshot = try await loadSnapshot()

                // Every subscriber receives state immediately instead of waiting for a write.
                try await outbound.writeTextMessage(
                    String(decoding: try encoder.encode(previousSnapshot), as: UTF8.self)
                )

                while !Task.isCancelled {
                    // SQLite has no cross-process asynchronous change notification to subscribe
                    // to. Twenty-five milliseconds targets near-live UI updates while each socket
                    // does at most about 40 inexpensive scalar PRAGMA reads per second. Full
                    // snapshots are only loaded after that token changes.
                    try await Task.sleep(for: .milliseconds(25))
                    let nextDataVersion = try readCurrentDataVersion(in: database)

                    let hasDatabaseChanged = nextDataVersion != dataVersion
                    guard hasDatabaseChanged else {
                        continue
                    }

                    dataVersion = nextDataVersion
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

    private static func readCurrentDataVersion(in database: DatabaseQueue) throws -> Int {
        try database.read { database in
            try #sql("PRAGMA data_version", as: Int.self).fetchOne(database) ?? 0
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
