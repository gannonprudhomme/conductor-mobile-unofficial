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
    ) async throws -> Response {
        @Dependency(\.continuousClock) var clock
        @Dependency(\.sidecarBridgeClient) var sidecarBridgeClient
        @Dependency(\.uuid) var uuid
        @Dependency(\.workspaceUIHook) var uiHook

        let sendMessageRequest = try await request.decode(
            as: SendMessageRequest.self,
            context: context
        )
        guard !sendMessageRequest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
                    model: row.model,
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
        // Use the requested model when supplied; otherwise continue with the session model.
        let model = sendMessageRequest.model ?? messageSendContext.model.rawValue
        let isKnownModel = Session.Model.models(for: messageSendContext.agentType)
            .contains { $0.rawValue == model }
        guard model == messageSendContext.model.rawValue || isKnownModel else {
            throw PlainTextResponseError(
                .badRequest,
                message: "Model is not available for this session's agent."
            )
        }

        if model != messageSendContext.model.rawValue {
            do {
                _ = try await uiHook.updateSessionModel(
                    sessionID: sessionID,
                    model: Session.Model(rawValue: model),
                    waitUntilChangeAvailableInDatabase: {
                        let didPersist = try await waitForPersistedSessionModel(
                            sessionID: sessionID,
                            model: model,
                            database: database,
                            clock: clock
                        )
                        guard didPersist else {
                            throw PlainTextResponseError(
                                .gatewayTimeout,
                                message: "Timed out waiting for Conductor to save the session model."
                            )
                        }
                    }
                )
            } catch let error as WorkspaceUIHook.DispatchError {
                switch error {
                case .deliveryUnknown:
                    throw PlainTextResponseError(
                        .serviceUnavailable,
                        message: "Could not determine whether the session model was delivered."
                    )
                case .mutationInFlight:
                    throw PlainTextResponseError(
                        .conflict,
                        message: "Another Conductor UI change is still in progress."
                    )
                }
            }
        }

        let messageID = uuid().uuidString
        do {
            try await sidecarBridgeClient.sendMessage(
                SidecarBridgeClient.RuntimeMessageRequest(
                    agentType: messageSendContext.agentType.rawValue,
                    cwd: workspacePath,
                    message: sendMessageRequest.message,
                    messageID: messageID,
                    model: model,
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

        let message = try await waitForPersistedMessage(
            id: messageID,
            sessionID: sessionID,
            database: database,
            clock: clock
        )
        guard let message else {
            throw PlainTextResponseError(
                .badGateway,
                message: "Conductor accepted the message, but it did not appear in the database before the persistence check timed out."
            )
        }

        return try JSONEncoder.conductor.encode(
            message,
            from: request,
            context: context
        )
    }

    private static func waitForPersistedMessage<C: Clock>(
        id: Message.ID,
        sessionID: Session.ID,
        database: any DatabaseReader,
        clock: C
    ) async throws -> Message? where C.Duration == Duration {
        let fastPollingDuration = Duration.milliseconds(100)
        let timeout = Duration.seconds(2)
        let start = clock.now

        while !Task.isCancelled {
            let message = try await database.read { database in
                try Message
                    .where {
                        $0.id.eq(id)
                            && $0.sessionID.eq(sessionID)
                    }
                    .fetchOne(database)
            }
            if let message {
                return message
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

    private static func waitForPersistedSessionModel<C: Clock>(
        sessionID: Session.ID,
        model: String,
        database: any DatabaseReader,
        clock: C
    ) async throws -> Bool where C.Duration == Duration {
        let timeout = Duration.seconds(2)
        let start = clock.now

        while !Task.isCancelled {
            let persistedModel = try await database.read { database in
                try Session.find(sessionID).fetchOne(database)?.model.rawValue
            }
            if persistedModel == model {
                return true
            }

            let elapsed = start.duration(to: clock.now)
            guard elapsed < timeout else {
                return false
            }
            try await clock.sleep(for: min(.milliseconds(25), timeout - elapsed))
        }

        throw CancellationError()
    }

    @Selection
    fileprivate struct MessageSendContext: Sendable {
        let agentType: Session.AgentType
        let model: Session.Model
        let workspacePath: String?
    }

    private struct SendMessageRequest: Decodable {
        let message: String
        let model: String?
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
