//
//  MessageRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import HTTPTypes
import SharedConductorData
import SQLiteData

enum MessageRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter
    ) async throws -> Response {
        let sendMessageRequest = try await request.decode(
            as: SendMessageRequest.self,
            context: context
        )
        guard !sendMessageRequest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "Message cannot be empty.")
        }
        let attemptID = sendMessageRequest.attemptID
        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        @Dependency(\.uuid) var uuid
        @Dependency(\.workspaceUIHook) var workspaceUIHook
        let clock = ContinuousClock()
        let uiHook = workspaceUIHook

        let session: Session?
        do {
            session = try await database.read { database in
                try Session
                    .where {
                        $0.workspaceID.eq(workspaceID)
                            && $0.id.eq(sessionID)
                    }
                    .fetchOne(database)
            }
        } catch {
            return response(
                attemptID: attemptID,
                result: .rejected("Could not load message send context: \(error)")
            )
        }

        guard let session else {
            return response(
                attemptID: attemptID,
                result: .rejected("Session not found.")
            )
        }
        let requestedModel = Session.Model(rawValue: sendMessageRequest.model)
        let requestedAgentType: Session.AgentType
        if requestedModel == session.model
            || Session.Model.models(for: session.agentType).contains(requestedModel) {
            requestedAgentType = session.agentType
        } else if session.lastUserMessageAt == nil,
                  let agentType = requestedModel.agentType {
            requestedAgentType = agentType
        } else {
            return response(
                attemptID: attemptID,
                result: .rejected("Model is not available for this session's agent.")
            )
        }
        let isFastModeEnabled = sendMessageRequest.isFastModeEnabled
            ?? session.isFastModeEnabled
            ?? false

        do {
            if requestedAgentType != session.agentType {
                let didUpdate = try await uiHook.updateSessionAgentAndModel(
                    sessionID: sessionID,
                    agentType: requestedAgentType,
                    model: requestedModel
                ) {
                    let didPersist = try await waitForPersistedSessionChange(
                        sessionID: sessionID,
                        database: database,
                        clock: clock
                    ) { session in
                        session.agentType == requestedAgentType
                            && session.model == requestedModel
                    }
                    guard didPersist else {
                        throw PlainTextResponseError(
                            .gatewayTimeout,
                            message: "Timed out waiting for Conductor to save the session agent and model."
                        )
                    }
                }
                guard didUpdate else {
                    return response(
                        attemptID: attemptID,
                        result: .rejected(
                            "Conductor is not connected to change the session agent."
                        )
                    )
                }
            } else if requestedModel != session.model {
                let didUpdate = try await uiHook.updateSessionModel(
                    sessionID: sessionID,
                    model: requestedModel
                ) {
                    let didPersist = try await waitForPersistedSessionChange(
                        sessionID: sessionID,
                        database: database,
                        clock: clock
                    ) { session in
                        session.model == requestedModel
                    }
                    guard didPersist else {
                        throw PlainTextResponseError(
                            .gatewayTimeout,
                            message: "Timed out waiting for Conductor to save the session model."
                        )
                    }
                }
                guard didUpdate else {
                    return response(
                        attemptID: attemptID,
                        result: .rejected(
                            "Conductor is not connected to change the session model."
                        )
                    )
                }
            }
        } catch let error as WorkspaceUIHook.DispatchError {
            return response(
                attemptID: attemptID,
                result: .rejected(modelUpdateFailureReason(for: error))
            )
        } catch {
            return response(
                attemptID: attemptID,
                result: .rejected("Could not update the session model: \(error)")
            )
        }

        if isFastModeEnabled != (session.isFastModeEnabled ?? false) {
            do {
                _ = try await uiHook.dispatch(
                    command: .sessionFastMode(
                        sessionID: sessionID,
                        isEnabled: isFastModeEnabled
                    )
                ) {
                    try await database.write { database in
                        try Session
                            .find(sessionID)
                            .update { $0.isFastModeEnabled = #bind(isFastModeEnabled) }
                            .execute(database)
                    }
                } waitUntilChangeAvailableInDatabase: {
                    let didPersist = try await waitForPersistedSessionChange(
                        sessionID: sessionID,
                        database: database,
                        clock: clock
                    ) { session in
                        session.isFastModeEnabled == isFastModeEnabled
                    }
                    guard didPersist else {
                        throw PlainTextResponseError(
                            .gatewayTimeout,
                            message: "Timed out waiting for Conductor to save Fast Mode."
                        )
                    }
                }
            } catch let error as WorkspaceUIHook.DispatchError {
                return response(
                    attemptID: attemptID,
                    result: .rejected(fastModeUpdateFailureReason(for: error))
                )
            } catch {
                return response(
                    attemptID: attemptID,
                    result: .rejected("Could not update Fast Mode: \(error)")
                )
            }
        }

        let requestID = uuid()
        do {
            let receipt = try await uiHook.sendMessage(
                requestID: requestID,
                attemptID: attemptID,
                sessionID: sessionID,
                workspaceID: workspaceID,
                content: sendMessageRequest.message,
                mode: .sent
            )
            return response(
                attemptID: attemptID,
                result: .accepted(messageID: receipt.messageID)
            )
        } catch let error as WorkspaceUIHook.CommandDispatchError {
            let result: DeliveryResult = switch error {
            case .listenerUnavailable:
                .rejected("Conductor's workspace UI hook is unavailable.")
            case .commandFailed, .deliveryUnknown, .persistenceTimedOut:
                .unknown("Delivery could not be determined.")
            }
            return response(
                attemptID: attemptID,
                result: result
            )
        } catch {
            return response(
                attemptID: attemptID,
                result: .rejected("Message was not enqueued.")
            )
        }
    }

    private static func waitForPersistedSessionChange<C: Clock>(
        sessionID: Session.ID,
        database: any DatabaseReader,
        clock: C,
        matches: @Sendable (Session) -> Bool
    ) async throws -> Bool where C.Duration == Duration {
        let timeout = Duration.seconds(2)
        let start = clock.now

        while !Task.isCancelled {
            let isPersisted = try await database.read { database in
                try Session.find(sessionID).fetchOne(database).map(matches) ?? false
            }
            if isPersisted {
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

    private static func modelUpdateFailureReason(
        for error: WorkspaceUIHook.DispatchError
    ) -> String {
        switch error {
        case .deliveryUnknown:
            "Could not determine whether the session model was delivered."
        case .listenerUnavailable:
            "Conductor's workspace UI hook is unavailable."
        case .mutationInFlight:
            "Another Conductor UI change is still in progress."
        }
    }

    private static func fastModeUpdateFailureReason(
        for error: WorkspaceUIHook.DispatchError
    ) -> String {
        switch error {
        case .deliveryUnknown:
            "Could not determine whether Fast Mode was delivered."
        case .listenerUnavailable:
            "Conductor's workspace UI hook is unavailable."
        case .mutationInFlight:
            "Another Conductor UI change is still in progress."
        }
    }

    private struct SendMessageRequest: Decodable {
        let attemptID: UUID
        let message: String
        let model: String
        let isFastModeEnabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case attemptID = "attemptId"
            case message
            case model
            case isFastModeEnabled = "fast_mode"
        }
    }

    private enum DeliveryResult {
        case accepted(messageID: String)
        case rejected(String)
        case unknown(String)
    }

    private struct SendMessageResponse: Encodable {
        let attemptID: UUID
        let result: Result

        enum Result: Encodable {
            case accepted(messageID: String)
            case rejected(reason: String)
            case unknown(reason: String)

            private enum CodingKeys: String, CodingKey {
                case messageID = "messageId"
                case reason
                case type
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .accepted(let messageID):
                    try container.encode("accepted", forKey: .type)
                    try container.encode(messageID, forKey: .messageID)
                case .rejected(let reason):
                    try container.encode("rejected", forKey: .type)
                    try container.encode(reason, forKey: .reason)
                case .unknown(let reason):
                    try container.encode("unknown", forKey: .type)
                    try container.encode(reason, forKey: .reason)
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case attemptID = "attemptId"
            case result
        }
    }

    private static func response(attemptID: UUID, result: DeliveryResult) -> Response {
        let result: SendMessageResponse.Result = switch result {
        case .accepted(let messageID):
            .accepted(messageID: messageID)
        case .rejected(let reason):
            .rejected(reason: reason)
        case .unknown(let reason):
            .unknown(reason: reason)
        }
        let data = try! JSONEncoder().encode(
            SendMessageResponse(attemptID: attemptID, result: result)
        )
        return Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
