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
    var dispatch: @Sendable (
        _ command: UIHookCommand,
        _ fallback: @escaping @Sendable () async throws -> Void,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> DispatchPath
    var listenerUnavailable: @Sendable () async -> Void
    var sendMessage: @Sendable (
        _ requestID: UUID,
        _ attemptID: UUID,
        _ sessionID: Session.ID,
        _ workspaceID: Workspace.ID,
        _ content: String,
        _ mode: MessageMode
    ) async throws -> MessageReceipt
    var stopSession: @Sendable (
        _ requestID: UUID,
        _ sessionID: Session.ID,
        _ waitUntilStopped: @escaping @Sendable () async throws -> Session?
    ) async throws -> Session
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

    enum MessageMode: String, Encodable, Sendable {
        case queued
        case sent
    }

    struct MessageReceipt: Equatable, Sendable {
        let messageID: String
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
            let state: String?

            private enum CodingKeys: String, CodingKey {
                case type
                case messageID = "messageId"
                case reason
                case state
            }
        }

        enum ResultType: String, Decodable, Sendable {
            case accepted
            case rejected
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
        live(clock: ContinuousClock())
    }

    static func live(clock: some Clock<Duration>) -> Self {
        let state = WorkspaceUIHookState(clock: clock)
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
            dispatch: { command, fallback, waitUntilChangeAvailableInDatabase in
                try await state.dispatch(
                    command,
                    fallback: fallback,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            listenerUnavailable: { await state.listenerUnavailable() },
            sendMessage: { requestID, attemptID, sessionID, workspaceID, content, mode in
                try await state.sendMessage(
                    requestID: requestID,
                    attemptID: attemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
            },
            stopSession: { requestID, sessionID, waitUntilStopped in
                try await state.stopSession(
                    requestID: requestID,
                    sessionID: sessionID,
                    waitUntilStopped: waitUntilStopped
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

extension WorkspaceUIHook {
    func sendMessage(
        requestID: UUID,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        content: String,
        mode: MessageMode
    ) async throws -> MessageReceipt {
        try await sendMessage(
            requestID,
            requestID,
            sessionID,
            workspaceID,
            content,
            mode
        )
    }
}

private actor WorkspaceUIHookState {
    private let clock: AnyClock<Duration>
    private var activeConnection: ConnectionState?
    private var dispatchedCreationIDs: Set<Workspace.ID> = []
    private var isMutationInFlight = false
    private var pendingCommands: [UUID: PendingCommand] = [:]

    init(clock: any Clock<Duration>) {
        self.clock = AnyClock(clock)
    }

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
    /// If no active listener can accept the event, this performs `fallback`. Once an event is
    /// enqueued, it waits for `waitUntilChangeAvailableInDatabase` and never falls back because
    /// Conductor may already have applied the mutation. Injecting both operations keeps this actor
    /// independent of persistence details.
    func dispatch(
        _ command: UIHookCommand,
        fallback: @escaping @Sendable () async throws -> Void = {},
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> WorkspaceUIHook.DispatchPath {
        try await dispatch(
            event: try command.event,
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

        guard command.deadline.map({ clock.now < $0 }) ?? true else {
            pendingCommands[result.requestID] = nil
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
            )
            return false
        }

        pendingCommands[result.requestID] = nil

        if command.kind == .message, let result = result.result {
            switch result.type {
            case .accepted:
                guard let messageID = result.messageID,
                      !messageID.isEmpty,
                      result.state == "sent" else {
                    command.continuation.finish(
                        throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                    )
                    return true
                }
                command.continuation.yield(
                    .message(.init(messageID: messageID))
                )
                command.continuation.finish()
            case .rejected:
                command.continuation.finish(
                    throwing: WorkspaceUIHook.CommandDispatchError.commandFailed(
                        result.reason ?? "Conductor rejected the message."
                    )
                )
            }
        } else if let error = result.error {
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.commandFailed(error)
            )
        } else if command.kind == .message {
            command.continuation.finish(
                throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
            )
        } else {
            command.continuation.yield(.completed)
            command.continuation.finish()
        }
        return true
    }

    func sendMessage(
        requestID: UUID,
        attemptID: UUID,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        content: String,
        mode: WorkspaceUIHook.MessageMode
    ) async throws -> WorkspaceUIHook.MessageReceipt {
        let event = try Self.messageEvent(
            requestID: requestID,
            attemptID: attemptID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            content: content,
            mode: mode
        )
        let deadline = clock.now.advanced(by: .seconds(5))
        let (results, continuation) = try enqueueCommand(
            requestID: requestID,
            event: event,
            deadline: deadline,
            kind: .message
        )
        Task { [weak self, clock] in
            try? await clock.sleep(until: deadline)
            await self?.expireCommand(requestID: requestID)
        }
        defer {
            continuation.finish()
            pendingCommands[requestID] = nil
        }

        do {
            for try await result in results {
                guard case .message(let receipt) = result else {
                    throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
                }
                return receipt
            }
        } catch {
            throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
        }
        throw WorkspaceUIHook.CommandDispatchError.deliveryUnknown
    }

    private func expireCommand(requestID: UUID) {
        guard let command = pendingCommands.removeValue(forKey: requestID) else {
            return
        }
        command.continuation.finish(
            throwing: WorkspaceUIHook.CommandDispatchError.deliveryUnknown
        )
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
            deadline: nil,
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
        deadline: AnyClock<Duration>.Instant?,
        kind: PendingCommand.Kind
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
            deadline: deadline,
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
        let deadline: AnyClock<Duration>.Instant?
        let kind: Kind

        enum Kind: Equatable {
            case command
            case message
        }
    }

    private enum PendingResult: Sendable {
        case completed
        case message(WorkspaceUIHook.MessageReceipt)
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
            let content: String
            let mode: WorkspaceUIHook.MessageMode

            private enum CodingKeys: String, CodingKey {
                case attemptID = "attemptId"
                case content
                case mode
            }

            let attemptID: UUID
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
        mode: WorkspaceUIHook.MessageMode
    ) throws -> String {
        let command = MessageCommand(
            requestID: requestID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            sendMessage: MessageCommand.SendMessage(
                content: content,
                mode: mode,
                attemptID: attemptID
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

private extension UIHookCommand {
    var event: String {
        get throws {
            let payload: String = switch self {
            case let .workspace(workspaceID, mutation):
                "\"workspaceId\":\(try Self.jsonString(workspaceID)),\(try mutation.field)"
            case let .sessionFastMode(sessionID, isEnabled):
                "\"sessionId\":\(try Self.jsonString(sessionID)),\"fastMode\":\(isEnabled)"
            }
            return "data: {\(payload)}\n\n"
        }
    }

    // JSONEncoder escapes values even though the surrounding SSE frame is assembled directly.
    static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func getCreateSessionEventName(workspaceID: String) throws -> String {
        "data: {\"workspaceId\":\(try jsonString(workspaceID)),\"createSession\":true}\n\n"
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
