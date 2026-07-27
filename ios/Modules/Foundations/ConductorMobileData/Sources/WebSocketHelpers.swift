//
//  WebSocketHelpers.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/13/26.
//

import Dependencies

public enum WebSocketHelpers {
    /// Observes a WebSocket immediately and reconnects one second after it completes or fails.
    ///
    /// Each frame is delivered to `onValue`. If processing a frame throws, that error is
    /// delivered to `onFailure`, just like a transport error, before reconnection.
    ///
    /// The sleep is retry backoff between connections, not message polling. It prevents a stopped
    /// or unreachable desktop service from causing a tight reconnect loop.
    public static func observe<Value: Sendable>(
        retrying makeStream: () async throws -> AsyncThrowingStream<Value, any Error>,
        onValue: (Value) async throws -> Void,
        onFailure: (any Error) async -> Void
    ) async {
        @Dependency(\.continuousClock) var clock

        while !Task.isCancelled {
            do {
                for try await value in try await makeStream() {
                    try await onValue(value)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await onFailure(error)
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                // Wait before retrying
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}
