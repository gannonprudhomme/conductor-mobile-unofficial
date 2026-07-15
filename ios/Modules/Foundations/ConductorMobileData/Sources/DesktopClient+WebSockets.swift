//
//  DesktopClient+WebSockets.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/13/26.
//

import AsyncAlgorithms
import Dependencies
import Foundation
import Observation
import SharedConductorData
import Sharing

extension DesktopClient {
    static func workspacesWebSocketURL(serverAddress: String) -> URL {
        serverURL(scheme: "ws", address: serverAddress)!
            .appending(path: "workspaces")
    }

    static let maximumWebSocketMessageSize = 64 * 1_024 * 1_024

    /// `/workspaces/{workspaceID}/sessions/{sessionID}/messages`
    static func messagesWebSocketURL(
        serverAddress: String,
        workspaceID: String,
        sessionID: String
    ) -> URL {
        serverURL(scheme: "ws", address: serverAddress)!
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
            .appending(path: sessionID)
            .appending(path: "messages")
    }

    /// `/workspaces/{workspaceID}/sessions`
    static func sessionsWebSocketURL(serverAddress: String, workspaceID: String) -> URL {
        serverURL(scheme: "ws", address: serverAddress)!
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
    }

    /// Automatically reacts to changes in the server address.
    ///
    /// `bufferingPolicy` controls which values wait when the producer is faster than the
    /// consumer. State snapshots keep only the newest pending value by default; callers whose
    /// values are incremental can opt into an unbounded buffer so no update is discarded.
    static func observe<Value: Decodable & Sendable>(
        _ type: Value.Type,
        bufferingPolicy: AsyncThrowingStream<
            Value,
            any Error
        >.Continuation.BufferingPolicy = .bufferingNewest(1),
        at makeURL: @escaping @Sendable (String) -> URL
    ) -> AsyncThrowingStream<Value, any Error> {
        @Dependency(\.urlSession) var urlSession
        @Shared(.desktopServerAddress) var desktopServerAddress

        // Capture the shared value's projection so `Observations` can track the current address
        // and every persisted change without making feature consumers manage reconnections.
        let sharedServerAddress = $desktopServerAddress

        let values = Observations { sharedServerAddress.wrappedValue }
            .removeDuplicates()
            // When the address actually changes, `flatMapLatest` cancels the old WebSocket stream
            // and subscribes to a new one.
            .flatMapLatest { serverAddress in
                webSocketStream(
                    type,
                    bufferingPolicy: bufferingPolicy,
                    using: WebSocketTaskClient(
                        urlSession.webSocketTask(with: makeURL(serverAddress))
                    )
                )
            }

        // The operators above return an opaque `some AsyncSequence`, while `DesktopClient`'s
        // dependency endpoints promise a concrete `AsyncThrowingStream`. This outer stream is
        // the type-erasure bridge between them. It also forwards consumer cancellation to the
        // task driving the operator chain.
        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let producer = Task {
                do {
                    for try await value in values {
                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }

                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    // Only non-private for tests
    static func webSocketStream<Value: Decodable & Sendable>(
        _ type: Value.Type,
        bufferingPolicy: AsyncThrowingStream<
            Value,
            any Error
        >.Continuation.BufferingPolicy = .bufferingNewest(1),
        using task: WebSocketTaskClient
    ) -> AsyncThrowingStream<Value, any Error> {
        @Shared(.desktopConnectionStatus) var connectionStatus
        let sharedConnectionStatus = $connectionStatus

        sharedConnectionStatus.withLock {
            if $0 != .connected {
                $0 = .connecting
            }
        }

        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            task.resume()
            let producer = Task {
                // A producer can fail before its termination handler is installed. In that case,
                // `finish` does not invoke the handler later, so the producer closes the socket.
                defer {
                    if !Task.isCancelled {
                        task.cancel()
                    }
                }

                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard !Task.isCancelled else {
                            return
                        }

                        sharedConnectionStatus.withLock { $0 = .connected }
                        let data = try data(from: message)
                        let value = try JSONDecoder.conductor.decode(type, from: data)

                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }

                    if DesktopClientError.isConnectionFailure(error) {
                        sharedConnectionStatus.withLock { $0 = .disconnected }
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
                task.cancel()
            }
        }
    }

    // Really just a protocol/mock surface over `URLSessionWebSocketTask`
    struct WebSocketTaskClient: Sendable {
        fileprivate var cancel: @Sendable () -> Void
        fileprivate var receive: @Sendable () async throws -> URLSessionWebSocketTask.Message
        fileprivate var resume: @Sendable () -> Void

        init(_ task: URLSessionWebSocketTask) {
            task.maximumMessageSize = DesktopClient.maximumWebSocketMessageSize
            self.cancel = {
                task.cancel(with: .goingAway, reason: nil)
            }
            self.receive = {
                try await task.receive()
            }
            self.resume = {
                task.resume()
            }
        }

        init( // only exists for tests
            cancel: @escaping @Sendable () -> Void,
            receive: @escaping @Sendable () async throws -> URLSessionWebSocketTask.Message,
            resume: @escaping @Sendable () -> Void
        ) {
            self.cancel = cancel
            self.receive = receive
            self.resume = resume
        }
    }
}

fileprivate extension DesktopClient {
    static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case let .data(data):
            data

        case let .string(string):
            Data(string.utf8)

        @unknown default:
            throw DesktopClientError.invalidResponse
        }
    }
}
