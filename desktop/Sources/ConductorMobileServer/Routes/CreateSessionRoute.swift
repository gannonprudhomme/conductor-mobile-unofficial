//
//  CreateSessionRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum CreateSessionRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> Response {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let initialSessionCount: Int
        do {
            initialSessionCount = try await database.read { database in
                guard try Workspace.find(workspaceID).fetchOne(database) != nil else {
                    throw PlainTextResponseError(.notFound, message: "Workspace not found.")
                }
                return try Session
                    .where { $0.workspaceID.eq(workspaceID) }
                    .fetchCount(database)
            }
        } catch let error as PlainTextResponseError {
            throw error
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load workspace sessions: \(error)"
            )
        }

        do {
            try await uiHook.createSession(
                workspaceID: workspaceID,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilSessionCountExceeds(
                        initialSessionCount,
                        workspaceID: workspaceID,
                        database: database,
                        clock: clock,
                        timeout: persistenceTimeout
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether session creation was delivered."
                )
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
                )
            case .mutationInFlight:
                throw PlainTextResponseError(
                    .conflict,
                    message: "Another workspace change is still in progress."
                )
            }
        } catch PersistenceError.timedOut {
            throw PlainTextResponseError(
                .gatewayTimeout,
                message: "Timed out waiting for Conductor to create the session."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not create session: \(error)"
            )
        }

        let session: Session?
        do {
            session = try await database.read { database in
                try Session
                    .where { $0.workspaceID.eq(workspaceID) }
                    .order { $0.createdAt.desc() }
                    .fetchOne(database)
            }
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load the created session: \(error)"
            )
        }
        guard let session else {
            throw PlainTextResponseError(
                .badGateway,
                message: "Conductor reported a new session, but it could not be loaded."
            )
        }

        return try JSONEncoder.conductor.encode(
            session,
            from: request,
            context: context
        )
    }

    private static func waitUntilSessionCountExceeds<C: Clock>(
        _ initialSessionCount: Int,
        workspaceID: Workspace.ID,
        database: any DatabaseReader,
        clock: C,
        timeout: Duration
    ) async throws where C.Duration == Duration {
        let start = clock.now
        while !Task.isCancelled {
            let sessionCount = try await database.read { database in
                try Session
                    .where { $0.workspaceID.eq(workspaceID) }
                    .fetchCount(database)
            }
            if sessionCount > initialSessionCount {
                return
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                throw PersistenceError.timedOut
            }

            try await clock.sleep(for: min(.milliseconds(3), timeout - elapsed))
        }

        throw CancellationError()
    }

    private enum PersistenceError: Error {
        case timedOut
    }
}
