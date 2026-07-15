//
//  StopRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import SharedConductorData
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct StopRouteTests {
    @Test("POST stop waits for and returns the canonical stopped session")
    func post() async throws {
        let database = try testConductorDatabase()
        let workingSession = stopRouteSession(status: .working)
        let stoppedSession = stopRouteSession(
            status: .idle,
            updatedAt: "2026-07-12T00:00:01Z"
        )
        try await database.write { database in
            try Session.insert { workingSession }.execute(database)
        }

        let clock = TestClock()
        let recorder = StopRouteRecorder()

        try await withDependencies {
            $0.continuousClock = clock
            $0.sidecarBridgeClient.stopSession = { request in
                await recorder.record(request)
            }
        } operation: {
            let application = Server.makeApplication(database: database)
            let requestTask = Task {
                try await application.test(.router) { client in
                    try await client.execute(
                        uri: "/workspaces/workspace-1/sessions/session-1/stop",
                        method: .post
                    ) { response in
                        #expect(response.status == .ok)
                        let session = try JSONDecoder.conductor.decode(
                            Session.self,
                            from: Data(response.body.readableBytesView)
                        )
                        await recorder.record(session)
                    }
                }
            }

            await clock.advance()
            #expect(await recorder.request != nil)
            #expect(await recorder.session == nil)

            try await database.write { database in
                try Session.upsert { stoppedSession }.execute(database)
            }
            await clock.advance(by: .milliseconds(1))
            try await requestTask.value
        }

        #expect(
            await recorder.request
                == SidecarBridgeClient.RuntimeStopRequest(
                    agentType: "codex",
                    sessionID: "session-1"
                )
        )
        #expect(await recorder.session == stoppedSession)
    }

    @Test("POST stop returns bad gateway when the session remains working")
    func sessionDoesNotStop() async throws {
        let database = try testConductorDatabase()
        let workingSession = stopRouteSession(status: .working)
        try await database.write { database in
            try Session.insert { workingSession }.execute(database)
        }

        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0.sidecarBridgeClient.stopSession = { _ in }
        } operation: {
            let application = Server.makeApplication(database: database)
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspaces/workspace-1/sessions/session-1/stop",
                    method: .post
                ) { response in
                    #expect(response.status == .badGateway)
                    #expect(
                        String(buffer: response.body)
                            == "Conductor accepted the stop request, but the session did not stop in the database before the persistence check timed out."
                    )
                }
            }
        }
    }

    @Test("POST stop rejects a session outside the selected workspace")
    func sessionNotFound() async throws {
        let database = try testConductorDatabase()
        let session = stopRouteSession(status: .working)
        try await database.write { database in
            try Session.insert { session }.execute(database)
        }
        let recorder = StopRouteRecorder()

        try await withDependencies {
            $0.sidecarBridgeClient.stopSession = { request in
                await recorder.record(request)
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

        #expect(await recorder.request == nil)
    }
}

private actor StopRouteRecorder {
    private(set) var request: SidecarBridgeClient.RuntimeStopRequest?
    private(set) var session: Session?

    func record(_ request: SidecarBridgeClient.RuntimeStopRequest) {
        self.request = request
    }

    func record(_ session: Session) {
        self.session = session
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
