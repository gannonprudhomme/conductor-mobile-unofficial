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
        database: any DatabaseWriter,
        commandTimeout: Duration
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
        let availableReasoningEfforts = Session.availableReasoningEfforts(
            agentType: requestedAgentType,
            model: requestedModel
        )
        if let requestedReasoningEffort = sendMessageRequest.reasoningEffort,
           !availableReasoningEfforts.contains(requestedReasoningEffort) {
            return try response(
                attemptID: attemptID,
                result: .rejected(
                    reason: "Reasoning effort is not available for this model."
                )
            )
        }
        let reasoningEffort: Session.ReasoningEffort? = if let requestedReasoningEffort = sendMessageRequest.reasoningEffort {
            requestedReasoningEffort
        } else if let persistedReasoningEffort = session.reasoningEffort,
                  availableReasoningEfforts.contains(persistedReasoningEffort) {
            persistedReasoningEffort
        } else {
            availableReasoningEfforts.contains(requestedModel.defaultReasoningEffort)
                ? requestedModel.defaultReasoningEffort
                : availableReasoningEfforts.first
        }

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
        return try await withThrowingTaskGroup(of: MessageSendEvent.self) { group in
            group.addTask {
                do {
                    let messageID = try await uiHook.sendMessage(
                        requestID: requestID,
                        attemptID: attemptID,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        content: sendMessageRequest.message,
                        mode: sendMessageRequest.mode,
                        reasoningEffort: reasoningEffort
                    )
                    return .accepted(messageID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkspaceUIHook.CommandDispatchError {
                    return .failed(error)
                } catch {
                    return .failed(.deliveryUnknown)
                }
            }
            group.addTask {
                try await Task.sleep(for: commandTimeout)
                return .deadline
            }
            defer { group.cancelAll() }

            guard let event = try await group.next() else {
                throw CancellationError()
            }
            switch event {
            case .accepted(let messageID):
                return try response(
                    attemptID: attemptID,
                    result: .accepted(messageID: messageID)
                )
            case .deadline, .failed(.deliveryUnknown), .failed(.persistenceTimedOut):
                return try response(
                    attemptID: attemptID,
                    result: .unknown(
                        reason: "Could not determine whether the message was delivered."
                    )
                )
            case .failed(.commandFailed(let message)):
                return try response(
                    attemptID: attemptID,
                    result: .rejected(
                        reason: "Conductor rejected the message: \(message)"
                    )
                )
            case .failed(.listenerUnavailable):
                return try response(
                    attemptID: attemptID,
                    result: .rejected(
                        reason: "Conductor's workspace UI hook is unavailable."
                    )
                )
            }
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

    private enum MessageSendEvent: Sendable {
        case accepted(Message.ID?)
        case deadline
        case failed(WorkspaceUIHook.CommandDispatchError)
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
