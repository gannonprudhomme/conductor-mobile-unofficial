//
//  WorkspaceUIHook.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData

@DependencyClient
public struct WorkspaceUIHook: Sendable {
    typealias MessageMode = MessageSendMode

    public var isConnected: @Sendable () async -> Bool = { false }
    var connect: @Sendable () async -> Connection = {
        Connection(
            events: AsyncStream { $0.finish() },
            id: UUID()
        )
    }
    var createSession: @Sendable (
        _ workspaceID: String,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var didCompleteCommand: @Sendable (_ result: CommandResult) async -> Bool = { _ in
        false
    }
    var disconnect: @Sendable (_ connectionID: UUID) async -> Void
    var createWorkspace: @Sendable (
        _ command: CreateWorkspaceCommand,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool = { _, _ in false }
    var deleteQueuedMessage: @Sendable (
        _ sessionID: String,
        _ messageID: String,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var dispatch: @Sendable (
        _ command: UIHookCommand,
        _ fallback: (@Sendable () async throws -> Void)?,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> DispatchPath
    var listenerUnavailable: @Sendable () async -> Void
    var mutateSession: @Sendable (
        _ requestID: UUID,
        _ command: UIHookCommand,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var sendMessage: @Sendable (
        _ requestID: UUID,
        _ attemptID: UUID,
        _ sessionID: Session.ID,
        _ workspaceID: Workspace.ID,
        _ content: String,
        _ mode: MessageMode,
        _ reasoningEffort: Session.ReasoningEffort?
    ) async throws -> Message.ID?
    var stopSession: @Sendable (
        _ requestID: UUID,
        _ sessionID: Session.ID,
        _ waitUntilStopped: @escaping @Sendable () async throws -> Session?
    ) async throws -> Session
    var steerQueuedMessage: @Sendable (
        _ sessionID: String,
        _ messageID: String,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var updateSessionAgentAndModel: @Sendable (
        _ sessionID: Session.ID,
        _ agentType: Session.AgentType,
        _ model: Session.Model,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool = { _, _, _, _ in false }
    var updateSessionModel: @Sendable (
        _ sessionID: Session.ID,
        _ model: Session.Model,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool = { _, _, _ in false }
    var reorderQueue: @Sendable (
        _ sessionID: String,
        _ messageIDs: [String],
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var setQueuePaused: @Sendable (
        _ sessionID: String,
        _ isPaused: Bool,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void
    var editQueuedMessage: @Sendable (
        _ sessionID: String,
        _ messageID: String,
        _ content: String,
        _ shouldResumeQueue: Bool,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> Void

    enum DispatchPath: Equatable, Sendable {
        case hook
        case sqliteFallback
    }

    enum DispatchError: Error, Equatable, Sendable {
        case deliveryUnknown
        case listenerUnavailable
        case mutationInFlight
    }

    enum CommandDispatchError: Error, Equatable, Sendable {
        case commandFailed(String)
        case deliveryUnknown
        case listenerUnavailable
        case persistenceTimedOut
    }

    struct CommandResult: Decodable, Sendable {
        let requestID: UUID
        let error: String?
        let result: Result?

        init(requestID: UUID, error: String? = nil, result: Result? = nil) {
            self.requestID = requestID
            self.error = error
            self.result = result
        }

        struct Result: Decodable, Sendable {
            let type: ResultType
            let messageID: String?
            let reason: String?

            private enum CodingKeys: String, CodingKey {
                case type
                case messageID = "messageId"
                case reason
            }
        }

        enum ResultType: String, Decodable, Sendable {
            case accepted
            case rejected
            case unknown
        }

        private enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
            case error
            case result
        }
    }

    struct Connection: Sendable {
        let events: AsyncStream<String>
        let id: UUID
    }
}

extension WorkspaceUIHook: DependencyKey {
    public static var liveValue: Self {
        let state = WorkspaceUIHookState()
        return Self(
            isConnected: { await state.isConnected },
            connect: { await state.connect() },
            createSession: { workspaceID, waitUntilChangeAvailableInDatabase in
                try await state.createSession(
                    workspaceID: workspaceID,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            didCompleteCommand: { result in
                await state.didCompleteCommand(result)
            },
            disconnect: { connectionID in
                await state.disconnect(connectionID: connectionID)
            },
            createWorkspace: { command, waitUntilChangeAvailableInDatabase in
                try await state.createWorkspace(
                    command: command,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            deleteQueuedMessage: {
                sessionID,
                messageID,
                waitUntilChangeAvailableInDatabase in
                try await state.deleteQueuedMessage(
                    sessionID: sessionID,
                    messageID: messageID,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            dispatch: { command, fallback, waitUntilChangeAvailableInDatabase in
                try await state.dispatch(
                    command,
                    fallback: fallback,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            listenerUnavailable: { await state.listenerUnavailable() },
            mutateSession: { requestID, command, waitUntilChangeAvailableInDatabase in
                try await state.mutateSession(
                    requestID: requestID,
                    command: command,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            sendMessage: {
                requestID,
                attemptID,
                sessionID,
                workspaceID,
                content,
                mode,
                reasoningEffort in
                try await state.sendMessage(
                    requestID: requestID,
                    attemptID: attemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode,
                    reasoningEffort: reasoningEffort
                )
            },
            stopSession: { requestID, sessionID, waitUntilStopped in
                try await state.stopSession(
                    requestID: requestID,
                    sessionID: sessionID,
                    waitUntilStopped: waitUntilStopped
                )
            },
            steerQueuedMessage: {
                sessionID,
                messageID,
                waitUntilChangeAvailableInDatabase in
                try await state.steerQueuedMessage(
                    sessionID: sessionID,
                    messageID: messageID,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            updateSessionAgentAndModel: {
                sessionID,
                agentType,
                model,
                waitUntilChangeAvailableInDatabase in
                try await state.updateSessionAgentAndModel(
                    sessionID: sessionID,
                    agentType: agentType,
                    model: model,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            updateSessionModel: { sessionID, model, waitUntilChangeAvailableInDatabase in
                try await state.updateSessionModel(
                    sessionID: sessionID,
                    model: model,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            reorderQueue: { sessionID, messageIDs, waitUntilChangeAvailableInDatabase in
                try await state.reorderQueue(
                    sessionID: sessionID,
                    messageIDs: messageIDs,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            setQueuePaused: { sessionID, isPaused, waitUntilChangeAvailableInDatabase in
                try await state.setQueuePaused(
                    sessionID: sessionID,
                    isPaused: isPaused,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            editQueuedMessage: {
                sessionID,
                messageID,
                content,
                shouldResumeQueue,
                waitUntilChangeAvailableInDatabase in
                try await state.editQueuedMessage(
                    sessionID: sessionID,
                    messageID: messageID,
                    content: content,
                    shouldResumeQueue: shouldResumeQueue,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            }
        )
    }
}

extension DependencyValues {
    public var workspaceUIHook: WorkspaceUIHook {
        get { self[WorkspaceUIHook.self] }
        set { self[WorkspaceUIHook.self] = newValue }
    }
}

private actor WorkspaceUIHookState {
    private var activeConnection: ConnectionState?
    private var dispatchedCreationIDs: Set<Workspace.ID> = []
    private var isMutationInFlight = false
    private var pendingCommands: [UUID: PendingCommand] = [:]

    var isConnected: Bool {
        activeConnection != nil
    }

    func connect() -> WorkspaceUIHook.Connection {
        let id = UUID()
        let (events, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.disconnect(connectionID: id)
            }
        }

        // EventSource reconnects replace the old stream so dispatch has one authoritative hook.
        activeConnection?.continuation.finish()
        activeConnection = ConnectionState(continuation: continuation, id: id)
        return WorkspaceUIHook.Connection(events: events, id: id)
    }

    func disconnect(connectionID: UUID) {
        guard let connection = activeConnection, connection.id == connectionID else {
            return
        }

        activeConnection = nil
        connection.continuation.finish()
        for command in pendingCommands.values {
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
            )
        }
        pendingCommands.removeAll()
    }

    func listenerUnavailable() {
        guard let connectionID = activeConnection?.id else {
            return
        }
        disconnect(connectionID: connectionID)
    }

    func createWorkspace(
        command: CreateWorkspaceCommand,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> Bool {
        if dispatchedCreationIDs.contains(command.workspaceID) {
            try await waitUntilChangeAvailableInDatabase()
            return true
        }

        let path = try await dispatch(
            event: Self.createWorkspaceEvent(command),
            fallback: {},
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase,
            enqueuedCreationID: command.workspaceID
        )
        return path == .hook
    }

    /// Serializes UI mutations while coordinating browser-hook delivery with SQLite.
    ///
    /// If no active listener can accept the event, this performs `fallback` or reports that the
    /// listener is unavailable. Once an event is enqueued, it waits for
    /// `waitUntilChangeAvailableInDatabase` and never falls back because Conductor may already have
    /// applied the mutation. Injecting both operations keeps this actor independent of persistence
    /// details.
    func dispatch(
        _ command: UIHookCommand,
        fallback: (@Sendable () async throws -> Void)?,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> WorkspaceUIHook.DispatchPath {
        try await dispatch(
            event: try command.event(),
            fallback: fallback,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func createSession(
        workspaceID: String,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        _ = try await dispatch(
            event: UIHookCommand.getCreateSessionEventName(workspaceID: workspaceID),
            fallback: nil,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func didCompleteCommand(_ result: WorkspaceUIHook.CommandResult) -> Bool {
        guard let command = pendingCommands[result.requestID] else {
            return false
        }

        pendingCommands[result.requestID] = nil

        if let result = result.result {
            switch result.type {
            case .accepted:
                switch command.kind {
                case .message:
                    guard let messageID = result.messageID,
                          !messageID.isEmpty else {
                        command.continuation.finish(
                            throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                        )
                        return true
                    }
                    command.continuation.yield(.message(messageID))
                    command.continuation.finish()
                case .queuedMessage:
                    command.continuation.yield(.completed)
                    command.continuation.finish()
                case .command:
                    command.continuation.finish(
                        throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                    )
                }
            case .rejected:
                command.continuation.finish(
                    throwing: WorkspaceUIHook.CommandDispatchError.commandFailed(
                        result.reason ?? "Conductor rejected the message."
                    )
                )
            case .unknown:
                command.continuation.finish(
                    throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                )
            }
        } else if let error = result.error {
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.commandFailed(error)
            )
        } else if command.kind != .command {
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
            )
        } else {
            command.continuation.yield(.completed)
            command.continuation.finish()
        }
        return true
    }

    func mutateSession(
        requestID: UUID,
        command: UIHookCommand,
        waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard !isMutationInFlight else {
            throw WorkspaceUIHook.DispatchError.mutationInFlight
        }
        isMutationInFlight = true
        defer { isMutationInFlight = false }

        let event = try command.event(requestID: requestID)
        let (results, continuation) = try enqueueCommand(requestID: requestID, event: event)
        defer {
            continuation.finish()
            pendingCommands[requestID] = nil
        }

        for try await _ in results {
            try await waitUntilChangeAvailableInDatabase()
            return
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
    }

    func sendMessage(
        requestID: UUID,
        attemptID: UUID,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        content: String,
        mode: WorkspaceUIHook.MessageMode,
        reasoningEffort: Session.ReasoningEffort?
    ) async throws -> Message.ID? {
        let event = try Self.messageEvent(
            requestID: requestID,
            attemptID: attemptID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            content: content,
            mode: mode,
            reasoningEffort: reasoningEffort
        )
        let (results, continuation) = try enqueueCommand(
            requestID: requestID,
            event: event,
            kind: mode == .sent ? .message : .queuedMessage
        )
        defer {
            continuation.finish()
            pendingCommands[requestID] = nil
        }

        do {
            for try await result in results {
                switch result {
                case .completed where mode == .queued:
                    return nil
                case .message(let messageID) where mode == .sent:
                    return messageID
                case .completed, .message:
                    throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.CommandDispatchError {
            throw error
        } catch {
            throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
        }
        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
    }

    func stopSession(
        requestID: UUID,
        sessionID: Session.ID,
        waitUntilStopped: @escaping @Sendable () async throws -> Session?
    ) async throws -> Session {
        guard !isMutationInFlight else {
            throw WorkspaceUIHook.DispatchError.mutationInFlight
        }
        isMutationInFlight = true
        defer { isMutationInFlight = false }

        let event = try Self.stopSessionEvent(requestID: requestID, sessionID: sessionID)
        let (results, continuation) = try enqueueCommand(
            requestID: requestID,
            event: event,
            kind: .command
        )
        defer {
            continuation.finish()
            pendingCommands[requestID] = nil
        }

        return try await withThrowingTaskGroup(of: StopEvent.self) { group in
            group.addTask {
                do {
                    for try await _ in results {
                        return .accepted
                    }
                    return .deliveryUnknown
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkspaceUIHook.CommandDispatchError {
                    return switch error {
                    case .commandFailed(let message):
                        .rejected(message)
                    case .deliveryUnknown, .listenerUnavailable, .persistenceTimedOut:
                        .deliveryUnknown
                    }
                }
            }
            group.addTask {
                guard let session = try await waitUntilStopped() else {
                    return .persistenceTimedOut
                }
                return .persisted(session)
            }
            defer { group.cancelAll() }

            var isAccepted = false
            var isDeliveryUnknown = false
            var didPersistenceTimeOut = false
            while let event = try await group.next() {
                switch event {
                case .accepted:
                    isAccepted = true
                    if didPersistenceTimeOut {
                        throw WorkspaceUIHook.CommandDispatchError.persistenceTimedOut
                    }
                case .rejected(let message):
                    throw WorkspaceUIHook.CommandDispatchError.commandFailed(message)
                case .deliveryUnknown:
                    isDeliveryUnknown = true
                    if didPersistenceTimeOut {
                        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                    }
                case .persistenceTimedOut:
                    didPersistenceTimeOut = true
                    if isAccepted {
                        throw WorkspaceUIHook.CommandDispatchError.persistenceTimedOut
                    }
                    if isDeliveryUnknown || pendingCommands[requestID] != nil {
                        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                    }
                    continue
                case .persisted(let session):
                    return session
                }
            }

            throw CancellationError()
        }
    }

    func updateSessionModel(
        sessionID: Session.ID,
        model: Session.Model,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> Bool {
        let path = try await dispatch(
            event: Self.sessionModelEvent(sessionID: sessionID, model: model),
            fallback: {},
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
        return path == .hook
    }

    func updateSessionAgentAndModel(
        sessionID: Session.ID,
        agentType: Session.AgentType,
        model: Session.Model,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> Bool {
        let path = try await dispatch(
            event: Self.sessionAgentAndModelEvent(
                sessionID: sessionID,
                agentType: agentType,
                model: model
            ),
            fallback: {},
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
        return path == .hook
    }

    func reorderQueue(
        sessionID: String,
        messageIDs: [String],
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        let requestID = UUID()
        try await dispatchCommand(
            requestID: requestID,
            event: try QueueOrderCommand(
                requestID: requestID,
                sessionID: sessionID,
                messageIDs: messageIDs
            ).event,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func deleteQueuedMessage(
        sessionID: String,
        messageID: String,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        let requestID = UUID()
        try await dispatchCommand(
            requestID: requestID,
            event: try QueuedMessageDeleteCommand(
                requestID: requestID,
                sessionID: sessionID,
                messageID: messageID
            ).event,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func setQueuePaused(
        sessionID: String,
        isPaused: Bool,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        let requestID = UUID()
        try await dispatchCommand(
            requestID: requestID,
            event: try QueuePauseCommand(
                requestID: requestID,
                sessionID: sessionID,
                isPaused: isPaused
            ).event,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func editQueuedMessage(
        sessionID: String,
        messageID: String,
        content: String,
        shouldResumeQueue: Bool,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        let requestID = UUID()
        try await dispatchCommand(
            requestID: requestID,
            event: try QueuedMessageEditCommand(
                requestID: requestID,
                sessionID: sessionID,
                edit: .init(
                    messageID: messageID,
                    content: content,
                    shouldResumeQueue: shouldResumeQueue
                )
            ).event,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    func steerQueuedMessage(
        sessionID: String,
        messageID: String,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        let requestID = UUID()
        try await dispatchCommand(
            requestID: requestID,
            event: try QueuedMessageSteerCommand(
                requestID: requestID,
                sessionID: sessionID,
                messageID: messageID
            ).event,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
    }

    private func dispatchCommand(
        requestID: UUID,
        event: String,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws {
        guard !isMutationInFlight else {
            throw WorkspaceUIHook.DispatchError.mutationInFlight
        }
        isMutationInFlight = true
        defer { isMutationInFlight = false }

        let (results, continuation) = try enqueueCommand(
            requestID: requestID,
            event: event
        )
        defer {
            continuation.finish()
            pendingCommands[requestID] = nil
        }

        for try await _ in results {
            try await waitUntilChangeAvailableInDatabase()
            return
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
    }

    private func dispatch(
        event: String,
        fallback: (@Sendable () async throws -> Void)?,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void,
        enqueuedCreationID: Workspace.ID? = nil
    ) async throws -> WorkspaceUIHook.DispatchPath {
        // Serialize mutations so late persistence cannot reorder two commands.
        guard !isMutationInFlight else {
            throw WorkspaceUIHook.DispatchError.mutationInFlight
        }
        isMutationInFlight = true
        defer { isMutationInFlight = false }

        // Fall back only when delivery has not happened or yield proves it could not happen.
        guard let connection = activeConnection else {
            guard let fallback else {
                throw WorkspaceUIHook.DispatchError.listenerUnavailable
            }
            try await fallback()
            return .sqliteFallback
        }

        switch connection.continuation.yield(event) {
        case .enqueued:
            if let enqueuedCreationID {
                dispatchedCreationIDs.insert(enqueuedCreationID)
            }
            // Never fall back after enqueue because failure cannot prove the browser did not apply it.
            try await waitUntilChangeAvailableInDatabase()
            return .hook
        case .dropped, .terminated:
            disconnect(connectionID: connection.id)
            guard let fallback else {
                throw WorkspaceUIHook.DispatchError.listenerUnavailable
            }
            try await fallback()
            return .sqliteFallback
        @unknown default:
            disconnect(connectionID: connection.id)
            throw WorkspaceUIHook.DispatchError.deliveryUnknown
        }
    }

    private func enqueueCommand(
        requestID: UUID,
        event: String,
        kind: PendingCommand.Kind = .command
    ) throws -> (
        results: AsyncThrowingStream<PendingResult, any Error>,
        continuation: AsyncThrowingStream<PendingResult, any Error>.Continuation
    ) {
        guard let connection = activeConnection else {
            throw WorkspaceUIHook.CommandDispatchError.listenerUnavailable
        }

        let (results, continuation) = AsyncThrowingStream<PendingResult, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pendingCommands[requestID] = PendingCommand(
            continuation: continuation,
            kind: kind
        )

        switch connection.continuation.yield(event) {
        case .dropped, .terminated:
            pendingCommands[requestID] = nil
            continuation.finish()
            disconnect(connectionID: connection.id)
            throw WorkspaceUIHook.CommandDispatchError.listenerUnavailable
        case .enqueued:
            return (results, continuation)
        @unknown default:
            pendingCommands[requestID] = nil
            continuation.finish()
            disconnect(connectionID: connection.id)
            throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
        }
    }

    private struct ConnectionState {
        let continuation: AsyncStream<String>.Continuation
        let id: UUID
    }

    private struct PendingCommand {
        let continuation: AsyncThrowingStream<PendingResult, any Error>.Continuation
        let kind: Kind

        enum Kind: Equatable {
            case command
            case message
            case queuedMessage
        }
    }

    private enum PendingResult: Sendable {
        case completed
        case message(Message.ID)
    }

    private enum StopEvent: Sendable {
        case accepted
        case deliveryUnknown
        case persisted(Session)
        case persistenceTimedOut
        case rejected(String)
    }

    private struct MessageCommand: Encodable {
        let requestID: UUID
        let sessionID: Session.ID
        let workspaceID: Workspace.ID
        let sendMessage: SendMessage

        struct SendMessage: Encodable {
            let attemptID: UUID
            let content: String
            let mode: WorkspaceUIHook.MessageMode
            let reasoningEffort: Session.ReasoningEffort?

            private enum CodingKeys: String, CodingKey {
                case attemptID = "attemptId"
                case content
                case mode
                case reasoningEffort
            }
        }

        private enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
            case sessionID = "sessionId"
            case workspaceID = "workspaceId"
            case sendMessage
        }
    }

    private static func messageEvent(
        requestID: UUID,
        attemptID: UUID,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        content: String,
        mode: WorkspaceUIHook.MessageMode,
        reasoningEffort: Session.ReasoningEffort?
    ) throws -> String {
        let command = MessageCommand(
            requestID: requestID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            sendMessage: MessageCommand.SendMessage(
                attemptID: attemptID,
                content: content,
                mode: mode,
                reasoningEffort: reasoningEffort
            )
        )
        let data = try JSONEncoder().encode(command)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private static func stopSessionEvent(requestID: UUID, sessionID: Session.ID) throws -> String {
        let requestID = try UIHookCommand.jsonString(requestID.uuidString)
        let sessionID = try UIHookCommand.jsonString(sessionID)
        return "data: {\"requestId\":\(requestID),\"sessionId\":\(sessionID),\"stopSession\":true}\n\n"
    }

    private static func sessionModelEvent(
        sessionID: Session.ID,
        model: Session.Model
    ) throws -> String {
        let sessionID = try UIHookCommand.jsonString(sessionID)
        let model = try UIHookCommand.jsonString(model.rawValue)
        return "data: {\"sessionId\":\(sessionID),\"model\":\(model)}\n\n"
    }

    private static func sessionAgentAndModelEvent(
        sessionID: Session.ID,
        agentType: Session.AgentType,
        model: Session.Model
    ) throws -> String {
        let sessionID = try UIHookCommand.jsonString(sessionID)
        let agentType = try UIHookCommand.jsonString(agentType.rawValue)
        let model = try UIHookCommand.jsonString(model.rawValue)
        return "data: {\"sessionId\":\(sessionID),\"agentAndModel\":{\"agentType\":\(agentType),\"model\":\(model)}}\n\n"
    }

    private static func createWorkspaceEvent(_ command: CreateWorkspaceCommand) throws -> String {
        let data = try JSONEncoder().encode(CreateWorkspaceEvent(createWorkspace: command))
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private struct CreateWorkspaceEvent: Encodable {
        let createWorkspace: CreateWorkspaceCommand
    }
}

struct CreateWorkspaceCommand: Codable, Equatable, Sendable {
    let repositoryID: Repository.ID
    let workspaceID: Workspace.ID
    let agentType: String
    let model: String

    private enum CodingKeys: String, CodingKey {
        case repositoryID = "repositoryId"
        case workspaceID = "workspaceId"
        case agentType
        case model
    }
}

private struct QueueOrderCommand: Encodable {
    let requestID: UUID
    let sessionID: String
    let messageIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case messageIDs = "orderedIds"
    }

    var event: String {
        get throws {
            let data = try JSONEncoder().encode(self)
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
    }
}

private struct QueuePauseCommand: Encodable {
    let requestID: UUID
    let sessionID: String
    let isPaused: Bool

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case isPaused = "queuePaused"
    }

    var event: String {
        get throws {
            let data = try JSONEncoder().encode(self)
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
    }
}

private struct QueuedMessageEditCommand: Encodable {
    let requestID: UUID
    let sessionID: String
    let edit: Edit

    struct Edit: Encodable {
        let messageID: String
        let content: String
        let shouldResumeQueue: Bool

        private enum CodingKeys: String, CodingKey {
            case messageID = "messageId"
            case content
            case shouldResumeQueue = "resumeQueue"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case edit = "queuedMessageEdit"
    }

    var event: String {
        get throws {
            let data = try JSONEncoder().encode(self)
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
    }
}

private struct QueuedMessageDeleteCommand: Encodable {
    let requestID: UUID
    let sessionID: String
    let messageID: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case messageID = "deleteQueuedMessage"
    }

    var event: String {
        get throws {
            let data = try JSONEncoder().encode(self)
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
    }
}

private struct QueuedMessageSteerCommand: Encodable {
    let requestID: UUID
    let sessionID: String
    let messageID: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case messageID = "steerQueuedMessage"
    }

    var event: String {
        get throws {
            let data = try JSONEncoder().encode(self)
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
    }
}

private extension UIHookCommand {
    func event(requestID: UUID? = nil) throws -> String {
        let requestIDPayload = try requestID.map {
            "\"requestId\":\(try Self.jsonString($0.uuidString)),"
        } ?? ""
        let payload: String = switch self {
        case let .session(sessionID, workspaceID, mutation):
            "\"sessionId\":\(try Self.jsonString(sessionID)),\"workspaceId\":\(try Self.jsonString(workspaceID)),\(try mutation.field)"
        case let .workspace(workspaceID, mutation):
            "\"workspaceId\":\(try Self.jsonString(workspaceID)),\(try mutation.field)"
        case let .sessionFastMode(sessionID, isEnabled):
            "\"sessionId\":\(try Self.jsonString(sessionID)),\"fastMode\":\(isEnabled)"
        }
        return "data: {\(requestIDPayload)\(payload)}\n\n"
    }

    // JSONEncoder escapes values even though the surrounding SSE frame is assembled directly.
    static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func getCreateSessionEventName(workspaceID: String) throws -> String {
        "data: {\"workspaceId\":\(try jsonString(workspaceID)),\"createSession\":true}\n\n"
    }
}

private extension SessionMutation {
    var field: String {
        get throws {
            switch self {
            case let .hidden(isHidden):
                "\"hidden\":\(isHidden)"
            case .title(let title):
                "\"title\":\(try UIHookCommand.jsonString(title))"
            }
        }
    }
}

private extension WorkspaceMutation {
    var field: String {
        get throws {
            switch self {
            case .archive:
                "\"archive\":true"
            case .branch(let branch):
                "\"branch\":\(try UIHookCommand.jsonString(branch))"
            case .pinned(let isPinned):
                "\"pinned\":\(isPinned)"
            case .status(let value):
                "\"status\":\(try UIHookCommand.jsonString(value))"
            case .unread(let isUnread):
                "\"unread\":\(isUnread)"
            }
        }
    }
}
