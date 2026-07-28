//
//  CloudReadObservationStreamTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

@testable import ConductorCloud
import Dependencies
import Foundation
import Testing

@MainActor
struct CloudReadObservationTests {
    @Test("Session observation paginates details and preserves unknown statuses")
    func sessionPagination() async throws {
        let fixture = SessionTransportFixture()
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }

        let snapshot = try await withDependencies {
            $0.cloudAPITransport.data = { request in
                try await fixture.response(for: request)
            }
        } operation: {
            var iterator = client.observeSessions("workspace").makeAsyncIterator()
            return try #require(try await iterator.next())
        }

        #expect(snapshot.accountID == "user::")
        #expect(snapshot.workspace.id == "workspace")
        #expect(snapshot.sessions.map(\.id) == ["session-1", "session-2"])
        #expect(snapshot.statuses["session-1"]?.status == .working)
        #expect(
            snapshot.statuses["session-2"]?.status.rawValue
                == "future-status"
        )
        #expect(await fixture.sessionOffsets() == [0, 1])
    }

    @Test("Transcript observation completes initial pages before using an incremental cursor")
    func initialAndIncrementalTranscript() async throws {
        let fixture = TranscriptTransportFixture()
        let clock = TestClock()
        let snapshots = LockIsolated<[CloudTranscriptSnapshot]>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }

        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                try await fixture.response(for: request)
            }
            $0.continuousClock = clock
        } operation: {
            Task {
                for try await snapshot in client.observeTranscript("session") {
                    snapshots.withValue { $0.append(snapshot) }
                }
            }
        }

        await waitForReadCondition { snapshots.value.count == 1 }
        #expect(snapshots.value[0].isFullSnapshot)
        #expect(snapshots.value[0].messages.map(\.id) == ["message-1", "message-2"])
        #expect(await fixture.offsets() == [0, 1])
        #expect(await fixture.incrementalCursors().isEmpty)

        await clock.advance(by: .milliseconds(2_500))
        await waitForReadCondition { snapshots.value.count == 2 }
        #expect(!snapshots.value[1].isFullSnapshot)
        #expect(snapshots.value[1].messages.map(\.id) == ["message-1"])
        #expect(await fixture.incrementalCursors() == ["message-2"])
        #expect(snapshots.value[1].status.status == .idle)

        observation.cancel()
        try await observation.value
    }

    @Test("Idle transcript polling waits ten seconds and cancellation ends observation")
    func idleCadenceAndCancellation() async throws {
        let fixture = IdleTranscriptTransportFixture()
        let clock = TestClock()
        let snapshotCount = LockIsolated(0)
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }

        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                try await fixture.response(for: request)
            }
            $0.continuousClock = clock
        } operation: {
            Task {
                for try await _ in client.observeTranscript("session") {
                    snapshotCount.withValue { $0 += 1 }
                }
            }
        }

        await waitForReadCondition { snapshotCount.value == 1 }
        #expect(await fixture.messageRequestCount() == 1)
        await clock.advance(by: .seconds(9))
        await Task.yield()
        #expect(await fixture.messageRequestCount() == 1)
        await clock.advance(by: .seconds(1))
        await waitForReadCondition {
            await fixture.messageRequestCount() == 2
        }

        observation.cancel()
        try await observation.value
    }
}

private let testBaseURL = URL(string: "https://cloud.test")!

private actor SessionTransportFixture {
    private var offsets: [Int] = []

    func response(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        switch path {
        case "/me":
            return try fixtureResponse(
                #"{"userId":"user","authMethod":"api-key"}"#,
                request
            )

        case "/v0/workspaces/workspace":
            return try fixtureResponse(
                #"""
                {
                  "id": "workspace",
                  "name": "Cloud workspace",
                  "createdAt": "2026-07-27T12:00:00Z"
                }
                """#,
                request
            )

        case "/v0/workspaces/workspace/sessions":
            let offset = query("offset", request: request).flatMap(Int.init) ?? 0
            offsets.append(offset)
            return try fixtureResponse(
                page(
                    data: sessionJSON(id: "session-\(offset + 1)"),
                    offset: offset,
                    hasMore: offset == 0
                ),
                request
            )

        case "/v0/sessions/session-1/status":
            return try fixtureResponse(
                statusJSON(sessionID: "session-1", status: "working"),
                request
            )

        case "/v0/sessions/session-2/status":
            return try fixtureResponse(
                statusJSON(sessionID: "session-2", status: "future-status"),
                request
            )

        default:
            throw FixtureError.unexpectedPath(path)
        }
    }

    func sessionOffsets() -> [Int] {
        offsets
    }
}

private actor TranscriptTransportFixture {
    private var messageOffsets: [Int] = []
    private var cursors: [String] = []
    private var statusCount = 0

    func response(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        switch path {
        case "/me":
            return try fixtureResponse(
                #"{"userId":"user","authMethod":"api-key"}"#,
                request
            )

        case "/v0/sessions/session/status":
            statusCount += 1
            return try fixtureResponse(
                statusJSON(
                    sessionID: "session",
                    status: statusCount == 1 ? "working" : "idle"
                ),
                request
            )

        case "/v0/sessions/session/messages":
            if let cursor = query("after", request: request) {
                cursors.append(cursor)
                return try fixtureResponse(
                    page(
                        data: messageJSON(id: "message-1", index: 1, text: "updated"),
                        offset: 0,
                        hasMore: false
                    ),
                    request
                )
            }
            let offset = query("offset", request: request).flatMap(Int.init) ?? 0
            messageOffsets.append(offset)
            return try fixtureResponse(
                page(
                    data: messageJSON(
                        id: "message-\(offset + 1)",
                        index: Double(offset + 1),
                        text: "initial"
                    ),
                    offset: offset,
                    hasMore: offset == 0
                ),
                request
            )

        default:
            throw FixtureError.unexpectedPath(path)
        }
    }

    func offsets() -> [Int] {
        messageOffsets
    }

    func incrementalCursors() -> [String] {
        cursors
    }
}

private actor IdleTranscriptTransportFixture {
    private var messageRequests = 0

    func response(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        switch path {
        case "/me":
            return try fixtureResponse(
                #"{"userId":"user","authMethod":"api-key"}"#,
                request
            )

        case "/v0/sessions/session/status":
            return try fixtureResponse(
                statusJSON(sessionID: "session", status: "idle"),
                request
            )

        case "/v0/sessions/session/messages":
            messageRequests += 1
            return try fixtureResponse(
                page(
                    data: "",
                    offset: 0,
                    hasMore: false
                ),
                request
            )

        default:
            throw FixtureError.unexpectedPath(path)
        }
    }

    func messageRequestCount() -> Int {
        messageRequests
    }
}

private enum FixtureError: Error {
    case invalidResponse
    case unexpectedPath(String)
}

private func fixtureResponse(
    _ body: String,
    _ request: URLRequest
) throws -> (Data, HTTPURLResponse) {
    guard let url = request.url,
          let response = HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: nil,
              headerFields: ["Content-Type": "application/json"]
          ) else {
        throw FixtureError.invalidResponse
    }
    return (Data(body.utf8), response)
}

private func query(
    _ name: String,
    request: URLRequest
) -> String? {
    guard let url = request.url,
          let components = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          ) else {
        return nil
    }
    return components.queryItems?.first { $0.name == name }?.value
}

private func page(
    data: String,
    offset: Int,
    hasMore: Bool
) -> String {
    """
    {
      "data": [\(data)],
      "offset": \(offset),
      "hasMore": \(hasMore)
    }
    """
}

private func sessionJSON(id: String) -> String {
    """
    {
      "id": "\(id)",
      "deepLink": "https://conductor.build/sessions/\(id)",
      "name": "\(id)",
      "model": "gpt-5.6-sol"
    }
    """
}

private func statusJSON(
    sessionID: String,
    status: String
) -> String {
    """
    {
      "workspaceId": "workspace",
      "sessionId": "\(sessionID)",
      "status": "\(status)",
      "updatedAt": "2026-07-27T12:00:00Z"
    }
    """
}

private func messageJSON(
    id: String,
    index: Double,
    text: String
) -> String {
    """
    {
      "id": "\(id)",
      "sessionId": "session",
      "sessionIndex": \(index),
      "type": "event",
      "content": {
        "type": "userMessage",
        "message": "\(text)"
      },
      "receivedAt": "2026-07-27T12:00:00Z"
    }
    """
}

private func waitForReadCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<1_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for Cloud observation.")
}
