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
                mode in
                await recorder.record(
                    requestID: requestID,
                    attemptID: receivedAttemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return WorkspaceUIHook.MessageReceipt(messageID: messageID)
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: attemptID),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt == .accepted(attemptID: attemptID, messageID: messageID))
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
                mode in
                await recorder.record(
                    requestID: requestID,
                    attemptID: attemptID,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    content: content,
                    mode: mode
                )
                return WorkspaceUIHook.MessageReceipt(messageID: "message-id")
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

    @Test("A missing UI hook listener is rejected")
    func listenerUnavailable() async throws {
        try await expectResult(
            from: WorkspaceUIHook.CommandDispatchError.listenerUnavailable,
            expectedType: .rejected
        )
    }

    @Test("Post-enqueue failures are unknown", arguments: [
        WorkspaceUIHook.CommandDispatchError.commandFailed("Browser rejected."),
        .deliveryUnknown,
        .persistenceTimedOut,
    ])
    func postEnqueueFailure(error: WorkspaceUIHook.CommandDispatchError) async throws {
        try await expectResult(from: error, expectedType: .unknown)
    }

    @Test("A pre-enqueue encoding failure is rejected")
    func preEnqueueFailure() async throws {
        try await expectResult(from: TestError.encoding, expectedType: .rejected)
    }

    @Test("Model update failure is rejected before sending")
    func modelUpdateFailure() async throws {
        let database = try await messageRouteDatabase()
        let recorder = MessageRouteRecorder()
        try await withDependencies {
            $0.workspaceUIHook.updateSessionModel = { _, _, _ in false }
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in
                await recorder.markSent()
                return WorkspaceUIHook.MessageReceipt(messageID: "unexpected")
            }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(44), model: "gpt-5.6-terra"),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt?.type == .rejected)
        }
        #expect(await recorder.didSend == false)
    }

    @Test("Malformed and blank requests remain untyped 400 responses", arguments: [
        #"{"message":"Run tests"}"#,
        #"{"attemptId":"00000000-0000-0000-0000-000000000045","message":"  \n ","model":"gpt-5.5"}"#,
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
        expectedType: RouteReceipt.ResultType
    ) async throws {
        let database = try await messageRouteDatabase()
        try await withDependencies {
            $0.uuid = .incrementing
            $0.workspaceUIHook.sendMessage = { _, _, _, _, _, _ in throw error }
        } operation: {
            let response = try await postMessage(
                body: requestBody(attemptID: UUID(46)),
                database: database
            )
            #expect(response.status == .ok)
            #expect(response.receipt?.type == expectedType)
            #expect(response.receipt?.attemptID == UUID(46))
            #expect(response.receipt?.reason?.isEmpty == false)
        }
    }
}

private func requestBody(
    attemptID: UUID,
    model: String = "gpt-5.5"
) -> String {
    #"{"attemptId":"\#(attemptID.uuidString)","message":"  Run the tests.  ","model":"\#(model)"}"#
}

private func postMessage(
    body: String,
    database: DatabaseQueue
) async throws -> (status: HTTPResponse.Status, receipt: RouteReceipt?) {
    let application = Server.makeApplication(database: database)
    let result = LockIsolated<(HTTPResponse.Status, RouteReceipt?)?>(nil)
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
                    try? JSONDecoder().decode(RouteReceipt.self, from: data)
                )
            }
        }
    }
    return try #require(result.value)
}

private struct RouteReceipt: Decodable, Equatable {
    let attemptID: UUID
    let result: Result

    var type: ResultType { result.type }
    var messageID: String? { result.messageID }
    var reason: String? { result.reason }

    static func accepted(attemptID: UUID, messageID: String) -> Self {
        Self(
            attemptID: attemptID,
            result: Result(type: .accepted, messageID: messageID, reason: nil)
        )
    }

    struct Result: Decodable, Equatable {
        let type: ResultType
        let messageID: String?
        let reason: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case messageID = "messageId"
            case reason
        }
    }

    enum ResultType: String, Decodable, Equatable {
        case accepted
        case rejected
        case unknown
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case result
    }
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
