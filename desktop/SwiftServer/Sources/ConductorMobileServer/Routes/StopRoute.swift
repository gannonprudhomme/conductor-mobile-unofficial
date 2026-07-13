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
        context: Server.RequestContext,
        database: any DatabaseReader
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.sidecarBridgeClient) var sidecarBridgeClient

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let agentType: Session.AgentType?
        do {
            agentType = try await database.read { database in
                try Session
                    .where {
                        $0.workspaceID.eq(workspaceID)
                            && $0.id.eq(sessionID)
                    }
                    .select(\.agentType)
                    .fetchOne(database)
            }
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load session: \(error)"
            )
        }

        guard let agentType else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }

        do {
            try await sidecarBridgeClient.stopSession(
                SidecarBridgeClient.RuntimeStopRequest(
                    agentType: agentType.rawValue,
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

        return .noContent
    }
}
