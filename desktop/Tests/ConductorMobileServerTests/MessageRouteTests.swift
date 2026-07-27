//
//  MessageRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/15/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import NIOCore
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct MessageRouteTests {
    @Test("POST message sends through the UI hook and returns no content")
    func post() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.updateSessionModel = { sessionID, model, waitUntilChangeAvailableInDatabase in
                await recorder.recordModelUpdate(sessionID: sessionID, model: model)
                try await database.write { database in
                    try Session
                        .find(sessionID)
                        .update { $0.model = #bind(model) }
                        .execute(database)
                }
                try await waitUntilChangeAvailableInDatabase()
                return true
            }
            $0.workspaceUIHook.dispatch = { command, _, waitUntilChangeAvailableInDatabase in
                #expect(
                    command == .sessionFastMode(
                        sessionID: "session-1",
                        isEnabled: true
                    )
                )
                await recorder.recordFastModeUpdate(isEnabled: true)
                try await database.write { database in
                    try Session
                        .find("session-1")
                        .update { $0.isFastModeEnabled = #bind(true) }
                        .execute(database)
                }
                try await waitUntilChangeAvailableInDatabase()
                return .hook
            }
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, reasoningEffort in
                let persistedSession = try await database.read { database in
                    try Session.find(sessionID).fetchOne(database)
                }
                #expect(persistedSession?.model == .gpt_5_6_terra)
                #expect(persistedSession?.isFastModeEnabled == true)
                #expect(reasoningEffort == .ultra)
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"  Run the tests.  ","model":"gpt-5.6-terra","fast_mode":true,"mode":"queued","reasoning_effort":"ultra"}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(response.body.readableBytes == 0)
                }
            }
        }

        #expect(
            await recorder.message == MessageRouteRecorder.RecordedMessage(
                sessionID: "session-1",
                content: "  Run the tests.  ",
                mode: .queued
            )
        )
        #expect(await recorder.updatedSessionID == "session-1")
        #expect(await recorder.updatedModel == .gpt_5_6_terra)
        #expect(await recorder.isUpdatedFastModeEnabled == true)
    }

    @Test("POST message returns unavailable when the UI hook cannot send")
    func unavailableUIHook() async throws {
        let database = try await messageRouteDatabase()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { _, fallback, _ in
                try await fallback?()
                return .sqliteFallback
            }
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in
                throw WorkspaceUIHook.CommandDispatchError.listenerUnavailable
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Run fast.","model":"gpt-5.5","fast_mode":true}"#
                    )
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(
                        String(buffer: response.body)
                            == "Conductor's workspace UI hook is unavailable."
                    )
                }
            }
        }

        let isPersistedFastModeEnabled = try await database.read { database in
            try Session.find("session-1").fetchOne(database)?.isFastModeEnabled
        }
        #expect(isPersistedFastModeEnabled == true)
    }

    @Test("POST message skips Fast Mode synchronization when unchanged")
    func unchangedFastMode() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { _, _, _ in
                Issue.record("Fast Mode should not be synchronized when unchanged.")
                return .hook
            }
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Run normally.","model":"gpt-5.5","fast_mode":false}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(
            await recorder.message == MessageRouteRecorder.RecordedMessage(
                sessionID: "session-1",
                content: "Run normally.",
                mode: .sent
            )
        )
    }

    @Test("POST message does not send when Fast Mode delivery fails")
    func fastModeDeliveryFails() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.dispatch = { _, _, _ in
                throw WorkspaceUIHook.DispatchError.deliveryUnknown
            }
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Run fast.","model":"gpt-5.5","fast_mode":true}"#
                    )
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(
                        String(buffer: response.body)
                            == "Could not determine whether Fast Mode was delivered."
                    )
                }
            }
        }

        #expect(await recorder.message == nil)
    }

    @Test("POST first message can switch the session agent and model")
    func firstMessageSwitchesAgent() async throws {
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
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, reasoningEffort in
                let persistedSession = try await database.read { database in
                    try Session.find(sessionID).fetchOne(database)
                }
                #expect(persistedSession?.agentType == .claude)
                #expect(persistedSession?.model == .fable5)
                #expect(reasoningEffort == .ultracode)
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Switch providers.","model":"fable-5","reasoning_effort":"ultracode"}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let session = try await database.read { database in
            try Session.find("session-1").fetchOne(database)
        }
        #expect(session?.agentType == .claude)
        #expect(session?.model == .fable5)
        #expect(await recorder.message?.content == "Switch providers.")
    }

    @Test("POST message requires the UI hook to change the session model")
    func modelChangeRequiresUIHook() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.updateSessionModel = { _, _, _ in false }
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Use Terra.","model":"gpt-5.6-terra"}"#
                    )
                ) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(
                        String(buffer: response.body)
                            == "Conductor is not connected to change the session model."
                    )
                }
            }
        }

        #expect(await recorder.message == nil)
    }

    @Test("POST message rejects a model from another agent after a message was sent")
    func incompatibleModelAfterMessage() async throws {
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update { $0.lastUserMessageAt = #bind("2026-07-09T00:01:00Z") }
                .execute(database)
        }
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Switch providers.","model":"fable-5"}"#
                    )
                ) { response in
                    #expect(response.status == .badRequest)
                    #expect(
                        String(buffer: response.body)
                            == "Model is not available for this session's agent."
                    )
                }
            }
        }

        #expect(await recorder.message == nil)
    }

    @Test("POST message reports unknown delivery when its callback misses the deadline")
    func deliveryUnknown() async throws {
        let database = try await messageRouteDatabase()
        let clock = ContinuousClock()
        let (sendStarted, sendStartedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (receiptGate, receiptGateContinuation) = AsyncStream<Void>.makeStream()
        defer {
            sendStartedContinuation.finish()
            receiptGateContinuation.finish()
        }

        try await withDependencies {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in
                sendStartedContinuation.yield(())
                for await _ in receiptGate {}
                throw CancellationError()
            }
        } operation: {
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(50)
            )
            let request = Task {
                try await application.test(.router) { client in
                    try await client.execute(
                        uri: "/workspaces/workspace-1/sessions/session-1/messages",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: ByteBuffer(string: #"{"message":"Run the tests."}"#)
                    ) { response in
                        #expect(response.status == .serviceUnavailable)
                        #expect(
                            String(buffer: response.body)
                                == "Could not determine whether the message was delivered. Check the conversation before retrying."
                        )
                    }
                }
            }
            for await _ in sendStarted {
                break
            }
            try await request.value
        }
    }

    @Test("POST message preserves a definite browser failure")
    func commandFailure() async throws {
        let database = try await messageRouteDatabase()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in
                throw WorkspaceUIHook.CommandDispatchError.commandFailed("Rejected.")
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"message":"Run the tests."}"#)
                ) { response in
                    #expect(response.status == .badGateway)
                    #expect(
                        String(buffer: response.body)
                            == "Conductor could not send the message: Rejected."
                    )
                }
            }
        }
    }

    @Test("POST message rejects Ultra reasoning for Claude")
    func claudeUltraReasoning() async throws {
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

        try await withDependencies {
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in
                Issue.record("Invalid reasoning effort should not be sent.")
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Think deeply.","reasoning_effort":"ultra"}"#
                    )
                ) { response in
                    #expect(response.status == .badRequest)
                    #expect(
                        String(buffer: response.body)
                            == "Reasoning effort is not available for this model."
                    )
                }
            }
        }
    }

    @Test("POST message forwards Ultracode reasoning for Claude")
    func claudeUltracodeReasoning() async throws {
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

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, reasoningEffort in
                #expect(reasoningEffort == .ultracode)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Think deeply.","reasoning_effort":"ultracode"}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }
    }

    @Test("POST message forwards Default reasoning for Codex")
    func defaultReasoning() async throws {
        let database = try await messageRouteDatabase()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, reasoningEffort in
                #expect(reasoningEffort == Session.ReasoningEffort.none)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string: #"{"message":"Use the default.","reasoning_effort":"none"}"#
                    )
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }
    }

    @Test("POST message sends immediately for an idle session")
    func idleSession() async throws {
        let database = try await messageRouteDatabase()
        try await database.write { database in
            try Session
                .find("session-1")
                .update { $0.status = Session.Status.idle }
                .execute(database)
        }
        let recorder = MessageRouteRecorder()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"message":"Run the tests."}"#)
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(await recorder.message?.mode == .sent)
    }

    @Test("POST message rejects blank input before contacting the UI hook")
    func blankMessage() async throws {
        let database = try testConductorDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, sessionID, _, content, mode, _ in
                await recorder.recordMessage(
                    sessionID: sessionID,
                    content: content,
                    mode: mode
                )
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/messages",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: #"{"message":" \n "}"#)
                ) { response in
                    #expect(response.status == .badRequest)
                    #expect(String(buffer: response.body) == "Message cannot be empty.")
                }
            }
        }

        #expect(await recorder.message == nil)
    }
}

private func messageRouteDatabase() async throws -> DatabaseQueue {
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
        status: .working,
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
    private(set) var isUpdatedFastModeEnabled: Bool?
    private(set) var updatedModel: Session.Model?
    private(set) var updatedSessionID: Session.ID?

    func recordMessage(
        sessionID: Session.ID,
        content: String,
        mode: WorkspaceUIHook.MessageMode
    ) {
        message = RecordedMessage(
            sessionID: sessionID,
            content: content,
            mode: mode
        )
    }

    func recordModelUpdate(sessionID: Session.ID, model: Session.Model) {
        updatedModel = model
        updatedSessionID = sessionID
    }

    func recordFastModeUpdate(isEnabled: Bool) {
        isUpdatedFastModeEnabled = isEnabled
    }

    struct RecordedMessage: Equatable {
        let sessionID: Session.ID
        let content: String
        let mode: WorkspaceUIHook.MessageMode
    }
}
