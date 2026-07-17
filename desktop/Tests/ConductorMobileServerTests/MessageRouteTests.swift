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
            $0.sidecarBridgeClient.sendMessage = { request in
                let persistedModel = try? await database.read { database in
                    try Session.find(request.sessionID).fetchOne(database)?.model
                }
                #expect(persistedModel == .gpt_5_6_terra)
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
                            string: #"{"message":"  Run the tests.  ","model":"gpt-5.6-terra"}"#
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
                message: "  Run the tests.  ",
                messageID: messageID,
                model: "gpt-5.6-terra",
                sessionID: "session-1",
                workspaceID: "workspace-1"
            )
        )
        #expect(await recorder.updatedSessionID == "session-1")
        #expect(await recorder.updatedModel == .gpt_5_6_terra)
    }

    @Test("POST message rejects a model from another agent")
    func incompatibleModel() async throws {
        let database = try await messageRouteDatabase()
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
        contextTokenCount: 0
    )
    try await database.write { database in
        try Workspace.insert { workspace }.execute(database)
        try Session.insert { session }.execute(database)
    }
    return database
}

private actor MessageRouteRecorder {
    private(set) var message: SidecarBridgeClient.RuntimeMessageRequest?
    private(set) var updatedModel: Session.Model?
    private(set) var updatedSessionID: Session.ID?

    func record(_ message: SidecarBridgeClient.RuntimeMessageRequest) {
        self.message = message
    }

    func recordModelUpdate(sessionID: Session.ID, model: Session.Model) {
        updatedModel = model
        updatedSessionID = sessionID
    }
}
