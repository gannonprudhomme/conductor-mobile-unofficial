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
    var disconnect: @Sendable (_ connectionID: UUID) async -> Void
    var dispatch: @Sendable (
        _ mutation: WorkspaceMutation,
        _ workspaceID: String,
        _ fallback: @escaping @Sendable () async throws -> Void,
        _ waitUntilChangeAvailableInDatabase: @escaping @Sendable () async throws -> Void
    ) async throws -> DispatchPath
    var listenerUnavailable: @Sendable () async -> Void
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
        case mutationInFlight
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
            disconnect: { connectionID in
                await state.disconnect(connectionID: connectionID)
            },
            dispatch: { mutation, workspaceID, fallback, waitUntilChangeAvailableInDatabase in
                try await state.dispatch(
                    mutation,
                    workspaceID: workspaceID,
                    fallback: fallback,
                    waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
                )
            },
            listenerUnavailable: { await state.listenerUnavailable() },
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

private actor WorkspaceUIHookState {
    private var activeConnection: ConnectionState?
    private var isMutationInFlight = false

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
    }

    func listenerUnavailable() {
        guard let connectionID = activeConnection?.id else {
            return
        }
        disconnect(connectionID: connectionID)
    }

    /// Serializes UI mutations while coordinating browser-hook delivery with SQLite.
    ///
    /// If no active listener can accept the event, this performs `fallback`. Once an event is
    /// enqueued, it waits for `waitUntilChangeAvailableInDatabase` and never falls back because
    /// Conductor may already have applied the mutation. Injecting both operations keeps this actor
    /// independent of persistence details.
    func dispatch(
        _ mutation: WorkspaceMutation,
        workspaceID: String,
        fallback: @Sendable () async throws -> Void = {},
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> WorkspaceUIHook.DispatchPath {
        try await dispatch(
            event: mutation.getEventName(workspaceID: workspaceID),
            fallback: fallback,
            waitUntilChangeAvailableInDatabase: waitUntilChangeAvailableInDatabase
        )
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

    private func dispatch(
        event: String,
        fallback: @Sendable () async throws -> Void,
        waitUntilChangeAvailableInDatabase: @Sendable () async throws -> Void
    ) async throws -> WorkspaceUIHook.DispatchPath {
        // Serialize mutations so late persistence cannot reorder two commands.
        guard !isMutationInFlight else {
            throw WorkspaceUIHook.DispatchError.mutationInFlight
        }
        isMutationInFlight = true
        defer { isMutationInFlight = false }

        // Fall back only when delivery has not happened or yield proves it could not happen.
        guard let connection = activeConnection else {
            try await fallback()
            return .sqliteFallback
        }

        switch connection.continuation.yield(event) {
        case .enqueued:
            // Never fall back after enqueue because failure cannot prove the browser did not apply it.
            try await waitUntilChangeAvailableInDatabase()
            return .hook
        case .dropped, .terminated:
            disconnect(connectionID: connection.id)
            try await fallback()
            return .sqliteFallback
        @unknown default:
            disconnect(connectionID: connection.id)
            throw WorkspaceUIHook.DispatchError.deliveryUnknown
        }
    }

    private struct ConnectionState {
        let continuation: AsyncStream<String>.Continuation
        let id: UUID
    }

    private static func sessionModelEvent(
        sessionID: Session.ID,
        model: Session.Model
    ) throws -> String {
        let sessionID = try WorkspaceMutation.jsonString(sessionID)
        let model = try WorkspaceMutation.jsonString(model.rawValue)
        return "data: {\"sessionId\":\(sessionID),\"model\":\(model)}\n\n"
    }
}

private extension WorkspaceMutation {
    func getEventName(workspaceID: String) throws -> String {
        let workspaceID = try Self.jsonString(workspaceID)
        let field: String = switch self {
        case .pinned(let isPinned):
            "\"pinned\":\(isPinned)"
        case .status(let value):
            "\"status\":\(try Self.jsonString(value))"
        case .unread(let isUnread):
            "\"unread\":\(isUnread)"
        }
        return "data: {\"workspaceId\":\(workspaceID),\(field)}\n\n"
    }

    // JSONEncoder escapes values even though the surrounding SSE frame is assembled directly.
    static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
