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
    @Test("POST message forwards a compatible model and waits for the canonical row")
    func post() async throws {
        let database = try await messageRouteDatabase()
        let messageID = UUID(0).uuidString
        let persistedMessage = Message(
            id: messageID,
            sessionID: "session-1",
            role: .user,
            content: "  Run the tests.  ",
            createdAt: Date(timeIntervalSince1970: 1_783_555_202),
            turnID: "turn-1"
        )

        let clock = TestClock()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.continuousClock = clock
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
            $0.sidecarBridgeClient.sendMessage = { request in
                let persistedSession = try? await database.read { database in
                    try Session.find(request.sessionID).fetchOne(database)
                }
                #expect(persistedSession?.model == .gpt_5_6_terra)
                #expect(persistedSession?.isFastModeEnabled == true)
                await recorder.record(request)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            let requestTask = Task {
                try await application.test(.router) { client in
                    try await client.execute(
                        uri: "/workspaces/workspace-1/sessions/session-1/messages",
                        method: .post,
                        headers: [.contentType: "application/json"],
                        body: ByteBuffer(
                            string: #"{"message":"  Run the tests.  ","model":"gpt-5.6-terra","fast_mode":true}"#
                        )
                    ) { response in
                        #expect(response.status == .ok)
                        let returnedMessage = try JSONDecoder.conductor.decode(
                            Message.self,
                            from: Data(response.body.readableBytesView)
                        )
                        #expect(returnedMessage == persistedMessage)
                    }
                }
            }

            await clock.advance()
            try await database.write { database in
                try Message.upsert { persistedMessage }.execute(database)
            }
            await clock.advance(by: .milliseconds(1))
            try await requestTask.value
        }

        #expect(
            await recorder.message == SidecarBridgeClient.RuntimeMessageRequest(
                agentType: "codex",
                cwd: "/tmp/workspace-1",
                isFastModeEnabled: true,
                message: "  Run the tests.  ",
                messageID: messageID,
                model: "gpt-5.6-terra",
                sessionID: "session-1",
                workspaceID: "workspace-1"
            )
        )
        #expect(await recorder.updatedSessionID == "session-1")
        #expect(await recorder.updatedModel == .gpt_5_6_terra)
        #expect(await recorder.isUpdatedFastModeEnabled == true)
    }

    @Test("POST message sends requested Fast Mode when the UI hook is unavailable")
    func unavailableUIHook() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.dispatch = { _, fallback, _ in
                try await fallback()
                return .sqliteFallback
            }
            $0.sidecarBridgeClient.sendMessage = { request in
                await recorder.record(request)
                try await persistMessage(for: request, database: database)
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
                    #expect(response.status == .ok)
                }
            }
        }

        #expect(await recorder.message?.isFastModeEnabled == true)
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
            $0.sidecarBridgeClient.sendMessage = { request in
                await recorder.record(request)
                try await persistMessage(for: request, database: database)
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
                    #expect(response.status == .ok)
                }
            }
        }

        #expect(await recorder.message?.isFastModeEnabled == false)
    }

    @Test("POST message does not reach the sidecar when Fast Mode delivery fails")
    func fastModeDeliveryFails() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.dispatch = { _, _, _ in
                throw WorkspaceUIHook.DispatchError.deliveryUnknown
            }
            $0.sidecarBridgeClient.sendMessage = { request in
                await recorder.record(request)
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
        let messageID = UUID(0).uuidString
        let persistedMessage = Message(
            id: messageID,
            sessionID: "session-1",
            role: .user,
            content: "Switch providers.",
            createdAt: Date(timeIntervalSince1970: 1_783_555_202),
            turnID: "turn-1"
        )

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
            $0.sidecarBridgeClient.sendMessage = { request in
                #expect(request.agentType == "claude")
                #expect(request.model == "fable-5")
                try await database.write { database in
                    try Message.insert { persistedMessage }.execute(database)
                }
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
                    #expect(response.status == .ok)
                }
            }
        }

        let session = try await database.read { database in
            try Session.find("session-1").fetchOne(database)
        }
        #expect(session?.agentType == .claude)
        #expect(session?.model == .fable5)
    }

    @Test("POST message requires the UI hook to change the session model")
    func modelChangeRequiresUIHook() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.updateSessionModel = { _, _, _ in false }
            $0.sidecarBridgeClient.sendMessage = { request in
                await recorder.record(request)
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
            $0.sidecarBridgeClient.sendMessage = { request in
                await recorder.record(request)
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

    @Test("POST message returns bad gateway when the message never appears")
    func messageDoesNotAppear() async throws {
        let database = try await messageRouteDatabase()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.sidecarBridgeClient.sendMessage = { _ in }
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
                            == "Conductor accepted the message, but it did not appear in the database before the persistence check timed out."
                    )
                }
            }
        }
    }

    @Test("POST message rejects blank input before contacting the sidecar bridge")
    func blankMessage() async throws {
        let database = try testConductorDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.sidecarBridgeClient.sendMessage = { message in
                await recorder.record(message)
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
        status: .idle,
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
    private(set) var message: SidecarBridgeClient.RuntimeMessageRequest?
    private(set) var isUpdatedFastModeEnabled: Bool?
    private(set) var updatedModel: Session.Model?
    private(set) var updatedSessionID: Session.ID?

    func record(_ message: SidecarBridgeClient.RuntimeMessageRequest) {
        self.message = message
    }

    func recordModelUpdate(sessionID: Session.ID, model: Session.Model) {
        updatedModel = model
        updatedSessionID = sessionID
    }

    func recordFastModeUpdate(isEnabled: Bool) {
        isUpdatedFastModeEnabled = isEnabled
    }
}

private func persistMessage(
    for request: SidecarBridgeClient.RuntimeMessageRequest,
    database: any DatabaseWriter
) async throws {
    try await database.write { database in
        try Message.insert {
            Message(
                id: request.messageID,
                sessionID: request.sessionID,
                role: .user,
                content: request.message,
                createdAt: Date(timeIntervalSince1970: 1_783_555_202),
                turnID: "turn-1"
            )
        }
        .execute(database)
    }
}
