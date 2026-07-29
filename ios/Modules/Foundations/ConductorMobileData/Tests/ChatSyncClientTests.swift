//
//  ChatSyncClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorCloud
import Dependencies
import Foundation
import SharedConductorData
import SQLiteData
@testable import ConductorMobileData
import Testing

@MainActor
struct ChatSyncClientTests {
    @Test("Workspace query excludes archived states, orders by activity, and caps at 30")
    func workspaceCandidates() throws {
        let database = try appDatabase()
        let tieDate = Date(timeIntervalSince1970: 2_000)
        try database.write { database in
            for workspace in [
                Workspace.preview(
                    id: "tie-b",
                    updatedAt: tieDate
                ),
                Workspace.preview(
                    id: "tie-a",
                    updatedAt: tieDate
                ),
                Workspace.preview(
                    id: "archived",
                    state: .archived,
                    updatedAt: tieDate.addingTimeInterval(100)
                ),
                Workspace.preview(
                    id: "archiving",
                    state: .archiving,
                    updatedAt: tieDate.addingTimeInterval(100)
                ),
            ] {
                try Workspace.insert { workspace }.execute(database)
            }
            for index in 0..<35 {
                try Workspace
                    .insert {
                        Workspace.preview(
                            id: "workspace-\(index)",
                            updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                        )
                    }
                    .execute(database)
            }
        }

        let workspaces = try database.read { database in
            try Workspace.chatSyncPrefetchCandidates(in: database)
        }

        #expect(workspaces.count == 30)
        #expect(workspaces.prefix(2).map(\.id) == ["tie-a", "tie-b"])
        #expect(!workspaces.map(\.id).contains("archived"))
        #expect(!workspaces.map(\.id).contains("archiving"))
    }

    @Test("Workspace discovery starts local and Cloud transcript streams")
    func workspaceDiscoveryStartsTranscriptStreams() async throws {
        let database = try appDatabase()
        let localWorkspace = Workspace.preview(id: "local-workspace")
        let cloudWorkspace = Workspace.preview(
            id: "cloud-workspace",
            hostingServerURL: Workspace.conductorCloudHostingServerURL,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let localSession = Session.preview(
            id: "local-session",
            workspaceID: localWorkspace.id
        )
        let localMessage = message(
            id: "local-message",
            sessionID: localSession.id
        )
        let cloudMessage = cloudUserEvent(
            id: "cloud-event",
            sessionID: "remote-session",
            text: "Cloud"
        )
        try await database.write { database in
            try Workspace.insert { [localWorkspace, cloudWorkspace] }
                .execute(database)
        }
        let localTranscriptConnections = LockIsolated(0)
        let cloudTranscriptConnections = LockIsolated(0)
        let localSessionContinuation = LockIsolated<
            AsyncThrowingStream<[Session], any Error>.Continuation?
        >(nil)
        let localTranscriptContinuation = LockIsolated<
            AsyncThrowingStream<DesktopMessageObservation, any Error>.Continuation?
        >(nil)
        let cloudTranscriptContinuation = LockIsolated<
            AsyncThrowingStream<CloudTranscriptUpdate, any Error>.Continuation?
        >(nil)

        try await withDependencies {
            $0.continuousClock = TestClock()
            $0.defaultDatabase = database
            $0.desktopClient.observeSessions = { workspaceID in
                guard workspaceID == localWorkspace.id else {
                    return AsyncThrowingStream { _ in }
                }
                return AsyncThrowingStream { continuation in
                    localSessionContinuation.setValue(continuation)
                    continuation.yield([localSession])
                }
            }
            $0.desktopClient.observeMessages = { workspaceID, sessionID in
                #expect(workspaceID == localWorkspace.id)
                #expect(sessionID == localSession.id)
                return AsyncThrowingStream { continuation in
                    localTranscriptConnections.withValue { $0 += 1 }
                    localTranscriptContinuation.setValue(continuation)
                    continuation.yield(
                        .requiresPersistence(
                            .snapshot(
                                [localMessage],
                                cursor: localMessage.id,
                                queuedMessages: []
                            )
                        )
                    )
                }
            }
            $0.cloudAPIClient.observeSessions = { workspaceID in
                #expect(workspaceID == cloudWorkspace.id)
                return AsyncThrowingStream { continuation in
                    continuation.yield(
                        CloudWorkspaceSessionSnapshot(
                            accountID: "account",
                            workspace: CloudWorkspace(
                                id: cloudWorkspace.id,
                                name: "Cloud",
                                createdAt: .now
                            ),
                            sessions: [
                                CloudSession(
                                    id: "remote-session",
                                    deepLink: URL(string: "https://example.com")!,
                                    name: "Cloud session",
                                    model: Session.Model.gpt_5_6_sol.rawValue,
                                    agent: Session.AgentType.codex.rawValue
                                ),
                            ],
                            statuses: [:]
                        )
                    )
                }
            }
            $0.cloudAPIClient.observeTranscript = { sessionID, workspaceID, checkpoint in
                #expect(sessionID == "remote-session")
                #expect(workspaceID == cloudWorkspace.id)
                #expect(checkpoint == nil)
                return AsyncThrowingStream { continuation in
                    cloudTranscriptConnections.withValue { $0 += 1 }
                    cloudTranscriptContinuation.setValue(continuation)
                    continuation.yield(
                        CloudTranscriptUpdate(
                            accountID: "account",
                            sessionID: sessionID,
                            messages: [cloudMessage],
                            kind: .complete,
                            rawCursor: cloudMessage.id
                        )
                    )
                }
            }
        } operation: {
            let client = ChatSyncClient.live()
            let foreground = Task { await client.runForeground() }
            defer {
                foreground.cancel()
                localSessionContinuation.value?.finish()
                localTranscriptContinuation.value?.finish()
                cloudTranscriptContinuation.value?.finish()
            }

            await waitUntil {
                localTranscriptConnections.value > 0
                    && cloudTranscriptConnections.value > 0
            }

            let cloudSessionID = CloudCanonicalID.session(
                accountID: "account",
                remoteSessionID: "remote-session"
            )
            var localCache: MessageSyncEvent?
            var cloudCache: CloudCachedTranscript?
            for _ in 0..<10_000 {
                localCache = try await DesktopTranscriptStore
                    .cachedTranscriptSnapshot(
                        workspaceID: localWorkspace.id,
                        sessionID: localSession.id,
                        database: database
                    )
                cloudCache = try await database.read { database in
                    try CloudChatPersistence.cachedTranscript(
                        for: cloudSessionID,
                        in: database
                    )
                }
                if localCache?.messages == [localMessage],
                   cloudCache?.messages.map(\.content) == ["Cloud"],
                   cloudCache?.checkpoint?.rawCursor == cloudMessage.id {
                    break
                }
                await Task.yield()
            }

            #expect(localCache?.messages == [localMessage])
            #expect(cloudCache?.messages.map(\.content) == ["Cloud"])
            #expect(cloudCache?.checkpoint?.rawCursor == cloudMessage.id)
        }
    }

    @Test("Hidden sessions are not prefetched")
    func hiddenSessionsAreNotPrefetched() async throws {
        let database = try appDatabase()
        let workspace = Workspace.preview(id: "workspace")
        let visible = Session.preview(id: "visible", workspaceID: workspace.id)
        let hidden = Session.preview(
            id: "hidden",
            workspaceID: workspace.id,
            isHidden: true
        )
        try await database.write { database in
            try Workspace.insert { workspace }.execute(database)
        }
        let observedSessionIDs = LockIsolated<[Session.ID]>([])

        await withDependencies {
            $0.continuousClock = TestClock()
            $0.defaultDatabase = database
            $0.desktopClient.observeSessions = { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield([visible, hidden])
                }
            }
            $0.desktopClient.observeMessages = { _, sessionID in
                observedSessionIDs.withValue { $0.append(sessionID) }
                return AsyncThrowingStream { _ in }
            }
        } operation: {
            let client = ChatSyncClient.live()
            let foreground = Task { await client.runForeground() }
            defer { foreground.cancel() }

            await waitUntil { observedSessionIDs.value == [visible.id] }
            for _ in 0..<100 {
                await Task.yield()
            }

            #expect(observedSessionIDs.value == [visible.id])
        }
    }

    @Test("Two selected observers share one transcript stream")
    func selectedObserversShareTranscriptStream() async throws {
        let database = try appDatabase()
        let (workspace, session) = try await seedLocalSession(in: database)
        let connections = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { workspaceID, sessionID in
                #expect(workspaceID == workspace.id)
                #expect(sessionID == session.id)
                connections.withValue { $0 += 1 }
                return AsyncThrowingStream { _ in }
            }
        } operation: {
            let client = ChatSyncClient.live()
            let first = Task {
                for await _ in client.observeSelected(sessionID: session.id) { }
            }
            let second = Task {
                for await _ in client.observeSelected(sessionID: session.id) { }
            }
            defer {
                first.cancel()
                second.cancel()
            }

            await waitUntil { connections.value == 1 }
            #expect(connections.value == 1)
        }
    }

    @Test("Selecting outside the cohort starts a worker immediately")
    func selectedOutsideCohortStartsImmediately() async throws {
        let database = try appDatabase()
        let targetWorkspace = Workspace.preview(
            id: "target",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let targetSession = Session.preview(
            id: "target-session",
            workspaceID: targetWorkspace.id
        )
        try await database.write { database in
            try Workspace.insert { targetWorkspace }.execute(database)
            for index in 0..<30 {
                try Workspace
                    .insert {
                        Workspace.preview(
                            id: "new-\(index)",
                            updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                        )
                    }
                    .execute(database)
            }
            try Session.insert { targetSession }.execute(database)
        }
        let targetConnections = LockIsolated(0)

        await withDependencies {
            $0.continuousClock = TestClock()
            $0.defaultDatabase = database
            $0.desktopClient.observeSessions = { workspaceID in
                #expect(workspaceID != targetWorkspace.id)
                return AsyncThrowingStream { continuation in
                    continuation.yield([])
                }
            }
            $0.desktopClient.observeMessages = { workspaceID, sessionID in
                #expect(workspaceID == targetWorkspace.id)
                #expect(sessionID == targetSession.id)
                targetConnections.withValue { $0 += 1 }
                return AsyncThrowingStream { _ in }
            }
        } operation: {
            let client = ChatSyncClient.live()
            let foreground = Task { await client.runForeground() }
            let selected = Task {
                for await _ in client.observeSelected(sessionID: targetSession.id) { }
            }
            defer {
                foreground.cancel()
                selected.cancel()
            }

            await waitUntil { targetConnections.value == 1 }
            #expect(targetConnections.value == 1)
        }
    }

    @Test("Selected readiness follows cache completeness")
    func selectedReadinessFollowsCacheCompleteness() async throws {
        let database = try appDatabase()
        let workspace = Workspace.preview(id: "workspace")
        let complete = Session.preview(
            id: "complete",
            workspaceID: workspace.id
        )
        let missing = Session.preview(
            id: "missing",
            workspaceID: workspace.id
        )
        try await database.write { database in
            try Workspace.insert { workspace }.execute(database)
            try Session.insert { [complete, missing] }.execute(database)
            try DesktopTranscriptMetadata.insert {
                DesktopTranscriptMetadata(
                    sessionID: complete.id,
                    transcriptCursor: nil
                )
            }
            .execute(database)
        }
        let missingContinuation = LockIsolated<
            AsyncThrowingStream<DesktopMessageObservation, any Error>.Continuation?
        >(nil)
        let missingEvents = LockIsolated<[ChatSyncEvent]>([])

        await withDependencies {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { _, sessionID in
                AsyncThrowingStream { continuation in
                    if sessionID == missing.id {
                        missingContinuation.setValue(continuation)
                    }
                }
            }
        } operation: {
            let client = ChatSyncClient.live()

            let completeEvent = await firstEvent(
                in: client.observeSelected(sessionID: complete.id)
            )
            #expect(completeEvent.isReady)

            let missingTask = Task {
                for await event in client.observeSelected(sessionID: missing.id) {
                    missingEvents.withValue { $0.append(event) }
                    if event.isReady {
                        return
                    }
                }
            }
            defer { missingTask.cancel() }

            await waitUntil { missingContinuation.value != nil }
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(missingEvents.value.isEmpty)

            missingContinuation.value?.yield(
                .requiresPersistence(.snapshot([], cursor: nil, queuedMessages: []))
            )
            await waitUntil { missingEvents.value.contains { $0.isReady } }
            #expect(missingEvents.value.contains { $0.isReady })
        }
    }

    @Test("Foreground cancellation terminates streams and resumption recreates them")
    func foregroundCancellationAndResumption() async throws {
        let database = try appDatabase()
        let (_, session) = try await seedLocalSession(in: database)
        let sessionConnections = LockIsolated(0)
        let transcriptConnections = LockIsolated(0)
        let sessionCancellations = LockIsolated(0)
        let transcriptCancellations = LockIsolated(0)

        await withDependencies {
            $0.continuousClock = TestClock()
            $0.defaultDatabase = database
            $0.desktopClient.observeSessions = { _ in
                AsyncThrowingStream { continuation in
                    sessionConnections.withValue { $0 += 1 }
                    continuation.yield([session])
                    continuation.onTermination = { termination in
                        if case .cancelled = termination {
                            sessionCancellations.withValue { $0 += 1 }
                        }
                    }
                }
            }
            $0.desktopClient.observeMessages = { _, _ in
                AsyncThrowingStream { continuation in
                    transcriptConnections.withValue { $0 += 1 }
                    continuation.onTermination = { termination in
                        if case .cancelled = termination {
                            transcriptCancellations.withValue { $0 += 1 }
                        }
                    }
                }
            }
        } operation: {
            let client = ChatSyncClient.live()
            var foreground = Task { await client.runForeground() }
            await waitUntil {
                sessionConnections.value == 1
                    && transcriptConnections.value == 1
            }

            foreground.cancel()
            await waitUntil {
                sessionCancellations.value == 1
                    && transcriptCancellations.value == 1
            }

            foreground = Task { await client.runForeground() }
            defer { foreground.cancel() }
            await waitUntil {
                sessionConnections.value == 2
                    && transcriptConnections.value == 2
            }

            #expect(sessionConnections.value == 2)
            #expect(transcriptConnections.value == 2)
        }
    }
}

private extension ChatSyncEvent {
    var isReady: Bool {
        if case .ready = self {
            true
        } else {
            false
        }
    }
}

private func seedLocalSession(
    in database: any DatabaseWriter
) async throws -> (Workspace, Session) {
    let workspace = Workspace.preview()
    let session = Session.preview()
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session.insert { session }.execute(database)
    }
    return (workspace, session)
}

private func message(
    id: Message.ID,
    sessionID: Session.ID
) -> Message {
    Message(
        id: id,
        sessionID: sessionID,
        role: .user,
        content: id,
        createdAt: Date(timeIntervalSince1970: 1),
        sentAt: Date(timeIntervalSince1970: 1),
        turnID: "turn-\(id)"
    )
}

private func cloudUserEvent(
    id: String,
    sessionID: String,
    text: String
) -> CloudTranscriptMessage {
    CloudTranscriptMessage(
        id: id,
        sessionID: sessionID,
        sessionIndex: 1,
        type: .init(rawValue: "message"),
        content: .object([
            "type": .string("userMessage"),
            "message": .string(text),
        ]),
        receivedAt: Date(timeIntervalSince1970: 1)
    )
}

private func firstEvent(
    in stream: AsyncStream<ChatSyncEvent>
) async -> ChatSyncEvent {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next() ?? .failure(CancellationError())
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<10_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for an asynchronous test condition.")
}
