//
//  MessageRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/15/26.
//

import Dependencies
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct MessageRouteTests {
    @Test("POST returns an accepted receipt with the echoed attempt ID")
    func accepted() async throws {
        let attemptID = UUID(42)
        let messageID = "canonical-message"
        let recorder = MessageRouteRecorder()
        let database = try await messageRouteDatabase()

        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = {
                requestID,
                receivedAttemptID,
                sessionID,
                workspaceID,
                content,
                mode,
                _ in
                await recorder.record(
                    requestID: requestID,
                    attemptID: receivedAttemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return messageID
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: attemptID),
                database: database
            )
            #expect(response.status == .ok)
            #expect(
                response.receipt == MessageSendResponse(
                    attemptID: attemptID,
                    result: .accepted(messageID: messageID)
                )
            )
        }

        let recorded = await recorder.message
        #expect(recorded?.attemptID == attemptID)
        #expect(recorded?.requestID != attemptID)
        #expect(recorded?.sessionID == "session-1")
        #expect(recorded?.workspaceID == "workspace-1")
        #expect(recorded?.content == "  Run the tests.  ")
        #expect(recorded?.mode == .sent)
    }

    @Test("Idle and working sessions both send with the sent mode", arguments: [
        Session.Status.idle,
        Session.Status.working,
    ])
    func sentMode(status: Session.Status) async throws {
        let database = try await messageRouteDatabase(status: status)
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = {
                requestID,
                attemptID,
                sessionID,
                workspaceID,
                content,
                mode,
                _ in
                await recorder.record(
                    requestID: requestID,
                    attemptID: attemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(43)),
                database: database
            )
            #expect(response.status == .ok)
        }
        #expect(await recorder.message?.mode == .sent)
    }

    @Test("Fast Mode is synchronized before sending")
    func fastModeSynchronization() async throws {
        let attemptID = UUID(47)
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { command, _, waitUntilChangeAvailableInDatabase in
                #expect(
                    command == .sessionFastMode(
                        sessionID: "session-1",
                        isEnabled: true
                    )
                )
                try await database.write { database in
                    try Session
                        .find("session-1")
                        .update { $0.isFastModeEnabled = #bind(true) }
                        .execute(database)
                }
                try await waitUntilChangeAvailableInDatabase()
                await recorder.recordFastModeUpdate()
                return .hook
            }
            $0.workspaceUIHook.sendMessage = {
                requestID,
                receivedAttemptID,
                sessionID,
                workspaceID,
                content,
                mode,
                _ in
                let session = try await database.read { database in
                    try Session.find(sessionID).fetchOne(database)
                }
                #expect(session?.isFastModeEnabled == true)
                await recorder.record(
                    requestID: requestID,
                    attemptID: receivedAttemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: attemptID, isFastModeEnabled: true),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }
        #expect(await recorder.didUpdateFastMode)
        #expect(await recorder.didSend)
    }

    @Test("Unchanged Fast Mode skips synchronization")
    func unchangedFastMode() async throws {
        let database = try await messageRouteDatabase()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { _, _, _ in
                Issue.record("Fast Mode should not be synchronized when unchanged.")
                return .hook
            }
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(48)),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }
    }

    @Test("Fast Mode delivery failure rejects without sending")
    func fastModeDeliveryFailure() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { _, _, _ in
                throw WorkspaceUIHook.DispatchError.deliveryUnknown
            }
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                await recorder.markSent()
                return "unexpected"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(49), isFastModeEnabled: true),
                database: database
            )
            #expect(response.status == .ok)
            #expect(
                response.receipt?.result == .rejected(
                    reason: "Could not determine whether Fast Mode was delivered."
                )
            )
        }
        #expect(await recorder.didSend == false)
    }

    @Test("A missing UI hook listener is rejected")
    func listenerUnavailable() async throws {
        try await expectResult(
            from: WorkspaceUIHook.CommandDispatchError.listenerUnavailable,
            expectedResult: .rejected(
                reason: "Conductor's workspace UI hook is unavailable."
            )
        )
    }

    @Test("Post-enqueue failures preserve delivery certainty", arguments: [
        WorkspaceUIHook.CommandDispatchError.commandFailed("Browser rejected."),
        .deliveryUnknown,
        .persistenceTimedOut,
    ])
    func postEnqueueFailure(error: WorkspaceUIHook.CommandDispatchError) async throws {
        let expectedResult: MessageDeliveryResult = switch error {
        case .commandFailed(let message):
            .rejected(reason: "Conductor rejected the message: \(message)")
        case .deliveryUnknown, .persistenceTimedOut:
            .unknown(reason: "Could not determine whether the message was delivered.")
        case .listenerUnavailable:
            .rejected(reason: "Conductor's workspace UI hook is unavailable.")
        }
        try await expectResult(
            from: error,
            expectedResult: expectedResult
        )
    }

    @Test("An unclassified send failure is delivery-unknown")
    func preEnqueueFailure() async throws {
        try await expectResult(
            from: TestError.encoding,
            expectedResult: .unknown(
                reason: "Could not determine whether the message was delivered."
            )
        )
    }

    @Test("The route's configured deadline owns message timeout")
    func configuredDeadline() async throws {
        let database = try await messageRouteDatabase()
        let (responses, responseContinuation) = AsyncStream<Void>.makeStream()
        defer { responseContinuation.finish() }
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                for await _ in responses { }
                throw CancellationError()
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(50)),
                database: database,
                commandTimeout: .milliseconds(20)
            )
            #expect(
                response.receipt?.result == .unknown(
                    reason: "Could not determine whether the message was delivered."
                )
            )
        }
    }

    @Test("Model update failure is rejected before sending")
    func modelUpdateFailure() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.updateSessionModel = { _, _, _ in false }
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                await recorder.markSent()
                return "unexpected"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(44), model: "gpt-5.6-terra"),
                database: database
            )
            #expect(response.status == .ok)
            #expect(
                response.receipt?.result == .rejected(
                    reason: "Conductor is not connected to change the session model."
                )
            )
        }
        #expect(await recorder.didSend == false)
    }

    @Test("A first message can switch the session agent and model")
    func firstMessageSwitchesAgent() async throws {
        let attemptID = UUID(51)
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.updateSessionAgentAndModel = {
                sessionID,
                agentType,
                model,
                waitUntilChangeAvailableInDatabase in
                try await database.write { database in
                    try Session
                        .find(sessionID)
                        .update {
                            $0.agentType = #bind(agentType)
                            $0.model = #bind(model)
                        }
                        .execute(database)
                }
                try await waitUntilChangeAvailableInDatabase()
                return true
            }
            $0.workspaceUIHook.sendMessage = {
                requestID,
                receivedAttemptID,
                sessionID,
                workspaceID,
                content,
                mode,
                reasoningEffort in
                let session = try await database.read { database in
                    try Session.find(sessionID).fetchOne(database)
                }
                #expect(session?.agentType == .claude)
                #expect(session?.model == .fable5)
                #expect(reasoningEffort == .ultracode)
                await recorder.record(
                    requestID: requestID,
                    attemptID: receivedAttemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(
                    attemptID: attemptID,
                    model: "fable-5",
                    reasoningEffort: .ultracode
                ),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }

        #expect(await recorder.message?.content == "  Run the tests.  ")
    }

    @Test("A model from another agent is rejected after the first message")
    func incompatibleModelAfterMessage() async throws {
        let attemptID = UUID(52)
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update { $0.lastUserMessageAt = #bind("2026-07-09T00:01:00Z") }
                .execute(database)
        }
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                await recorder.markSent()
                return "unexpected"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: attemptID, model: "fable-5"),
                database: database
            )
            #expect(response.status == .ok)
            #expect(
                response.receipt?.result == .rejected(
                    reason: "Model is not available for this session's agent."
                )
            )
        }
        #expect(await recorder.didSend == false)
    }

    @Test("An unavailable reasoning effort is rejected before sending")
    func unavailableReasoningEffort() async throws {
        let attemptID = UUID(53)
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update {
                    $0.agentType = #bind(Session.AgentType.claude)
                    $0.model = #bind(Session.Model.fable5)
                    $0.claudeEffortLevel = #bind(Session.ReasoningEffort.high)
                }
                .execute(database)
        }
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in
                await recorder.markSent()
                return "unexpected"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(
                    attemptID: attemptID,
                    model: "fable-5",
                    reasoningEffort: .ultra
                ),
                database: database
            )
            #expect(
                response.receipt?.result == .rejected(
                    reason: "Reasoning effort is not available for this model."
                )
            )
        }
        #expect(await recorder.didSend == false)
    }

    @Test("A valid Claude reasoning effort is forwarded")
    func claudeReasoningEffort() async throws {
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update {
                    $0.agentType = #bind(Session.AgentType.claude)
                    $0.model = #bind(Session.Model.fable5)
                }
                .execute(database)
        }
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, reasoningEffort in
                #expect(reasoningEffort == .ultracode)
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(
                    attemptID: UUID(54),
                    model: "fable-5",
                    reasoningEffort: .ultracode
                ),
                database: database
            )
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }
    }

    @Test("An omitted reasoning effort uses the model default")
    func defaultReasoningEffort() async throws {
        let database = try await messageRouteDatabase()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, reasoningEffort in
                #expect(reasoningEffort == .medium)
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(55)),
                database: database
            )
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }
    }

    @Test("An omitted reasoning effort preserves a compatible session setting")
    func persistedReasoningEffort() async throws {
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update {
                    $0.codexThinkingLevel = #bind(Session.ReasoningEffort.high)
                }
                .execute(database)
        }
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, reasoningEffort in
                #expect(reasoningEffort == .high)
                return "message-id"
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(56)),
                database: database
            )
            #expect(response.receipt?.result == .accepted(messageID: "message-id"))
        }
    }

    @Test("Malformed and blank requests remain untyped 400 responses", arguments: [
        #"{"message":"Run tests"}"#,
        #"{"attemptId":"00000000-0000-0000-0000-000000000045","message":"Run tests","model":"gpt-5.5"}"#,
        #"{"attemptId":"00000000-0000-0000-0000-000000000045","message":"  \n ","model":"gpt-5.5","fast_mode":false}"#,
    ])
    func badRequest(body: String) async throws {
        let database = try await messageRouteDatabase()
        let response = try await postMessage(
            body: body,
            database: database
        )
        #expect(response.status == .badRequest)
        #expect(response.receipt == nil)
    }

    private func expectResult(
        from error: any Error & Sendable,
        expectedResult: MessageDeliveryResult
    ) async throws {
        let database = try await messageRouteDatabase()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _, _ in throw error }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(46)),
                database: database
            )
            #expect(response.status == .ok)
            #expect(
                response.receipt == MessageSendResponse(
                    attemptID: UUID(46),
                    result: expectedResult
                )
            )
        }
    }
}

private func requestBody(
    attemptID: UUID,
    model: String = "gpt-5.5",
    isFastModeEnabled: Bool = false,
    reasoningEffort: Session.ReasoningEffort? = nil
) -> String {
    let reasoning = reasoningEffort.map {
        #","reasoning_effort":"\#($0.rawValue)""#
    } ?? ""
    return #"{"attemptId":"\#(attemptID.uuidString)","message":"  Run the tests.  ","model":"\#(model)","fast_mode":\#(isFastModeEnabled),"mode":"sent"\#(reasoning)}"#
}

private func postMessage(
    body: String,
    database: DatabaseQueue,
    commandTimeout: Duration = .seconds(5)
) async throws -> (status: HTTPResponse.Status, receipt: MessageSendResponse?) {
    let application = Server.makeApplication(
        database: database,
        uiCommandTimeout: commandTimeout
    )
    let result = LockIsolated<(HTTPResponse.Status, MessageSendResponse?)?>(nil)
    try await application.test(.router) { client in
        try await client.execute(
            uri: "/workspaces/workspace-1/sessions/session-1/messages",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: body)
        ) { response in
            let data = Data(response.body.readableBytesView)
            result.withValue {
                $0 = (
                    response.status,
                    try? JSONDecoder().decode(MessageSendResponse.self, from: data)
                )
            }
        }
    }
    return try #require(result.value)
}

private func messageRouteDatabase(
    status: Session.Status = .working
) async throws -> DatabaseQueue {
    let database = try testConductorDatabase()
    let date = Date(timeIntervalSince1970: 1_783_555_200)
    let workspace = Workspace(
        id: "workspace-1",
        createdAt: date,
        updatedAt: date,
        workspacePath: "/tmp/workspace-1"
    )
    let session = Session(
        id: "session-1",
        workspaceID: workspace.id,
        title: "Working",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-09T00:00:01Z",
        updatedAt: "2026-07-09T00:00:01Z",
        lastUserMessageAt: nil,
        status: status,
        model: .gpt5_5,
        unreadCount: 0,
        freshlyCompacted: 0,
        contextTokenCount: 0,
        isFastModeEnabled: false
    )
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session.insert { session }.execute(database)
    }
    return database
}

private actor MessageRouteRecorder {
    private(set) var message: RecordedMessage?
    private(set) var didSend = false
    private(set) var didUpdateFastMode = false

    func record(
        requestID: UUID,
        attemptID: UUID,
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        content: String,
        mode: WorkspaceUIHook.MessageMode
    ) {
        didSend = true
        message = RecordedMessage(
            requestID: requestID,
            attemptID: attemptID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            content: content,
            mode: mode
        )
    }

    func markSent() {
        didSend = true
    }

    func recordFastModeUpdate() {
        didUpdateFastMode = true
    }

    struct RecordedMessage: Equatable {
        let requestID: UUID
        let attemptID: UUID
        let sessionID: Session.ID
        let workspaceID: Workspace.ID
        let content: String
        let mode: WorkspaceUIHook.MessageMode
    }
}

private enum TestError: Error {
    case encoding
}
