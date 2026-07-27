//
//  QueuedMessagesTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/19/26.
//

import ComposableArchitecture
import ConductorMobileData
import CustomDump
import Foundation
import SharedConductorData
import SQLiteData
import SwiftUI
@testable import ConductorChat
import Testing
import UIKit

@MainActor
struct QueuedMessagesTests {
    @Test("The queue starts collapsed and toggles from its disclosure button")
    func disclosure() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let session = try makeSession()
            let store = TestStore(
                initialState: QueuedMessages.State(session: session)
            ) {
                QueuedMessages()
            }

            #expect(!store.state.isExpanded)
            await store.send(.disclosureButtonTapped) {
                $0.isExpanded = true
            }
            await store.send(.disclosureButtonTapped) {
                $0.isExpanded = false
            }
        }
    }

    @Test("An expanded queue flexes between one and four rows")
    func queueHeight() async throws {
        let longSession = try makeSession(status: "working")
        let shortSession = try makeSession(id: "session-2", status: "working")
        let longMessages = (1...40).map { index in
            Message(
                id: "queued-\(index)",
                sessionID: longSession.id,
                role: .user,
                content: "Message \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                queueOrder: index
            )
        }
        let shortMessages = (1...2).map { index in
            Message(
                id: "short-queued-\(index)",
                sessionID: shortSession.id,
                role: .user,
                content: "Message \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                queueOrder: index
            )
        }

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { longMessages + shortMessages }.execute(database)
            }
        } operation: {
            var longState = QueuedMessages.State(session: longSession)
            try await longState.$messages.load()
            longState.isExpanded = true
            let longStore = Store(initialState: longState) {
                QueuedMessages()
            }
            let availableHeight: CGFloat = 700
            let longHostingController = UIHostingController(
                rootView: QueuedMessagesView(
                    store: longStore
                )
            )

            let constrainedSize = longHostingController.sizeThatFits(
                in: CGSize(width: 390, height: availableHeight)
            )

            let expandedHeight: CGFloat = 44 + 1 + 52 * 4
            #expect(abs(constrainedSize.height - expandedHeight) < 1)

            let continuousHeight: CGFloat = 44 + 1 + 52 * 2.5
            let continuousSize = longHostingController.sizeThatFits(
                in: CGSize(width: 390, height: continuousHeight)
            )
            #expect(abs(continuousSize.height - continuousHeight) < 1)

            let minimumHeight: CGFloat = 44 + 1 + 52
            let minimumSize = longHostingController.sizeThatFits(
                in: CGSize(width: 390, height: 60)
            )
            #expect(abs(minimumSize.height - minimumHeight) < 1)

            var shortState = QueuedMessages.State(session: shortSession)
            try await shortState.$messages.load()
            shortState.isExpanded = true
            let shortStore = Store(initialState: shortState) {
                QueuedMessages()
            }
            let shortHostingController = UIHostingController(
                rootView: QueuedMessagesView(
                    store: shortStore
                )
            )
            let fittedSize = shortHostingController.sizeThatFits(
                in: CGSize(width: 390, height: availableHeight)
            )

            let shortExpandedHeight: CGFloat = 44 + 1 + 52 * 2
            #expect(abs(fittedSize.height - shortExpandedHeight) < 1)

            await shortStore.send(.disclosureButtonTapped).finish()
            await Task.yield()
            let collapsedSize = shortHostingController.sizeThatFits(
                in: CGSize(width: 390, height: availableHeight)
            )

            #expect(abs(collapsedSize.height - 44) < 1)
            #expect(collapsedSize.width < 160)
        }
    }

    @Test("Queued messages are scoped and ordered")
    func queuedMessages() async throws {
        let session = try makeSession()
        let sentMessage = Message(
            id: "sent",
            sessionID: session.id,
            role: .user,
            content: "Already sent",
            createdAt: Date(timeIntervalSince1970: 100),
            sentAt: Date(timeIntervalSince1970: 100),
            turnID: "sent",
            queueOrder: 1
        )
        let queuedSecond = Message(
            id: "queued-second",
            sessionID: session.id,
            role: .user,
            content: "Second",
            createdAt: Date(timeIntervalSince1970: 102),
            queueOrder: 2
        )
        let queuedFirst = Message(
            id: "queued-first",
            sessionID: session.id,
            role: .user,
            content: "First",
            createdAt: Date(timeIntervalSince1970: 103),
            queueOrder: 1
        )
        let cancelledMessage = Message(
            id: "cancelled",
            sessionID: session.id,
            role: .user,
            content: "Cancelled",
            createdAt: Date(timeIntervalSince1970: 104),
            cancelledAt: "2026-07-09T00:00:00Z",
            queueOrder: 3
        )
        let otherSessionMessage = Message(
            id: "other",
            sessionID: "session-2",
            role: .user,
            content: "Other session",
            createdAt: Date(timeIntervalSince1970: 99),
            queueOrder: 1
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.upsert {
                    [
                        queuedSecond,
                        cancelledMessage,
                        sentMessage,
                        otherSessionMessage,
                        queuedFirst,
                    ]
                }
                .execute(database)
            }
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let state = QueuedMessages.State(session: session)
            try await state.$messages.load()

            expectNoDifference(state.messages, [queuedFirst, queuedSecond])

            let deliveredMessage = {
                var message = queuedFirst
                message.sentAt = Date(timeIntervalSince1970: 105)
                message.turnID = message.id
                return message
            }()
            try await database.write { database in
                try Message.upsert { deliveredMessage }.execute(database)
            }
            try await state.$messages.load()

            expectNoDifference(state.messages, [queuedSecond])
        }
    }

    @Test("Reordering queued messages is optimistic until the desktop confirms it")
    func reorderQueuedMessages() async throws {
        let session = try makeSession(status: "working")
        let first = Message(
            id: "queued-first",
            sessionID: session.id,
            role: .user,
            content: "First",
            createdAt: Date(timeIntervalSince1970: 100),
            queueOrder: 1
        )
        let second = Message(
            id: "queued-second",
            sessionID: session.id,
            role: .user,
            content: "Second",
            createdAt: Date(timeIntervalSince1970: 101),
            queueOrder: 2
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { [first, second] }.execute(database)
            }
        } operation: {
            let state = QueuedMessages.State(session: session)
            try await state.$messages.load()
            let store = TestStore(initialState: state) {
                QueuedMessages()
            } withDependencies: {
                $0.desktopClient.reorderQueuedMessages = {
                    workspaceID,
                    sessionID,
                    messageIDs in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(messageIDs == [second.id, first.id])
                }
            }

            await store.send(.messagesReordered([second.id, first.id])) {
                $0.isReorderInFlight = true
                $0.pendingMessageIDs = [second.id, first.id]
            }
            expectNoDifference(
                store.state.displayedMessages.map(\.id),
                [second.id, first.id]
            )
            await store.receive(\.reorderResponse) {
                $0.isReorderInFlight = false
            }
        }
    }

    @Test("A failed queue reorder restores the authoritative database order")
    func reorderQueuedMessagesFails() async throws {
        let session = try makeSession(status: "working")
        let first = Message(
            id: "queued-first",
            sessionID: session.id,
            role: .user,
            content: "First",
            createdAt: Date(timeIntervalSince1970: 100),
            queueOrder: 1
        )
        let second = Message(
            id: "queued-second",
            sessionID: session.id,
            role: .user,
            content: "Second",
            createdAt: Date(timeIntervalSince1970: 101),
            queueOrder: 2
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { [first, second] }.execute(database)
            }
        } operation: {
            let state = QueuedMessages.State(session: session)
            try await state.$messages.load()
            let store = TestStore(initialState: state) {
                QueuedMessages()
            } withDependencies: {
                $0.desktopClient.reorderQueuedMessages = { _, _, _ in
                    throw TestError()
                }
            }

            await store.send(.messagesReordered([second.id, first.id])) {
                $0.isReorderInFlight = true
                $0.pendingMessageIDs = [second.id, first.id]
            }
            await store.receive(\.reorderResponse) {
                $0.isReorderInFlight = false
                $0.pendingMessageIDs = nil
            }
            expectNoDifference(
                store.state.displayedMessages.map(\.id),
                [first.id, second.id]
            )
        }
    }

    @Test("A paused queue can be resumed")
    func resumeQueuedMessages() async throws {
        let session = try makeSession(
            status: "working",
            queuePausedAt: "2026-07-18T09:00:00Z"
        )
        let sessionID = session.id
        let workspaceID = session.workspaceID

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: QueuedMessages.State(session: session)) {
                QueuedMessages()
            } withDependencies: {
                $0.desktopClient.resumeQueuedMessages = { receivedWorkspaceID, receivedSessionID in
                    #expect(receivedWorkspaceID == workspaceID)
                    #expect(receivedSessionID == sessionID)
                }
            }

            await store.send(.resumeButtonTapped) {
                $0.isResumeInFlight = true
            }
            await store.receive(\.resumeResponse) {
                $0.isResumeInFlight = false
            }
        }
    }

    @Test("Queue pause presentation follows the persisted pause timestamp")
    func queuePausePresentation() throws {
        try withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let workingPaused = QueuedMessages.State(
                session: try makeSession(
                    status: "working",
                    queuePausedAt: "2026-07-18T09:00:00Z"
                )
            )
            let idleUnpaused = QueuedMessages.State(
                session: try makeSession(id: "session-2", status: "idle")
            )

            #expect(workingPaused.shouldShowResumeButton)
            #expect(!idleUnpaused.shouldShowResumeButton)
        }
    }

    @Test("Queued messages can be deleted or steered")
    func queuedMessageActions() async throws {
        let session = try makeSession(status: "working")
        let message = Message(
            id: "queued",
            sessionID: session.id,
            role: .user,
            content: "Original",
            createdAt: Date(timeIntervalSince1970: 100),
            queueOrder: 1
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { message }.execute(database)
            }
        } operation: {
            let state = QueuedMessages.State(session: session)
            try await state.$messages.load()
            let store = TestStore(initialState: state) {
                QueuedMessages()
            } withDependencies: {
                $0.desktopClient.deleteQueuedMessage = {
                    workspaceID,
                    sessionID,
                    messageID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(messageID == message.id)
                }
                $0.desktopClient.steerQueuedMessage = {
                    workspaceID,
                    sessionID,
                    messageID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(messageID == message.id)
                }
            }

            await store.send(.deleteButtonTapped(message.id)) {
                $0.messageActionInFlightID = message.id
            }
            await store.receive(\.deleteResponse) {
                $0.messageActionInFlightID = nil
            }
            await store.send(.steerButtonTapped(message.id)) {
                $0.messageActionInFlightID = message.id
            }
            await store.receive(\.steerResponse) {
                $0.messageActionInFlightID = nil
            }
        }
    }

    @Test("Editing a queued message updates it and restores the queue")
    func editQueuedMessage() async throws {
        let session = try makeSession(status: "working")
        let message = Message(
            id: "queued",
            sessionID: session.id,
            role: .user,
            content: "Original",
            createdAt: Date(timeIntervalSince1970: 100),
            queueOrder: 1
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { message }.execute(database)
            }
        } operation: {
            let state = QueuedMessages.State(session: session)
            try await state.$messages.load()
            let store = TestStore(initialState: state) {
                QueuedMessages()
            } withDependencies: {
                $0.desktopClient.beginQueuedMessageEdit = { workspaceID, sessionID, messageID in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(messageID == message.id)
                    return DesktopClient.QueuedMessageEdit(
                        message: message,
                        shouldResumeQueue: true
                    )
                }
                $0.desktopClient.finishQueuedMessageEdit = {
                    workspaceID,
                    sessionID,
                    messageID,
                    content,
                    shouldResumeQueue in
                    #expect(workspaceID == session.workspaceID)
                    #expect(sessionID == session.id)
                    #expect(messageID == message.id)
                    #expect(content == "Updated")
                    #expect(shouldResumeQueue)
                }
            }

            await store.send(.messageTapped(message.id)) {
                $0.isEditStartInFlight = true
            }
            await store.receive(\.beginEditResponse) {
                $0.editingMessageID = message.id
                $0.isEditStartInFlight = false
                $0.editDraft = "Original"
                $0.shouldResumeAfterEditing = true
            }

            await store.send(.binding(.set(\.editDraft, "  Updated  "))) {
                $0.editDraft = "  Updated  "
            }
            await store.send(.finishEditButtonTapped) {
                $0.isEditInFlight = true
            }
            await store.receive(\.finishEditResponse) {
                $0.editingMessageID = nil
                $0.isEditInFlight = false
                $0.editDraft = ""
                $0.shouldResumeAfterEditing = false
            }
        }
    }

    @Test("Cancelling an edit leaves a queue that was already paused unchanged")
    func cancelQueuedMessageEditAlreadyPaused() async throws {
        let session = try makeSession(
            status: "working",
            queuePausedAt: "2026-07-18T09:00:00Z"
        )
        let message = Message(
            id: "queued",
            sessionID: session.id,
            role: .user,
            content: "Original",
            createdAt: Date(timeIntervalSince1970: 100),
            queueOrder: 1
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Message.insert { message }.execute(database)
            }
        } operation: {
            var state = QueuedMessages.State(session: session)
            try await state.$messages.load()
            state.editingMessageID = message.id
            state.editDraft = "Original"
            let store = TestStore(initialState: state) {
                QueuedMessages()
            }

            await store.send(.cancelEditButtonTapped) {
                $0.editingMessageID = nil
                $0.editDraft = ""
            }
        }
    }
}

private func makeSession(
    id: Session.ID = "session-1",
    status: String = "idle",
    queuePausedAt: String? = nil
) throws -> Session {
    var session = try JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "\(id)",
              "workspace_id": "workspace-1",
              "title": "Chat",
              "agent_type": "codex",
              "is_hidden": false,
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "status": "\(status)",
              "model": "gpt-5.5",
              "fast_mode": true,
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )
    session.queuePausedAt = queuePausedAt
    return session
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
