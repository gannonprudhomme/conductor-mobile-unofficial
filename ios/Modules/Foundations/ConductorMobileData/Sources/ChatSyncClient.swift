//
//  ChatSyncClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorCloud
import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import SQLiteData

public enum ChatSyncEvent: Sendable {
    case ready
    case failure(any Error & Sendable)
}

@DependencyClient
public struct ChatSyncClient: Sendable {
    public var runForeground: @Sendable () async -> Void = { }
    public var observeSelected: @Sendable (_ sessionID: Session.ID) -> AsyncStream<ChatSyncEvent> = { _ in
        AsyncStream { $0.finish() }
    }
}

extension ChatSyncClient: DependencyKey {
    public static var liveValue: Self {
        live()
    }

    public static func live() -> Self {
        let coordinator = ChatSyncCoordinator()
        return Self {
            await coordinator.runForeground()
        } observeSelected: { sessionID in
            coordinator.observeSelected(sessionID: sessionID)
        }
    }
}

public extension DependencyValues {
    var chatSyncClient: ChatSyncClient {
        get { self[ChatSyncClient.self] }
        set { self[ChatSyncClient.self] = newValue }
    }
}

private actor ChatSyncCoordinator {
    private typealias Observer = (continuation: AsyncStream<ChatSyncEvent>.Continuation, isReady: Bool)

    private struct Route: Sendable {
        let sessionID: Session.ID
        let workspaceID: Workspace.ID
        let isCloudHosted: Bool
    }

    private var foregroundSessionsByWorkspace: [Workspace.ID: Set<Session.ID>] = [:]
    private var observers: [Session.ID: [UUID: Observer]] = [:]
    private var transcriptTasks: [Session.ID: Task<Void, Never>] = [:]
    private var workspaceTasks: [Workspace.ID: (workspace: Workspace, task: Task<Void, Never>)] = [:]

    nonisolated func observeSelected(sessionID: Session.ID) -> AsyncStream<ChatSyncEvent> {
        AsyncStream { continuation in
            let observerID = UUID()
            let registration = Task {
                await self.addSelected(
                    observerID: observerID,
                    sessionID: sessionID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task {
                    registration.cancel()
                    await self.removeSelected(
                        observerID: observerID,
                        sessionID: sessionID
                    )
                }
            }
        }
    }

    func runForeground() async {
        @Dependency(\.continuousClock) var clock

        while !Task.isCancelled {
            try? await reconcileForeground()
            do {
                try await clock.sleep(for: .seconds(5))
            } catch {
                break
            }
        }
        stopForeground()
    }

    private func reconcileForeground() async throws {
        @Dependency(\.defaultDatabase) var database

        let workspaces = try await database.read {
            try Workspace.chatSyncPrefetchCandidates(in: $0)
        }
        let workspaceIDs = Set(workspaces.map(\.id))

        for workspaceID in Array(workspaceTasks.keys) where !workspaceIDs.contains(workspaceID) {
            removeWorkspace(workspaceID)
        }

        for workspace in workspaces {
            if let observation = workspaceTasks[workspace.id],
               observation.workspace.isCloudHosted == workspace.isCloudHosted {
                continue
            }
            removeWorkspace(workspace.id)
            workspaceTasks[workspace.id] = (
                workspace,
                Task { await self.observeSessions(workspace) }
            )
        }
    }

    private func stopForeground() {
        for workspaceID in Array(workspaceTasks.keys) {
            removeWorkspace(workspaceID)
        }
    }

    private func removeWorkspace(_ workspaceID: Workspace.ID) {
        workspaceTasks.removeValue(forKey: workspaceID)?.task.cancel()
        let sessionIDs = foregroundSessionsByWorkspace.removeValue(forKey: workspaceID) ?? []
        for sessionID in sessionIDs {
            stopTranscriptIfUnused(sessionID: sessionID)
        }
    }

    private func observeSessions(_ workspace: Workspace) async {
        if workspace.isCloudHosted {
            await observeCloudSessions(workspaceID: workspace.id)
        } else {
            await observeLocalSessions(workspaceID: workspace.id)
        }
        guard !Task.isCancelled else {
            return
        }
        removeWorkspace(workspace.id)
    }

    private func observeLocalSessions(workspaceID: Workspace.ID) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.desktopClient) var desktopClient

        await StreamObservation.observe {
            desktopClient.observeSessions(workspaceID: workspaceID)
        } onValue: { sessions in
            try await database.write { database in
                try Session.where { $0.workspaceID.eq(workspaceID) }
                    .delete().execute(database)
                try Session.upsert { sessions }.execute(database)
            }
            await self.setForegroundSessions(
                sessions.filter { !$0.isHidden }.map(\.id),
                workspaceID: workspaceID
            )
        } onFailure: { _ in }
    }

    private func observeCloudSessions(workspaceID: Workspace.ID) async {
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
            await self.setForegroundSessions(
                sessions.filter { !$0.isHidden }.map(\.id),
                workspaceID: workspaceID
            )
        } onFailure: { _ in }
    }

    private func setForegroundSessions(_ sessionIDs: [Session.ID], workspaceID: Workspace.ID) async {
        let nextSessionIDs = Set(sessionIDs)
        let oldSessionIDs = foregroundSessionsByWorkspace[workspaceID] ?? []
        foregroundSessionsByWorkspace[workspaceID] = nextSessionIDs

        for sessionID in oldSessionIDs.subtracting(nextSessionIDs) {
            stopTranscriptIfUnused(sessionID: sessionID)
        }
        for sessionID in nextSessionIDs {
            ensureTranscript(sessionID: sessionID)
        }
    }

    private func addSelected(
        observerID: UUID,
        sessionID: Session.ID,
        continuation: AsyncStream<ChatSyncEvent>.Continuation
    ) async {
        let isReady = await isCacheReady(sessionID: sessionID)
        observers[sessionID, default: [:]][observerID] = (continuation, isReady)
        if isReady {
            continuation.yield(.ready)
        }
        ensureTranscript(sessionID: sessionID)
    }

    private func removeSelected(observerID: UUID, sessionID: Session.ID) {
        observers[sessionID]?[observerID] = nil
        if observers[sessionID]?.isEmpty == true {
            observers[sessionID] = nil
        }
        stopTranscriptIfUnused(sessionID: sessionID)
    }

    private func ensureTranscript(sessionID: Session.ID) {
        guard transcriptTasks[sessionID] == nil else {
            return
        }
        transcriptTasks[sessionID] = Task {
            await self.observeTranscript(sessionID: sessionID)
        }
    }

    private func stopTranscriptIfUnused(sessionID: Session.ID) {
        guard observers[sessionID]?.isEmpty != false,
              !foregroundSessionsByWorkspace.values.contains(where: { $0.contains(sessionID) })
        else {
            return
        }
        transcriptTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func observeTranscript(sessionID: Session.ID) async {
        do {
            let route = try await route(for: sessionID)
            if route.isCloudHosted {
                await observeCloudTranscript(route)
            } else {
                await observeLocalTranscript(route)
            }
        } catch {
            failSelected(sessionID: sessionID, error: ChatSyncError.missingSession)
        }
        guard !Task.isCancelled else {
            return
        }
        transcriptTasks[sessionID] = nil
    }

    private func observeLocalTranscript(_ route: Route) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.desktopClient) var desktopClient

        await StreamObservation.observe {
            desktopClient.observeMessages(
                workspaceID: route.workspaceID,
                sessionID: route.sessionID
            )
        } onValue: { observation in
            let event: MessageSyncEvent
            switch observation {
            case let .persisted(persisted):
                event = persisted

            case let .requiresPersistence(unpersisted):
                event = try await DesktopTranscriptStore.applySyncEvent(
                    unpersisted,
                    workspaceID: route.workspaceID,
                    sessionID: route.sessionID,
                    database: database
                )
            }
            if event.isSnapshot {
                await self.markReady(sessionID: route.sessionID)
            }
        } onFailure: { _ in }
    }

    private func observeCloudTranscript(_ route: Route) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.cloudAPIClient) var cloudAPIClient

        do {
            let cache = try await database.read { database in
                try CloudChatPersistence.cachedTranscript(
                    for: route.sessionID,
                    in: database
                )
            }
            if cache.checkpoint != nil {
                await markReady(sessionID: route.sessionID)
            }
            await StreamObservation.observe(
                retrying: {
                    cloudAPIClient.observeTranscript(
                        sessionID: cache.remoteSessionID,
                        workspaceID: route.workspaceID,
                        checkpoint: cache.checkpoint
                    )
                },
                shouldRetry: {
                    CloudAPIClientError.shouldRetryObservation(after: $0)
                }
            ) { update in
                _ = try await database.write { database in
                    try CloudChatPersistence.persist(update, in: database)
                }
                if update.kind == .complete {
                    await self.markReady(sessionID: route.sessionID)
                }
            } onFailure: { error in
                guard !CloudAPIClientError.shouldRetryObservation(after: error) else { return }
                await self.failSelected(
                    sessionID: route.sessionID,
                    error: ChatSyncError.transcriptFailed
                )
            }
        } catch {
            failSelected(sessionID: route.sessionID, error: ChatSyncError.transcriptFailed)
        }
    }

    private func markReady(sessionID: Session.ID) {
        guard var sessionObservers = observers[sessionID] else {
            return
        }
        let observerIDs = sessionObservers.compactMap { observerID, observer in
            observer.isReady ? nil : observerID
        }
        for observerID in observerIDs {
            sessionObservers[observerID]?.continuation.yield(.ready)
            sessionObservers[observerID]?.isReady = true
        }
        observers[sessionID] = sessionObservers
    }

    private func failSelected(sessionID: Session.ID, error: any Error & Sendable) {
        guard let sessionObservers = observers.removeValue(forKey: sessionID) else {
            return
        }
        for observer in sessionObservers.values {
            observer.continuation.yield(.failure(error))
            observer.continuation.finish()
        }
    }

    private func isCacheReady(sessionID: Session.ID) async -> Bool {
        do {
            let route = try await route(for: sessionID)
            @Dependency(\.defaultDatabase) var database
            if route.isCloudHosted {
                return try await database.read { database in
                    try CloudChatPersistence.cachedTranscript(for: sessionID, in: database)
                        .checkpoint != nil
                }
            }
            return try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                workspaceID: route.workspaceID,
                sessionID: sessionID,
                database: database
            ) != nil
        } catch {
            return false
        }
    }

    private func route(for sessionID: Session.ID) async throws -> Route {
        @Dependency(\.defaultDatabase) var database

        return try await database.read { database in
            guard let session = try Session.find(sessionID).fetchOne(database),
                  let workspace = try Workspace.find(session.workspaceID).fetchOne(database)
            else {
                throw ChatSyncError.missingSession
            }
            return Route(
                sessionID: sessionID,
                workspaceID: session.workspaceID,
                isCloudHosted: workspace.isCloudHosted
            )
        }
    }
}

extension Workspace {
    static func chatSyncPrefetchCandidates(
        in database: Database
    ) throws -> [Workspace] {
        try Self
            .where {
                let state = #sql("coalesce(\($0.state), '')", as: String.self)
                return state.neq(State.archiving.rawValue)
                    && state.neq(State.archived.rawValue)
            }
            .order { ($0.updatedAt.desc(), $0.id) }
            .limit(30)
            .fetchAll(database)
    }
}

private enum ChatSyncError: Error, Sendable {
    case missingSession
    case transcriptFailed
}
