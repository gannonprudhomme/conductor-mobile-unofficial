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
        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")

        do {
            let hasSession = try await database.read { database in
                try Session
                    .where {
                        $0.workspaceID.eq(workspaceID)
                            && $0.id.eq(sessionID)
                    }
                    .select(\.id)
                    .fetchOne(database)
                    != nil
            }
            guard hasSession else {
                throw PlainTextResponseError(.notFound, message: "Session not found.")
            }

            try await database.write { database in
                try Session
                    .find(sessionID)
                    .update {
                        $0.fastMode = #bind(options.fastMode)
                    }
                    .execute(database)
            }
        } catch let error as PlainTextResponseError {
            throw error
        } catch {
            Logger.bridge.error("Failed to update session fast mode: \(error)")
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not update session fast mode: \(error)"
            )
        }

        return .noContent
    }
}
