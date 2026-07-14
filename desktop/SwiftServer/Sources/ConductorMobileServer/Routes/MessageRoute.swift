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
        @Dependency(\.sidecarBridgeClient) var sidecarBridgeClient

        let request = try await request.decode(as: SendMessageRequest.self, context: context)
        guard !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "Message cannot be empty.")
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
                    agentPersonality: row.agentPersonality,
                    claudeEffortLevel: row.claudeEffortLevel,
                    codexThinkingLevel: row.codexThinkingLevel,
                    fastMode: row.fastMode,
                    model: row.model,
                    permissionMode: row.permissionMode,
                    workspacePath: row.workspacePath
                )
            }
        } catch {
            Logger.bridge.error("Failed to load message send context: \(error)")
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load message send context: \(error)"
            )
        }

        guard let messageSendContext else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard let workspacePath = messageSendContext.workspacePath else {
            throw PlainTextResponseError(
                .conflict,
                message: "The workspace is not available locally."
            )
        }

        do {
            try await sidecarBridgeClient.sendMessage(
                SidecarBridgeClient.RuntimeMessageRequest(
                    agentType: messageSendContext.agentType.rawValue,
                    cwd: workspacePath,
                    fastMode: request.fastMode ?? messageSendContext.fastMode ?? false,
                    message: request.message,
                    model: messageSendContext.model,
                    modelReasoningEffort: (
                        request.reasoningEffort
                            ?? messageSendContext.reasoningEffort
                            ?? .high
                    ).rawValue,
                    permissionMode: (messageSendContext.permissionMode ?? .default).rawValue,
                    personality: (messageSendContext.agentPersonality ?? .pragmatic).rawValue,
                    sessionID: sessionID,
                    workspaceID: workspaceID
                )
            )
        } catch let error as SidecarBridgeClient.ResponseError {
            Logger.bridge.error(
                "Bridge request failed with status \(error.statusCode): \(error.message)"
            )
            throw PlainTextResponseError(
                HTTPResponse.Status(code: error.statusCode),
                message: error.message
            )
        } catch {
            Logger.bridge.error("Failed to reach the Conductor sidecar bridge: \(error)")
            throw PlainTextResponseError(
                .badGateway,
                message: "Could not reach the Conductor sidecar bridge: \(error)"
            )
        }

        return .noContent
    }

    @Selection
    fileprivate struct MessageSendContext: Sendable {
        let agentType: Session.AgentType
        let agentPersonality: Session.Personality?
        let claudeEffortLevel: Session.ReasoningEffort?
        let codexThinkingLevel: Session.ReasoningEffort?
        let fastMode: Bool?
        let model: String
        let permissionMode: Session.PermissionMode?
        let workspacePath: String?

        var reasoningEffort: Session.ReasoningEffort? {
            agentType == .claude ? claudeEffortLevel : codexThinkingLevel
        }
    }

    private struct SendMessageRequest: Decodable {
        let message: String
        let fastMode: Bool?
        let reasoningEffort: Session.ReasoningEffort?

        private enum CodingKeys: String, CodingKey {
            case message
            case fastMode = "fast_mode"
            case reasoningEffort = "reasoning_effort"
        }
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
                    agentPersonality: session.agentPersonality,
                    claudeEffortLevel: session.claudeEffortLevel,
                    codexThinkingLevel: session.codexThinkingLevel,
                    fastMode: session.fastMode,
                    model: session.model,
                    permissionMode: session.permissionMode,
                    workspacePath: workspace.workspacePath
                )
            }
    }
}
