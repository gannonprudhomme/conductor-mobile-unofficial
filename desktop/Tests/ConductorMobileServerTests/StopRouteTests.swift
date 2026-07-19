//
//  StopRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import Hummingbird
import HummingbirdTesting
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct StopRouteTests {
    @Test("POST stop returns the stopped session observed during persistence")
    func post() async throws {
        let database = try testConductorDatabase()
        let stoppedSession = stopRouteSession(
            status: .idle,
            updatedAt: "2026-07-12T00:00:01Z"
        )
        let resumedSession = stopRouteSession(
            status: .working,
            updatedAt: "2026-07-12T00:00:02Z"
        )
        try await insertStopRouteSession(status: .working, into: database)
        let recorder = StopRouteRecorder()

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.uuid = .incrementing
            $0.workspaceUIHook.stopSession = { requestID, sessionID, waitUntilStopped in
                await recorder.record(requestID: requestID, sessionID: sessionID)
                try await database.write { database in
                    try Session.upsert { stoppedSession }.execute(database)
                }
                let observedSession = try #require(try await waitUntilStopped())
                try await database.write { database in
                    try Session.upsert { resumedSession }.execute(database)
                }
                return observedSession
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: stopURI,
                    method: .post
                ) { response in
                    #expect(response.status == .ok)
                    let session = try JSONDecoder.conductor.decode(
                        Session.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(session == stoppedSession)
                }
            }
        }

        #expect(await recorder.requestID == UUID(0))
        #expect(await recorder.sessionID == "session-1")
    }

    @Test("POST stop is idempotent for an already stopped session")
    func alreadyStopped() async throws {
        let database = try testConductorDatabase()
        let session = stopRouteSession(status: .idle)
        try await database.write { database in
            try Session.insert { session }.execute(database)
        }
        let recorder = StopRouteRecorder()

        try await withDependencies {
            $0.workspaceUIHook.stopSession = { requestID, sessionID, _ in
                await recorder.record(requestID: requestID, sessionID: sessionID)
                return session
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(uri: stopURI, method: .post) { response in
                    #expect(response.status == .ok)
                    let responseSession = try JSONDecoder.conductor.decode(
                        Session.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(responseSession == session)
                }
            }
        }

        #expect(await recorder.sessionID == nil)
    }

    @Test("POST stop maps explicit controller rejection to bad gateway")
    func controllerRejection() async throws {
        try await expectStopError(
            .commandFailed("Rejected."),
            status: .badGateway,
            message: "Conductor could not stop the session: Rejected."
        )
    }

    @Test("POST stop maps a disconnected hook to service unavailable")
    func disconnectedHook() async throws {
        try await expectStopError(
            .listenerUnavailable,
            status: .serviceUnavailable,
            message: "Conductor's workspace UI hook is unavailable."
        )
    }

    @Test("POST stop times out when a connected hook omits its callback")
    func callbackLoss() async throws {
        let database = try testConductorDatabase()
        try await insertStopRouteSession(status: .working, into: database)
        let clock = ContinuousClock()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()

        try await withDependencies {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.workspaceUIHook = uiHook
        } operation: {
            var events = connection.events.makeAsyncIterator()
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(50)
            )
            let request = Task {
                try await application.test(.router) { client in
                    try await client.execute(uri: stopURI, method: .post) { response in
                        #expect(response.status == .serviceUnavailable)
                        #expect(
                            String(buffer: response.body)
                                == "Could not determine whether Conductor received the stop command."
                        )
                    }
                }
            }
            let event = await events.next()
            #expect(event != nil)
            try await request.value
            await uiHook.disconnect(connectionID: connection.id)
        }
    }

    @Test("POST stop returns canonical persistence after callback loss")
    func callbackLossAfterPersistence() async throws {
        let database = try testConductorDatabase()
        try await insertStopRouteSession(status: .working, into: database)
        let stoppedSession = stopRouteSession(
            status: .idle,
            updatedAt: "2026-07-12T00:00:01Z"
        )
        let clock = ContinuousClock()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()

        try await withDependencies {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.workspaceUIHook = uiHook
        } operation: {
            var events = connection.events.makeAsyncIterator()
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(50)
            )
            let request = Task {
                try await application.test(.router) { client in
                    try await client.execute(uri: stopURI, method: .post) { response in
                        #expect(response.status == .ok)
                        let session = try JSONDecoder.conductor.decode(
                            Session.self,
                            from: Data(response.body.readableBytesView)
                        )
                        #expect(session == stoppedSession)
                    }
                }
            }
            let event = await events.next()
            #expect(event != nil)
            await uiHook.disconnect(connectionID: connection.id)
            try await database.write { database in
                try Session.upsert { stoppedSession }.execute(database)
            }
            try await request.value
        }
    }

    @Test("POST stop uses the shared timeout after controller acceptance")
    func acceptedWithoutPersistence() async throws {
        let database = try testConductorDatabase()
        try await insertStopRouteSession(status: .working, into: database)
        let clock = ContinuousClock()
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()

        try await withDependencies {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.workspaceUIHook = uiHook
        } operation: {
            var events = connection.events.makeAsyncIterator()
            let application = Server.makeApplication(
                database: database,
                uiCommandTimeout: .milliseconds(75)
            )
            let request = Task {
                try await application.test(.router) { client in
                    try await client.execute(uri: stopURI, method: .post) { response in
                        #expect(response.status == .gatewayTimeout)
                        #expect(
                            String(buffer: response.body)
                                == "Conductor accepted the stop command, but the session remained working."
                        )
                    }
                }
            }
            let event = await events.next()
            #expect(event != nil)
            #expect(
                await uiHook.didCompleteCommand(
                    result: WorkspaceUIHook.CommandResult(
                        requestID: UUID(0),
                        error: nil
                    )
                )
            )
            try await request.value
        }
    }

    @Test("POST stop rejects a session outside the selected workspace")
    func sessionNotFound() async throws {
        let database = try testConductorDatabase()
        try await insertStopRouteSession(status: .working, into: database)
        let recorder = StopRouteRecorder()

        try await withDependencies {
            $0.workspaceUIHook.stopSession = { requestID, sessionID, _ in
                await recorder.record(requestID: requestID, sessionID: sessionID)
                return stopRouteSession(status: .idle)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/other-workspace/sessions/session-1/stop",
                    method: .post
                ) { response in
                    #expect(response.status == .notFound)
                    #expect(String(buffer: response.body) == "Session not found.")
                }
            }
        }

        #expect(await recorder.sessionID == nil)
    }
}

private func expectStopError(
    _ error: WorkspaceUIHook.CommandDispatchError,
    status: HTTPResponse.Status,
    message: String
) async throws {
    let database = try testConductorDatabase()
    try await insertStopRouteSession(status: .working, into: database)

    try await withDependencies {
        $0.continuousClock = ContinuousClock()
        $0.uuid = .incrementing
        $0.workspaceUIHook.stopSession = { _, _, _ in
            throw error
        }
    } operation: {
        let application = Server.makeApplication(database: database)
        try await application.test(.router) { client in
            try await client.execute(uri: stopURI, method: .post) { response in
                #expect(response.status == status)
                #expect(String(buffer: response.body) == message)
            }
        }
    }
}

private actor StopRouteRecorder {
    private(set) var requestID: UUID?
    private(set) var sessionID: Session.ID?

    func record(requestID: UUID, sessionID: Session.ID) {
        self.requestID = requestID
        self.sessionID = sessionID
    }
}

private func insertStopRouteSession(
    status: Session.Status,
    into database: DatabaseQueue
) async throws {
    let session = stopRouteSession(status: status)
    try await database.write { database in
        try Session.insert { session }.execute(database)
    }
}

private func stopRouteSession(
    status: Session.Status,
    updatedAt: String = "2026-07-12T00:00:00Z"
) -> Session {
    Session(
        id: "session-1",
        workspaceID: "workspace-1",
        title: "Working",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-12T00:00:00Z",
        updatedAt: updatedAt,
        lastUserMessageAt: nil,
        status: status,
        model: .gpt5_5,
        unreadCount: 0,
        freshlyCompacted: 0,
        contextTokenCount: 0
    )
}

private let stopURI = "/workspaces/workspace-1/sessions/session-1/stop"
