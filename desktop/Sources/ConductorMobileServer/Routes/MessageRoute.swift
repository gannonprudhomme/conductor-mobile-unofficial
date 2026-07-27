//
//  MessageRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum MessageRoute {
    static func post(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseWriter,
        commandTimeout: Duration
    ) async throws -> Response {
        @Dependency(\.continuousClock) var continuousClock
        @Dependency(\.uuid) var uuid
        @Dependency(\.workspaceUIHook) var workspaceUIHook
        let clock = continuousClock
        let uiHook = workspaceUIHook

        let sendMessageRequest = try await request.decode(
            as: SendMessageRequest.self,
            context: context
        )
        guard !sendMessageRequest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "Message cannot be empty.")
        }
        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")

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
            throw PlainTextResponseError(
                .internalServerError,
                message: "Could not load message send context: \(error)"
            )
        }

        guard let session else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        let model = sendMessageRequest.model ?? session.model.rawValue
        let requestedModel = Session.Model(rawValue: model)
        let requestedAgentType: Session.AgentType
        if requestedModel == session.model
            || Session.Model.models(for: session.agentType).contains(requestedModel) {
            requestedAgentType = session.agentType
        } else if session.lastUserMessageAt == nil,
                  let agentType = requestedModel.agentType {
            requestedAgentType = agentType
        } else {
            throw PlainTextResponseError(
                .badRequest,
                message: "Model is not available for this session's agent."
            )
        }
        let isFastModeEnabled = sendMessageRequest.isFastModeEnabled
            ?? session.isFastModeEnabled
            ?? false
        let availableReasoningEfforts = Session.availableReasoningEfforts(
            agentType: requestedAgentType,
            model: requestedModel
        )
        if let requestedReasoningEffort = sendMessageRequest.reasoningEffort,
           !availableReasoningEfforts.contains(requestedReasoningEffort) {
            throw PlainTextResponseError(
                .badRequest,
                message: "Reasoning effort is not available for this model."
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
                    throw PlainTextResponseError(
                        .serviceUnavailable,
                        message: "Conductor is not connected to change the session agent."
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
                    throw PlainTextResponseError(
                        .serviceUnavailable,
                        message: "Conductor is not connected to change the session model."
                    )
                }
            }
        } catch let error as WorkspaceUIHook.DispatchError {
            throw responseError(
                for: error,
                deliveryUnknownMessage: "Could not determine whether the session model was delivered."
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
                throw responseError(
                    for: error,
                    deliveryUnknownMessage: "Could not determine whether Fast Mode was delivered."
                )
            }
        }

        let requestID = uuid()
        return try await withThrowingTaskGroup(of: MessageSendEvent.self) { group in
            group.addTask {
                do {
                    try await uiHook.sendMessage(
                        requestID: requestID,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        content: sendMessageRequest.message,
                        mode: sendMessageRequest.mode ?? .sent,
                        reasoningEffort: reasoningEffort
                    )
                    return .accepted
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkspaceUIHook.CommandDispatchError {
                    return .failed(error)
                }
            }
            group.addTask {
                try await clock.sleep(for: commandTimeout)
                return .deadline
            }
            defer { group.cancelAll() }

            guard let event = try await group.next() else {
                throw CancellationError()
            }
            switch event {
            case .accepted:
                return Response(status: .noContent)
            case .deadline, .failed(.deliveryUnknown), .failed(.persistenceTimedOut):
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Could not determine whether the message was delivered. Check the conversation before retrying."
                )
            case .failed(.commandFailed(let message)):
                throw PlainTextResponseError(
                    .badGateway,
                    message: "Conductor could not send the message: \(message)"
                )
            case .failed(.listenerUnavailable):
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's workspace UI hook is unavailable."
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

    private static func responseError(
        for error: WorkspaceUIHook.DispatchError,
        deliveryUnknownMessage: String
    ) -> PlainTextResponseError {
        switch error {
        case .deliveryUnknown:
            PlainTextResponseError(
                .serviceUnavailable,
                message: deliveryUnknownMessage
            )
        case .listenerUnavailable:
            PlainTextResponseError(
                .serviceUnavailable,
                message: "Conductor's workspace UI hook is unavailable."
            )
        case .mutationInFlight:
            PlainTextResponseError(
                .conflict,
                message: "Another Conductor UI change is still in progress."
            )
        }
    }

    private struct SendMessageRequest: Decodable {
        let message: String
        let model: String?
        let isFastModeEnabled: Bool?
        let mode: WorkspaceUIHook.MessageMode?
        let reasoningEffort: Session.ReasoningEffort?

        private enum CodingKeys: String, CodingKey {
            case message
            case model
            case isFastModeEnabled = "fast_mode"
            case mode
            case reasoningEffort = "reasoning_effort"
        }
    }

    private enum MessageSendEvent: Sendable {
        case accepted
        case deadline
        case failed(WorkspaceUIHook.CommandDispatchError)
    }
}
