//
//  Server.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation
import Hummingbird
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
        database: any DatabaseReader,
        port: Int = 3768
    ) -> Application<RouterResponder<RequestContext>> {
        let router = Router(context: RequestContext.self)

        router.get("/sessions") { _, _ in
            try await database.read { database in
                try Session.mostRecentlyUpdated.fetchAll(database)
            }
        }

        router.get("/workspaces") { _, _ in
            try await database.read { database in
                try WorkspaceSnapshot.mostRecentlyUpdated.fetchAll(database)
            }
        }

        router.get("/repositories") { _, _ in
            try await database.read { database in
                try Repository.orderedByDisplayOrder.fetchAll(database)
            }
        }

        router.get("/workspaces/{workspaceID}/sessions") { _, context in
            let workspaceID = try context.parameters.require("workspaceID")
            return try await database.read { database in
                try Session.all(forWorkspaceID: workspaceID).fetchAll(database)
            }
        }

        router.get("/workspaces/{workspaceID}/sessions/{sessionID}/messages") { _, context in
            let workspaceID = try context.parameters.require("workspaceID")
            let sessionID = try context.parameters.require("sessionID")
            return try await database.read { database in
                try Message.all(forWorkspaceID: workspaceID, sessionID: sessionID)
                    .fetchAll(database)
            }
        }

        router.post("/workspaces/{workspaceID}/sessions/{sessionID}/messages") { request, context in
            try await MessageRoute.post(
                request: request,
                context: context,
                database: database
            )
        }

        return Application(
            router: router,
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

    /// Exists just to give it the custom JSONEncoder
    struct RequestContext: Hummingbird.RequestContext {
        var coreContext: CoreRequestContextStorage

        init(source: Source) {
            coreContext = .init(source: source)
        }

        var responseEncoder: JSONEncoder {
            .conductor
        }
    }
}
