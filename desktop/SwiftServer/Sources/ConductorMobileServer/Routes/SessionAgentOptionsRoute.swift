//
//  SessionAgentOptionsRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Foundation
import Hummingbird
import Logging
import SharedConductorData
import SQLiteData

enum SessionAgentOptionsRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter
    ) async throws -> HTTPResponse.Status {
        let options = try await request.decode(
            as: Session.AgentOptions.self,
            context: context
        )
        guard Session.ReasoningEffort.knownValues.contains(options.reasoningEffort) else {
            throw PlainTextResponseError(
                .badRequest,
                message: "Unknown reasoning effort."
            )
        }

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")

        do {
            let agentType = try await database.read { database in
                try Session
                    .where {
                        $0.workspaceID.eq(workspaceID)
                            && $0.id.eq(sessionID)
                    }
                    .select(\.agentType)
                    .fetchOne(database)
            }
            guard let agentType else {
                throw PlainTextResponseError(.notFound, message: "Session not found.")
            }

            try await database.write { database in
                switch agentType {
                case .claude:
                    try Session
                        .find(sessionID)
                        .update {
                            $0.fastMode = #bind(options.fastMode)
                            $0.claudeEffortLevel = #bind(options.reasoningEffort)
                        }
                        .execute(database)

                default:
                    try Session
                        .find(sessionID)
                        .update {
                            $0.fastMode = #bind(options.fastMode)
                            $0.codexThinkingLevel = #bind(options.reasoningEffort)
                        }
                        .execute(database)
                }
            }
        } catch let error as PlainTextResponseError {
            throw error
        } catch {
            Logger.bridge.error("Failed to update session agent options: \(error)")
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not update session agent options: \(error)"
            )
        }

        return .noContent
    }
}
