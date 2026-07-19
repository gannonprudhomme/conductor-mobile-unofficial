//
//  StopRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum StopRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> Response {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.uuid) var uuid
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let session: Session?
        do {
            session = try await loadSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load session: \(error)"
            )
        }

        guard let session else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard session.status == .working else {
            return try JSONEncoder.conductor.encode(
                session,
                from: request,
                context: context
            )
        }

        let stoppedSession: Session
        do {
            stoppedSession = try await uiHook.stopSession(
                requestID: uuid(),
                sessionID: sessionID
            ) {
                try await waitForStoppedSession(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    database: database,
                    clock: clock,
                    timeout: persistenceTimeout
                )
            }
        } catch WorkspaceUIHook.CommandDispatchError.commandFailed(let message) {
            throw PlainTextResponseError(
                .badGateway,
                message: "Conductor could not stop the session: \(message)"
            )
        } catch WorkspaceUIHook.CommandDispatchError.listenerUnavailable {
            throw PlainTextResponseError(
                .serviceUnavailable,
                message: "Conductor's workspace UI hook is unavailable."
            )
        } catch WorkspaceUIHook.CommandDispatchError.deliveryUnknown {
            throw PlainTextResponseError(
                .serviceUnavailable,
                message: "Could not determine whether Conductor received the stop command."
            )
        } catch WorkspaceUIHook.CommandDispatchError.persistenceTimedOut {
            throw PlainTextResponseError(
                .gatewayTimeout,
                message: "Conductor accepted the stop command, but the session remained working."
            )
        } catch WorkspaceUIHook.DispatchError.mutationInFlight {
            throw PlainTextResponseError(
                .conflict,
                message: "Another workspace command is still in progress."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not stop session: \(error)"
            )
        }

        return try JSONEncoder.conductor.encode(
            stoppedSession,
            from: request,
            context: context
        )
    }

    private static func waitForStoppedSession<C: Clock>(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader,
        clock: C,
        timeout: Duration
    ) async throws -> Session? where C.Duration == Duration {
        let start = clock.now

        while !Task.isCancelled {
            let session = try await loadSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            )
            if let session, session.status != .working {
                return session
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                return nil
            }

            try await clock.sleep(for: min(.milliseconds(25), timeout - elapsed))
        }

        throw CancellationError()
    }

    private static func loadSession(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader
    ) async throws -> Session? {
        try await database.read { database in
            try Session
                .where {
                    $0.workspaceID.eq(workspaceID)
                        && $0.id.eq(sessionID)
                }
                .fetchOne(database)
        }
    }
}
