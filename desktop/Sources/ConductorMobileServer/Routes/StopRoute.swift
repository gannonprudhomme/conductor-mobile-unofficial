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
        database: any DatabaseReader
    ) async throws -> Response {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.sidecarBridgeClient) var sidecarBridgeClient

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

        do {
            try await sidecarBridgeClient.stopSession(
                SidecarBridgeClient.RuntimeStopRequest(
                    agentType: session.agentType.rawValue,
                    sessionID: sessionID
                )
            )
        } catch let error as SidecarBridgeClient.ResponseError {
            throw PlainTextResponseError(
                HTTPResponse.Status(code: error.statusCode),
                message: error.message
            )
        } catch {
            throw PlainTextResponseError(
                .badGateway,
                message: "Could not reach the Conductor sidecar bridge: \(error)"
            )
        }

        let stoppedSession = try await waitForStoppedSession(
            workspaceID: workspaceID,
            sessionID: sessionID,
            database: database,
            clock: clock
        )
        guard let stoppedSession else {
            throw PlainTextResponseError(
                .badGateway,
                message: "Conductor accepted the stop request, but the session did not stop in the database before the persistence check timed out."
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
        clock: C
    ) async throws -> Session? where C.Duration == Duration {
        let fastPollingDuration = Duration.milliseconds(100)
        let timeout = Duration.seconds(2)
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

            let interval: Duration = elapsed < fastPollingDuration
                ? .milliseconds(1)
                : .milliseconds(25)
            let sleepDuration = min(interval, timeout - elapsed)
            try await clock.sleep(for: sleepDuration)
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
