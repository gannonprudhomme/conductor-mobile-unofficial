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
import Sharing
import Testing

struct DesktopClientWebSocketsTests {
    @Test("WebSocket resource URLs use the desktop service")
    func webSocketURLs() {
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(
                serverAddress: DesktopClient.defaultServerAddress
            ).absoluteString,
            "ws://192.168.0.32:3768/workspaces"
        )
        expectNoDifference(
            DesktopClient.sessionsWebSocketURL(
                serverAddress: DesktopClient.defaultServerAddress,
                workspaceID: "workspace-1"
            ).absoluteString,
            "ws://192.168.0.32:3768/workspaces/workspace-1/sessions"
        )
        expectNoDifference(
            DesktopClient.messagesWebSocketURL(
                serverAddress: DesktopClient.defaultServerAddress,
                workspaceID: "workspace-1",
                sessionID: "session-1"
            ).absoluteString,
            "ws://192.168.0.32:3768/workspaces/workspace-1/sessions/session-1/messages"
        )
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(serverAddress: "my-mac").absoluteString,
            "ws://my-mac:3768/workspaces"
        )
        expectNoDifference(
            DesktopClient.workspacesWebSocketURL(serverAddress: "my-mac:4000").absoluteString,
            "ws://my-mac:4000/workspaces"
        )
    }

    @Test("WebSocket tasks accept bounded full snapshots larger than Foundation's default")
    func webSocketMaximumMessageSize() {
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://example.com/items")!
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
