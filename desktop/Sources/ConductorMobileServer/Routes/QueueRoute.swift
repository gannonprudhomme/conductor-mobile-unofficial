//
//  QueueRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/16/26.
//

import Dependencies
import Foundation
import Hummingbird
import SharedConductorData
import SQLiteData

enum QueueRoute {
    static func delete(
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let messageID = try context.parameters.require("messageID")
        let editContext = try await loadEditContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            messageID: messageID,
            database: database
        )
        guard editContext.session != nil else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard editContext.message != nil else {
            throw PlainTextResponseError(.notFound, message: "Queued message not found.")
        }

        try await performMutation(
            deliveryUnknownMessage: "Could not determine whether the queued-message deletion was delivered.",
            timeoutMessage: "Timed out waiting for Conductor to delete the queued message.",
            internalErrorPrefix: "Could not delete queued message"
        ) {
            try await uiHook.deleteQueuedMessage(
                sessionID: sessionID,
                messageID: messageID,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilQueuedMessageIsRemoved(
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        messageID: messageID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        }

        return .noContent
    }

    static func beginEditing(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> Response {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let messageID = try context.parameters.require("messageID")
        let editContext = try await loadEditContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            messageID: messageID,
            database: database
        )
        guard let session = editContext.session else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard editContext.message != nil else {
            throw PlainTextResponseError(.notFound, message: "Queued message not found.")
        }

        let shouldResumeQueue = session.queuePausedAt == nil
        if shouldResumeQueue {
            do {
                try await performMutation(
                    deliveryUnknownMessage: "Could not determine whether the queue was paused.",
                    timeoutMessage: "Timed out waiting for Conductor to pause the queue.",
                    internalErrorPrefix: "Could not pause the queue"
                ) {
                    try await uiHook.setQueuePaused(
                        sessionID: sessionID,
                        isPaused: true,
                        waitUntilChangeAvailableInDatabase: {
                            try await waitUntilQueueIsPaused(
                                workspaceID: workspaceID,
                                sessionID: sessionID,
                                messageID: messageID,
                                database: database,
                                timeout: persistenceTimeout
                            )
                        }
                    )
                }
            } catch {
                // The target may be consumed while Conductor is applying the pause. Restore the
                // queue before returning so a failed attempt cannot strand the session paused.
                try? await uiHook.setQueuePaused(
                    sessionID: sessionID,
                    isPaused: false,
                    waitUntilChangeAvailableInDatabase: {
                        try await waitUntilQueueIsResumed(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            database: database,
                            timeout: persistenceTimeout
                        )
                    }
                )
                throw error
            }
        }

        let currentEditContext = try await loadEditContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            messageID: messageID,
            database: database
        )
        guard let currentMessage = currentEditContext.message else {
            if shouldResumeQueue {
                try? await uiHook.setQueuePaused(
                    sessionID: sessionID,
                    isPaused: false,
                    waitUntilChangeAvailableInDatabase: {
                        try await waitUntilQueueIsResumed(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            database: database,
                            timeout: persistenceTimeout
                        )
                    }
                )
            }
            throw PlainTextResponseError(
                .conflict,
                message: "The queued message changed before editing began."
            )
        }
        let response = BeginEditResponse(
            message: currentMessage,
            shouldResumeQueue: shouldResumeQueue
        )
        return try JSONEncoder.conductor.encode(
            response,
            from: request,
            context: context
        )
    }

    static func finishEditing(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let messageID = try context.parameters.require("messageID")
        let body: EditBody
        do {
            body = try await request.decode(as: EditBody.self, context: context)
        } catch {
            throw PlainTextResponseError(.badRequest, message: "Invalid queued-message edit.")
        }
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw PlainTextResponseError(.badRequest, message: "Queued message cannot be empty.")
        }

        let editContext = try await loadEditContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            messageID: messageID,
            database: database
        )
        guard let session = editContext.session else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard editContext.message != nil else {
            throw PlainTextResponseError(.notFound, message: "Queued message not found.")
        }
        guard session.queuePausedAt != nil else {
            throw PlainTextResponseError(
                .conflict,
                message: "The queue must remain paused while editing a message."
            )
        }

        try await performMutation(
            deliveryUnknownMessage: "Could not determine whether the queued-message edit was delivered.",
            timeoutMessage: "Timed out waiting for Conductor to save the queued message.",
            internalErrorPrefix: "Could not edit queued message"
        ) {
            try await uiHook.editQueuedMessage(
                sessionID: sessionID,
                messageID: messageID,
                content: content,
                shouldResumeQueue: false,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilEditIsPersisted(
                        content: content,
                        sessionID: sessionID,
                        messageID: messageID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        }

        if body.shouldResumeQueue {
            try await performMutation(
                deliveryUnknownMessage: "Could not determine whether the queue was resumed.",
                timeoutMessage: "Timed out waiting for Conductor to resume the queue.",
                internalErrorPrefix: "Could not resume the queue"
            ) {
                try await uiHook.setQueuePaused(
                    sessionID: sessionID,
                    isPaused: false,
                    waitUntilChangeAvailableInDatabase: {
                        try await waitUntilQueueIsResumed(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            database: database,
                            timeout: persistenceTimeout
                        )
                    }
                )
            }
        }

        return .noContent
    }

    static func resume(
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let session = try await loadSession(
            workspaceID: workspaceID,
            sessionID: sessionID,
            database: database
        )
        guard let session else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard session.queuePausedAt != nil else {
            return .noContent
        }

        try await performMutation(
            deliveryUnknownMessage: "Could not determine whether the queue was resumed.",
            timeoutMessage: "Timed out waiting for Conductor to resume the queue.",
            internalErrorPrefix: "Could not resume the queue"
        ) {
            try await uiHook.setQueuePaused(
                sessionID: sessionID,
                isPaused: false,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilQueueIsResumed(
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        }

        return .noContent
    }

    static func steer(
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let messageID = try context.parameters.require("messageID")
        let editContext = try await loadEditContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            messageID: messageID,
            database: database
        )
        guard editContext.session != nil else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard editContext.message != nil else {
            throw PlainTextResponseError(.notFound, message: "Queued message not found.")
        }

        try await performMutation(
            deliveryUnknownMessage: "Could not determine whether the queued message was steered.",
            timeoutMessage: "Timed out waiting for Conductor to steer the queued message.",
            internalErrorPrefix: "Could not steer queued message"
        ) {
            try await uiHook.steerQueuedMessage(
                sessionID: sessionID,
                messageID: messageID,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilQueuedMessageIsRemoved(
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        messageID: messageID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        }

        return .noContent
    }

    static func patch(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        persistenceTimeout: Duration
    ) async throws -> HTTPResponse.Status {
        @Dependency(\.workspaceUIHook) var uiHook

        let workspaceID = try context.parameters.require("workspaceID")
        let sessionID = try context.parameters.require("sessionID")
        let body: QueueOrderBody
        do {
            body = try await request.decode(as: QueueOrderBody.self, context: context)
        } catch {
            throw PlainTextResponseError(.badRequest, message: "Invalid queued-message order.")
        }

        guard !body.messageIDs.isEmpty,
              Set(body.messageIDs).count == body.messageIDs.count else {
            throw PlainTextResponseError(.badRequest, message: "Invalid queued-message order.")
        }

        guard let currentMessageIDs = try await queuedMessageIDs(
            workspaceID: workspaceID,
            sessionID: sessionID,
            database: database
        ) else {
            throw PlainTextResponseError(.notFound, message: "Session not found.")
        }
        guard Set(body.messageIDs) == Set(currentMessageIDs) else {
            throw PlainTextResponseError(
                .conflict,
                message: "The queued messages changed before they could be reordered."
            )
        }
        guard body.messageIDs != currentMessageIDs else {
            return .noContent
        }

        try await performMutation(
            deliveryUnknownMessage: "Could not determine whether the queue reorder was delivered.",
            timeoutMessage: "Timed out waiting for Conductor to save the queued-message order.",
            internalErrorPrefix: "Could not reorder queued messages"
        ) {
            try await uiHook.reorderQueue(
                sessionID: sessionID,
                messageIDs: body.messageIDs,
                waitUntilChangeAvailableInDatabase: {
                    try await waitUntilOrderIsPersisted(
                        body.messageIDs,
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        database: database,
                        timeout: persistenceTimeout
                    )
                }
            )
        }

        return .noContent
    }

    private static func waitUntilQueueIsPaused(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        messageID: Message.ID,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        try await waitUntil(timeout: timeout) {
            let editContext = try await loadEditContext(
                workspaceID: workspaceID,
                sessionID: sessionID,
                messageID: messageID,
                database: database
            )
            guard editContext.message != nil else {
                throw PersistenceError.queuedMessageUnavailable
            }
            return editContext.session?.queuePausedAt != nil
        }
    }

    private static func waitUntilQueuedMessageIsRemoved(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        messageID: Message.ID,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        try await waitUntil(timeout: timeout) {
            try await loadEditContext(
                workspaceID: workspaceID,
                sessionID: sessionID,
                messageID: messageID,
                database: database
            ).message == nil
        }
    }

    private static func waitUntilEditIsPersisted(
        content: String,
        sessionID: Session.ID,
        messageID: Message.ID,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        try await waitUntil(timeout: timeout) {
            try await database.read { database in
                try Message
                    .where {
                        $0.id.eq(messageID)
                            && $0.sessionID.eq(sessionID)
                    }
                    .fetchOne(database)?
                    .content == content
            }
        }
    }

    private static func waitUntilQueueIsResumed(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        try await waitUntil(timeout: timeout) {
            guard let session = try await loadSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            ) else {
                return false
            }
            return session.queuePausedAt == nil
        }
    }

    private static func waitUntil(
        timeout: Duration,
        condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var isFirstAttempt = true
        while isFirstAttempt || clock.now < deadline {
            isFirstAttempt = false
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PersistenceError.timedOut
    }

    private static func waitUntilOrderIsPersisted(
        _ expectedMessageIDs: [Message.ID],
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader,
        timeout: Duration
    ) async throws {
        try await waitUntil(timeout: timeout) {
            let messageIDs = try await queuedMessageIDs(
                workspaceID: workspaceID,
                sessionID: sessionID,
                database: database
            )
            return messageIDs == expectedMessageIDs
        }
    }

    private static func loadEditContext(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        messageID: Message.ID,
        database: any DatabaseReader
    ) async throws -> EditContext {
        try await database.read { database in
            let session = try Session
                .where {
                    $0.id.eq(sessionID)
                        && $0.workspaceID.eq(workspaceID)
                }
                .fetchOne(database)
            let message = try Message
                .where {
                    $0.id.eq(messageID)
                        && $0.sessionID.eq(sessionID)
                        && $0.sentAt.is(nil)
                        && $0.queueOrder.isNot(nil)
                        && $0.cancelledAt.is(nil)
                }
                .fetchOne(database)
            return EditContext(message: message, session: session)
        }
    }

    private static func loadSession(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader
    ) async throws -> Session? {
        try await database.read { database in
            try Session
                .where {
                    $0.id.eq(sessionID)
                        && $0.workspaceID.eq(workspaceID)
                }
                .fetchOne(database)
        }
    }

    private static func performMutation(
        deliveryUnknownMessage: String,
        timeoutMessage: String,
        internalErrorPrefix: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceUIHook.DispatchError {
            switch error {
            case .deliveryUnknown:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: deliveryUnknownMessage
                )
            case .listenerUnavailable:
                throw PlainTextResponseError(
                    .serviceUnavailable,
                    message: "Conductor's UI hook is not connected."
                )
            case .mutationInFlight:
                throw PlainTextResponseError(
                    .conflict,
                    message: "Another Conductor UI change is still in progress."
                )
            }
        } catch PersistenceError.timedOut {
            throw PlainTextResponseError(.gatewayTimeout, message: timeoutMessage)
        } catch PersistenceError.queuedMessageUnavailable {
            throw PlainTextResponseError(
                .conflict,
                message: "The queued message changed before the edit completed."
            )
        } catch {
            throw PlainTextResponseError(
                .internalServerError,
                message: "\(internalErrorPrefix): \(error)"
            )
        }
    }

    private static func queuedMessageIDs(
        workspaceID: Workspace.ID,
        sessionID: Session.ID,
        database: any DatabaseReader
    ) async throws -> [Message.ID]? {
        try await database.read { database in
            let sessionExists = try Session
                .where {
                    $0.id.eq(sessionID)
                        && $0.workspaceID.eq(workspaceID)
                }
                .fetchOne(database) != nil
            guard sessionExists else {
                return nil
            }

            return try Message
                .where {
                    $0.sessionID.eq(sessionID)
                        && $0.sentAt.is(nil)
                        && $0.queueOrder.isNot(nil)
                        && $0.cancelledAt.is(nil)
                }
                .order {
                    (
                        $0.queueOrder.asc(nulls: .last),
                        $0.createdAt,
                        $0.id
                    )
                }
                .fetchAll(database)
                .map(\.id)
        }
    }

    private struct QueueOrderBody: Decodable {
        let messageIDs: [Message.ID]

        private enum CodingKeys: String, CodingKey {
            case messageIDs = "message_ids"
        }
    }

    private struct BeginEditResponse: Encodable {
        let message: Message
        let shouldResumeQueue: Bool

        private enum CodingKeys: String, CodingKey {
            case message
            case shouldResumeQueue = "should_resume_queue"
        }
    }

    private struct EditBody: Decodable {
        let content: String
        let shouldResumeQueue: Bool

        private enum CodingKeys: String, CodingKey {
            case content
            case shouldResumeQueue = "resume_queue"
        }
    }

    private struct EditContext {
        let message: Message?
        let session: Session?
    }

    private enum PersistenceError: Error {
        case queuedMessageUnavailable
        case timedOut
    }
}
