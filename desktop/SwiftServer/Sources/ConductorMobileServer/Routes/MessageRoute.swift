//
//  MessageRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import Logging
import SharedConductorData
import SQLiteData

enum MessageRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader
    ) async throws -> HTTPResponse.Status {
        @Dependency(SidecarBridgeClient.self) var sidecarBridgeClient

        let request = try await request.decode(as: SendMessageRequest.self, context: context)
        guard !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error(.badRequest, message: "Message cannot be empty.")
        }
        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")

        let messageSendContext: MessageSendContext?
        do {
            messageSendContext = try await database.read { database in
                let query = Session.messageSendContext(
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
                guard let row = try query.fetchOne(database) else {
                    return nil
                }

                return MessageSendContext(
                    agentType: row.agentType,
                    model: row.model,
                    workspacePath: row.workspacePath
                )
            }
        } catch {
            Logger.bridge.error("Failed to load message send context: \(error)")
            throw Error(
                .internalServerError,
                message: "Could not load message send context: \(error)"
            )
        }

        guard let messageSendContext else {
            throw Error(.notFound, message: "Session not found.")
        }
        guard let workspacePath = messageSendContext.workspacePath else {
            throw Error(.conflict, message: "The workspace is not available locally.")
        }

        do {
            try await sidecarBridgeClient.sendMessage(
                SidecarBridgeClient.RuntimeMessageRequest(
                    agentType: messageSendContext.agentType.rawValue,
                    cwd: workspacePath,
                    message: request.message,
                    model: messageSendContext.model,
                    sessionID: sessionID,
                    workspaceID: workspaceID
                )
            )
        } catch let error as SidecarBridgeClient.ResponseError {
            Logger.bridge.error(
                "Bridge request failed with status \(error.statusCode): \(error.message)"
            )
            throw Error(
                HTTPResponse.Status(code: error.statusCode),
                message: error.message
            )
        } catch {
            Logger.bridge.error("Failed to reach the Conductor sidecar bridge: \(error)")
            throw Error(
                .badGateway,
                message: "Could not reach the Conductor sidecar bridge: \(error)"
            )
        }

        return .noContent
    }

    /// Hummingbird's `HTTPError` encodes its message as nested JSON. This type preserves the
    /// mobile API's existing plain-text error body while still providing the correct HTTP status.
    struct Error: HTTPResponseError {
        let status: HTTPResponse.Status
        let message: String

        init(_ status: HTTPResponse.Status, message: String) {
            self.status = status
            self.message = message
        }

        func response(
            from request: Request,
            context: some Hummingbird.RequestContext
        ) throws -> Response {
            var response = message.response(from: request, context: context)
            response.status = status
            return response
        }
    }

    @Selection
    fileprivate struct MessageSendContext: Sendable {
        let agentType: Session.AgentType
        let model: String
        let workspacePath: String?
    }

    private struct SendMessageRequest: Decodable {
        let message: String
    }
}

private extension Session {
    static func messageSendContext(
        workspaceID: String,
        sessionID: String
    ) -> some SelectStatement<MessageRoute.MessageSendContext, Session, Workspace> {
        Session
            .where {
                $0.workspaceID.eq(workspaceID)
                    && $0.id.eq(sessionID)
            }
            .join(Workspace.all) { session, workspace in
                session.workspaceID.eq(workspace.id)
            }
            .select { session, workspace in
                MessageRoute.MessageSendContext.Columns(
                    agentType: session.agentType,
                    model: session.model,
                    workspacePath: workspace.workspacePath
                )
            }
    }
}
