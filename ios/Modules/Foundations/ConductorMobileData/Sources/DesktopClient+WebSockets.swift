//
//  DesktopClient+WebSockets.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Dependencies
import Foundation
import SharedConductorData

extension DesktopClient {
    static let workspacesWebSocketURL = webSocketBaseURL.appending(path: "workspaces")
    static let maximumWebSocketMessageSize = 64 * 1_024 * 1_024

    /// `/workspaces/{workspaceID}/sessions/{sessionID}/messages`
    static func messagesWebSocketURL(workspaceID: String, sessionID: String) -> URL {
        webSocketBaseURL
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
            .appending(path: sessionID)
            .appending(path: "messages")
    }

    /// `/workspaces/{workspaceID}/sessions
    static func sessionsWebSocketURL(workspaceID: String) -> URL {
        webSocketBaseURL
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
    }

    static func observe<Value: Decodable & Sendable>(
        _ type: Value.Type,
        at url: URL
    ) -> AsyncThrowingStream<Value, any Error> {
        @Dependency(\.urlSession) var urlSession

        return observe(
            type,
            using: WebSocketTaskClient(urlSession.webSocketTask(with: url))
        )
    }

    static func observe<Value: Decodable & Sendable>(
        _ type: Value.Type,
        using task: WebSocketTaskClient
    ) -> AsyncThrowingStream<Value, any Error> {
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
                        let data = try data(from: message)
                        let value = try JSONDecoder.conductor.decode(type, from: data)

                        if case .terminated = continuation.yield(value) {
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                producer.cancel()
            }
        }
    }

    // Really just a protocol/mock surfaace over `URLSessionWebSocketTask`
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
    static let webSocketBaseURL = URL(string: "ws://\(desktopServerAddress)")!

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
