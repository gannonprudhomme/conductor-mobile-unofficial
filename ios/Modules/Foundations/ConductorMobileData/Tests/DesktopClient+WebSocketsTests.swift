//
//  DesktopClient+WebSocketsTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

@testable import ConductorMobileData
import CustomDump
import Dependencies
import Foundation
import SharedConductorData
import Sharing
import SQLiteData
import Testing

struct DesktopClientWebSocketsTests {
    @Test("Transcript benchmark reports transport and mobile stages")
    func transcriptBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TRANSCRIPT_BENCHMARK_RUN"] == "1",
              let serverAddress = environment["TRANSCRIPT_BENCHMARK_SERVER"],
              let workloadJSON = environment["TRANSCRIPT_BENCHMARK_WORKLOADS"] else {
            return
        }
        let workloads = try JSONDecoder().decode(
            [MobileTranscriptBenchmarkWorkload].self,
            from: Data(workloadJSON.utf8)
        )
        let warmupCount = Int(environment["TRANSCRIPT_BENCHMARK_WARMUPS"] ?? "") ?? 2
        let iterationCount = Int(environment["TRANSCRIPT_BENCHMARK_ITERATIONS"] ?? "") ?? 10
        let clock = ContinuousClock()

        for workload in workloads {
            for iteration in 0..<(warmupCount + iterationCount) {
                let database = try DatabaseQueue()
                try appDatabaseMigrator().migrate(database)
                try await database.write { database in
                    try Workspace.insert {
                        Workspace.preview(id: workload.workspaceID)
                    }
                    .execute(database)
                    try Session.insert {
                        Session.preview(
                            id: workload.sessionID,
                            workspaceID: workload.workspaceID
                        )
                    }
                    .execute(database)
                }

                let url = try #require(
                    DesktopClient.messagesWebSocketURL(
                        serverAddress: serverAddress,
                        workspaceID: workload.workspaceID,
                        sessionID: workload.sessionID
                    )
                )
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 120
                let session = URLSession(configuration: configuration)
                let task = session.webSocketTask(with: url)
                task.maximumMessageSize = DesktopClient.maximumWebSocketMessageSize

                let start = clock.now
                task.resume()
                let frame = try await task.receive()
                let firstEvent = clock.now
                let data = switch frame {
                case let .data(data):
                    data
                case let .string(string):
                    Data(string.utf8)
                @unknown default:
                    throw DesktopClientError.invalidResponse
                }

                let decodeStart = clock.now
                let event = try JSONDecoder.conductor.decode(
                    MessageSyncEvent.self,
                    from: data
                )
                let decoded = clock.now

                let persistenceStart = clock.now
                try await DesktopTranscriptStore.applySyncEvent(
                    event,
                    workspaceID: workload.workspaceID,
                    sessionID: workload.sessionID,
                    database: database
                )
                let persisted = clock.now

                let visibilityStart = clock.now
                let cached = try await DesktopTranscriptStore.cachedTranscriptSnapshot(
                    workspaceID: workload.workspaceID,
                    sessionID: workload.sessionID,
                    database: database
                )
                let visible = clock.now
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()

                guard iteration >= warmupCount else {
                    continue
                }
                let result = MobileTranscriptBenchmarkResult(
                    label: workload.label,
                    iteration: iteration - warmupCount,
                    messageCount: event.messages.count
                        + (event.queuedMessages?.count ?? 0),
                    eventCount: 1,
                    frameBytes: data.count,
                    firstEventMilliseconds: benchmarkMilliseconds(
                        from: start,
                        to: firstEvent
                    ),
                    decodeMilliseconds: benchmarkMilliseconds(
                        from: decodeStart,
                        to: decoded
                    ),
                    persistenceMilliseconds: benchmarkMilliseconds(
                        from: persistenceStart,
                        to: persisted
                    ),
                    visibleQueryMilliseconds: benchmarkMilliseconds(
                        from: visibilityStart,
                        to: visible
                    ),
                    totalMilliseconds: benchmarkMilliseconds(
                        from: start,
                        to: visible
                    ),
                    visibleMessageCount: cached?.messages.count ?? 0
                )
                print(
                    "TRANSCRIPT_MOBILE_BENCHMARK "
                        + String(
                            decoding: try JSONEncoder().encode(result),
                            as: UTF8.self
                        )
                )
            }
        }
    }

    @Test("WebSocket resource URLs use the desktop service")
    func webSocketURLs() {
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(
                serverAddress: "my-mac"
            )?.absoluteString,
            "ws://my-mac:3768/workspaces"
        )
        expectNoDifference(
            DesktopClient.sessionsWebSocketURL(
                serverAddress: "my-mac",
                workspaceID: "workspace-1"
            )?.absoluteString,
            "ws://my-mac:3768/workspaces/workspace-1/sessions"
        )
        expectNoDifference(
            DesktopClient.messagesWebSocketURL(
                serverAddress: "my-mac",
                workspaceID: "workspace-1",
                sessionID: "session-1",
                resumeAfterMessageID: "message / \u{e9}"
            )?.absoluteString,
            "ws://my-mac:3768/workspaces/workspace-1/sessions/session-1/messages"
                + "?after=message%20/%20%C3%A9"
        )
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(serverAddress: "my-mac:4000")?.absoluteString,
            "ws://my-mac:4000/workspaces"
        )
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(serverAddress: ""),
            nil
        )
    }

    @Test("WebSocket observations reject invalid desktop server addresses")
    func invalidWebSocketAddress() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "" }
            let stream = DesktopClient.observe([String].self) { _ in nil }
            var iterator = stream.makeAsyncIterator()

            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await iterator.next()
            }
        }
    }

    @Test("WebSocket tasks accept bounded full snapshots larger than Foundation's default")
    func webSocketMaximumMessageSize() throws {
        let task = URLSession.shared.webSocketTask(
            with: try #require(URL(string: "ws://example.com/items"))
        )

        _ = DesktopClient.WebSocketTaskClient(task)

        expectNoDifference(
            task.maximumMessageSize,
            DesktopClient.maximumWebSocketMessageSize
        )
    }

    @Test("WebSocket observations decode text and data frames")
    func webSocketFrameDecoding() async throws {
        struct TestError: Error { }

        let (frames, framesContinuation) = AsyncThrowingStream.makeStream(
            of: URLSessionWebSocketTask.Message.self,
            throwing: (any Error).self
        )
        let cancelCount = LockIsolated(0)
        let resumeCount = LockIsolated(0)
        let stream = DesktopClient.webSocketStream(
            [String].self,
            using: DesktopClient.WebSocketTaskClient {
                cancelCount.withValue { $0 += 1 }
            } receive: {
                for try await frame in frames {
                    return frame
                }
                throw CancellationError()
            } resume: {
                resumeCount.withValue { $0 += 1 }
            }
        )
        var iterator = stream.makeAsyncIterator()

        framesContinuation.yield(.string(#"["text"]"#))
        let text = try await iterator.next()
        expectNoDifference(text, ["text"])
        framesContinuation.yield(.data(Data(#"["data"]"#.utf8)))
        let data = try await iterator.next()
        expectNoDifference(data, ["data"])
        framesContinuation.finish(throwing: TestError())
        await #expect(throws: TestError.self) {
            try await iterator.next()
        }
        expectNoDifference(resumeCount.value, 1)
        expectNoDifference(cancelCount.value, 1)
    }

    @Test("WebSocket observations update their shared connection status")
    func webSocketConnectionStatus() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .disconnected }
            let (frames, framesContinuation) = AsyncThrowingStream.makeStream(
                of: URLSessionWebSocketTask.Message.self,
                throwing: (any Error).self
            )
            let stream = DesktopClient.webSocketStream(
                [String].self,
                using: DesktopClient.WebSocketTaskClient {
                } receive: {
                    for try await frame in frames {
                        return frame
                    }
                    throw CancellationError()
                } resume: {
                }
            )
            var iterator = stream.makeAsyncIterator()

            expectNoDifference(connectionStatus, .connecting)

            framesContinuation.yield(.string(#"["connected"]"#))
            _ = try await iterator.next()
            expectNoDifference(connectionStatus, .connected)

            framesContinuation.finish(throwing: URLError(.networkConnectionLost))
            await #expect(throws: URLError.self) {
                try await iterator.next()
            }
            expectNoDifference(connectionStatus, .disconnected)
        }
    }

    @Test("WebSocket observations retain only the newest pending snapshot")
    func webSocketSnapshotBuffering() async throws {
        struct TestError: Error { }

        let frames = LockIsolated<[URLSessionWebSocketTask.Message]>([
            .string(#"["first"]"#),
            .string(#"["second"]"#),
            .string(#"["third"]"#),
        ])
        let (framesConsumed, framesConsumedContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        let stream = DesktopClient.webSocketStream(
            [String].self,
            using: DesktopClient.WebSocketTaskClient {
            } receive: {
                guard let frame = (frames.withValue { frames in
                    frames.isEmpty ? nil : frames.removeFirst()
                }) else {
                    framesConsumedContinuation.yield()
                    throw TestError()
                }

                return frame
            } resume: {
            }
        )
        var framesConsumedIterator = framesConsumed.makeAsyncIterator()

        _ = await framesConsumedIterator.next()
        var iterator = stream.makeAsyncIterator()
        let latestSnapshot = try await iterator.next()
        expectNoDifference(latestSnapshot, ["third"])
        await #expect(throws: TestError.self) {
            try await iterator.next()
        }
    }

    @Test("Unbounded WebSocket observations retain every pending change")
    func webSocketChangeBuffering() async throws {
        struct TestError: Error { }

        let frames = LockIsolated<[URLSessionWebSocketTask.Message]>([
            .string(#"["first"]"#),
            .string(#"["second"]"#),
            .string(#"["third"]"#),
        ])
        let (framesConsumed, framesConsumedContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        let stream = DesktopClient.webSocketStream(
            [String].self,
            bufferingPolicy: .unbounded,
            using: DesktopClient.WebSocketTaskClient {
            } receive: {
                guard let frame = (frames.withValue { frames in
                    frames.isEmpty ? nil : frames.removeFirst()
                }) else {
                    framesConsumedContinuation.yield()
                    throw TestError()
                }

                return frame
            } resume: {
            }
        )
        var framesConsumedIterator = framesConsumed.makeAsyncIterator()

        _ = await framesConsumedIterator.next()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let third = try await iterator.next()
        expectNoDifference(first, ["first"])
        expectNoDifference(second, ["second"])
        expectNoDifference(third, ["third"])
        await #expect(throws: TestError.self) {
            try await iterator.next()
        }
    }

    @Test("Canceling an observation stops its WebSocket and receive task")
    func webSocketCancellation() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .connected }
            let (receiveStarted, receiveStartedContinuation) = AsyncStream.makeStream(of: Void.self)
            let (producerCancelled, producerCancelledContinuation) = AsyncStream.makeStream(
                of: Void.self
            )
            let receiveContinuation = LockIsolated<
                CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
            >(nil)
            let cancelCount = LockIsolated(0)
            let stream = DesktopClient.webSocketStream(
                [String].self,
                using: DesktopClient.WebSocketTaskClient {
                    cancelCount.withValue { $0 += 1 }
                    receiveContinuation.withValue {
                        $0?.resume(throwing: URLError(.networkConnectionLost))
                        $0 = nil
                    }
                } receive: {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            receiveContinuation.setValue(continuation)
                            receiveStartedContinuation.yield()
                        }
                    } onCancel: {
                        producerCancelledContinuation.yield()
                        producerCancelledContinuation.finish()
                    }
                } resume: {
                }
            )
            let observation = Task {
                for try await _ in stream { }
            }
            var receiveStartedIterator = receiveStarted.makeAsyncIterator()
            var producerCancelledIterator = producerCancelled.makeAsyncIterator()

            _ = await receiveStartedIterator.next()
            observation.cancel()
            _ = await producerCancelledIterator.next()
            _ = await observation.result

            expectNoDifference(cancelCount.value, 1)
            expectNoDifference(connectionStatus, .connected)
        }
    }

    @Test("Canceled WebSocket frames do not update connection status")
    func canceledWebSocketFrame() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .disconnected }
            let (receiveStarted, receiveStartedContinuation) = AsyncStream.makeStream(of: Void.self)
            let receiveContinuation = LockIsolated<
                CheckedContinuation<URLSessionWebSocketTask.Message, Never>?
            >(nil)
            let stream = DesktopClient.webSocketStream(
                [String].self,
                using: DesktopClient.WebSocketTaskClient {
                    receiveContinuation.withValue {
                        $0?.resume(returning: .string(#"["stale"]"#))
                        $0 = nil
                    }
                } receive: {
                    await withCheckedContinuation { continuation in
                        receiveContinuation.setValue(continuation)
                        receiveStartedContinuation.yield()
                    }
                } resume: {
                }
            )
            let observation = Task {
                for try await _ in stream { }
            }
            var receiveStartedIterator = receiveStarted.makeAsyncIterator()

            expectNoDifference(connectionStatus, .connecting)
            _ = await receiveStartedIterator.next()
            observation.cancel()
            _ = await observation.result

            expectNoDifference(connectionStatus, .connecting)
        }
    }
}

private struct MobileTranscriptBenchmarkWorkload: Decodable {
    let label: String
    let workspaceID: Workspace.ID
    let sessionID: Session.ID

    enum CodingKeys: String, CodingKey {
        case label
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
    }
}

private struct MobileTranscriptBenchmarkResult: Encodable {
    let label: String
    let iteration: Int
    let messageCount: Int
    let eventCount: Int
    let frameBytes: Int
    let firstEventMilliseconds: Double
    let decodeMilliseconds: Double
    let persistenceMilliseconds: Double
    let visibleQueryMilliseconds: Double
    let totalMilliseconds: Double
    let visibleMessageCount: Int

    enum CodingKeys: String, CodingKey {
        case label
        case iteration
        case messageCount = "message_count"
        case eventCount = "event_count"
        case frameBytes = "frame_bytes"
        case firstEventMilliseconds = "first_event_ms"
        case decodeMilliseconds = "decode_ms"
        case persistenceMilliseconds = "persistence_ms"
        case visibleQueryMilliseconds = "visible_query_ms"
        case totalMilliseconds = "total_ms"
        case visibleMessageCount = "visible_message_count"
    }
}

private func benchmarkMilliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}
