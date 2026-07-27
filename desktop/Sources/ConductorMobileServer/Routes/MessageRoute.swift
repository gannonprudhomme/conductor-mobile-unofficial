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
            as: MessageSendRequest.self,
            context: context
        )
        guard !sendMessageRequest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "Message cannot be empty.")
        }
        let attemptID = sendMessageRequest.attemptID
        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        @Dependency(\.continuousClock) var clock
        @Dependency(\.uuid) var uuid
        @Dependency(\.workspaceUIHook) var workspaceUIHook
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try response(
                attemptID: attemptID,
                result: .rejected(reason: "Could not load message send context: \(error)")
            )
        }

        guard let session else {
            return try response(
                attemptID: attemptID,
                result: .rejected(reason: "Session not found.")
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
            return try response(
                attemptID: attemptID,
                result: .rejected(reason: "Model is not available for this session's agent.")
            )
        }
        let isFastModeEnabled = sendMessageRequest.isFastModeEnabled

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
                    return try response(
                        attemptID: attemptID,
                        result: .rejected(
                            reason: "Conductor is not connected to change the session agent."
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
                    return try response(
                        attemptID: attemptID,
                        result: .rejected(
                            reason: "Conductor is not connected to change the session model."
                        )
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.DispatchError {
            return try response(
                attemptID: attemptID,
                result: .rejected(
                    reason: updateFailureReason(for: error, subject: "the session model")
                )
            )
        } catch {
            return try response(
                attemptID: attemptID,
                result: .rejected(reason: "Could not update the session model: \(error)")
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
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WorkspaceUIHook.DispatchError {
                return try response(
                    attemptID: attemptID,
                    result: .rejected(
                        reason: updateFailureReason(for: error, subject: "Fast Mode")
                    )
                )
            } catch {
                return try response(
                    attemptID: attemptID,
                    result: .rejected(reason: "Could not update Fast Mode: \(error)")
                )
            }
        }

        let requestID = uuid()
        do {
            let messageID = try await uiHook.sendMessage(
                requestID: requestID,
                attemptID: attemptID,
                sessionID: sessionID,
                workspaceID: workspaceID,
                content: sendMessageRequest.message,
                mode: .sent
            )
            return try response(
                attemptID: attemptID,
                result: .accepted(messageID: messageID)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.CommandDispatchError {
            let result: MessageDeliveryResult = switch error {
            case .listenerUnavailable:
                .rejected(reason: "Conductor's workspace UI hook is unavailable.")
            case .commandFailed, .deliveryUnknown, .persistenceTimedOut:
                .unknown(reason: "Delivery could not be determined.")
            }
            return try response(
                attemptID: attemptID,
                result: result
            )
        } catch {
            return try response(
                attemptID: attemptID,
                result: .rejected(reason: "Message was not enqueued.")
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

    private static func updateFailureReason(
        for error: WorkspaceUIHook.DispatchError,
        subject: String
    ) -> String {
        switch error {
        case .deliveryUnknown:
            "Could not determine whether \(subject) was delivered."
        case .listenerUnavailable:
            "Conductor's workspace UI hook is unavailable."
        case .mutationInFlight:
            "Another Conductor UI change is still in progress."
        }
    }

    private static func response(
        attemptID: UUID,
        result: MessageDeliveryResult
    ) throws -> Response {
        let data = try JSONEncoder().encode(
            MessageSendResponse(attemptID: attemptID, result: result)
        )
        return Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
