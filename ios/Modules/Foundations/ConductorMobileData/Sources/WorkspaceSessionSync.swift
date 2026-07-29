//
//  WorkspaceSessionSync.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorCloud
import Dependencies
import Foundation
import SharedConductorData
import SQLiteData

public enum WorkspaceSessionSyncEvent: Sendable {
    case snapshot([Session])
    case failure(any Error & Sendable)
}

public enum WorkspaceSessionPersistence {
    @discardableResult
    public static func reconcileLocalSnapshot(
        _ sessions: [Session],
        workspaceID: Workspace.ID,
        in database: Database
    ) throws -> [Session] {
        let workspaceSessions = sessions.filter {
            $0.workspaceID == workspaceID
        }
        let currentIDs = Set(workspaceSessions.map(\.id))
        let existingSessions = try Session
            .where { $0.workspaceID.eq(workspaceID) }
            .fetchAll(database)

        try Session.upsert { workspaceSessions }
            .execute(database)

        for session in existingSessions where !currentIDs.contains(session.id) {
            try Session.find(session.id)
                .delete()
                .execute(database)
        }
        return workspaceSessions
    }
}

public enum WorkspaceSessionObservation {
    public static func observe(
        workspace: Workspace
    ) -> AsyncStream<WorkspaceSessionSyncEvent> {
        observe(
            workspaceID: workspace.id,
            isCloudHosted: workspace.isCloudHosted
        )
    }

    public static func observe(
        workspaceID: Workspace.ID,
        isCloudHosted: Bool
    ) -> AsyncStream<WorkspaceSessionSyncEvent> {
        WorkspaceSessionObservationStore.shared.observe(
            workspaceID: workspaceID,
            isCloudHosted: isCloudHosted
        )
    }
}

private actor WorkspaceSessionObservationStore {
    static let shared = WorkspaceSessionObservationStore()

    private struct Key: Hashable {
        let workspaceID: Workspace.ID
        let isCloudHosted: Bool
    }

    private struct Entry {
        let id: UUID
        var continuations: [
            UUID: AsyncStream<WorkspaceSessionSyncEvent>.Continuation
        ] = [:]
        var latestSessions: [Session]?
        let task: Task<Void, Never>
    }

    private var entries: [Key: Entry] = [:]

    nonisolated func observe(
        workspaceID: Workspace.ID,
        isCloudHosted: Bool
    ) -> AsyncStream<WorkspaceSessionSyncEvent> {
        let key = Key(
            workspaceID: workspaceID,
            isCloudHosted: isCloudHosted
        )
        return AsyncStream { continuation in
            let observerID = UUID()
            let registration = Task {
                await self.add(
                    observerID: observerID,
                    key: key,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task {
                    registration.cancel()
                    await self.remove(observerID: observerID, key: key)
                }
            }
        }
    }

    private func add(
        observerID: UUID,
        key: Key,
        continuation: AsyncStream<WorkspaceSessionSyncEvent>.Continuation
    ) {
        guard !Task.isCancelled else {
            return
        }
        if entries[key] == nil {
            let entryID = UUID()
            entries[key] = Entry(
                id: entryID,
                task: Task {
                    await self.run(
                        workspaceID: key.workspaceID,
                        isCloudHosted: key.isCloudHosted,
                        key: key,
                        entryID: entryID
                    )
                }
            )
        }
        entries[key]?.continuations[observerID] = continuation
        if let latestSessions = entries[key]?.latestSessions {
            continuation.yield(.snapshot(latestSessions))
        }
    }

    private func remove(observerID: UUID, key: Key) {
        entries[key]?.continuations[observerID] = nil
        guard entries[key]?.continuations.isEmpty == true else {
            return
        }
        entries.removeValue(forKey: key)?.task.cancel()
    }

    private func run(
        workspaceID: Workspace.ID,
        isCloudHosted: Bool,
        key: Key,
        entryID: UUID
    ) async {
        if isCloudHosted {
            await observeCloudSessions(
                workspaceID: workspaceID,
                key: key,
                entryID: entryID
            )
        } else {
            await observeLocalSessions(
                workspaceID: workspaceID,
                key: key,
                entryID: entryID
            )
        }
        finish(key: key, entryID: entryID)
    }

    private func observeLocalSessions(
        workspaceID: Workspace.ID,
        key: Key,
        entryID: UUID
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.desktopClient) var desktopClient

        await StreamObservation.observe {
            desktopClient.observeSessions(workspaceID: workspaceID)
        } onValue: { sessions in
            let sessions = try await database.write { database in
                try WorkspaceSessionPersistence.reconcileLocalSnapshot(
                    sessions,
                    workspaceID: workspaceID,
                    in: database
                )
            }
            self.publish(
                .snapshot(sessions),
                key: key,
                entryID: entryID
            )
        } onFailure: { error in
            self.publish(
                .failure(sendableObservationError(error)),
                key: key,
                entryID: entryID
            )
        }
    }

    private func observeCloudSessions(
        workspaceID: Workspace.ID,
        key: Key,
        entryID: UUID
    ) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.cloudAPIClient) var cloudAPIClient

        await StreamObservation.observe(
            retrying: {
                cloudAPIClient.observeSessions(workspaceID: workspaceID)
            },
            shouldRetry: {
                CloudAPIClientError.shouldRetryObservation(after: $0)
            }
        ) { snapshot in
            let sessions = try await database.write { database in
                try CloudChatPersistence.persist(snapshot, in: database)
            }
            self.publish(
                .snapshot(sessions),
                key: key,
                entryID: entryID
            )
        } onFailure: { error in
            self.publish(
                .failure(sendableObservationError(error)),
                key: key,
                entryID: entryID
            )
        }
    }

    private func publish(
        _ event: WorkspaceSessionSyncEvent,
        key: Key,
        entryID: UUID
    ) {
        guard entries[key]?.id == entryID else {
            return
        }
        if case let .snapshot(sessions) = event {
            entries[key]?.latestSessions = sessions
        }
        guard let continuations = entries[key]?.continuations.values else {
            return
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func finish(key: Key, entryID: UUID) {
        guard entries[key]?.id == entryID else {
            return
        }
        let entry = entries.removeValue(forKey: key)
        guard let continuations = entry?.continuations.values else {
            return
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}

func sendableObservationError(_ error: any Error) -> any Error & Sendable {
    if let error = error as? CloudAPIClientError {
        return error
    }
    if let error = error as? DesktopClientError {
        return error
    }
    if let error = error as? URLError {
        return error
    }
    return NonSendableObservationError(error)
}

private struct NonSendableObservationError: LocalizedError, Sendable {
    let message: String

    init(_ error: any Error) {
        self.message = error.localizedDescription
    }

    var errorDescription: String? {
        message
    }
}
