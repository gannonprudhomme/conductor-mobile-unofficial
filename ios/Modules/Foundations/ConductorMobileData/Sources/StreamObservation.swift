//
//  StreamObservation.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Dependencies
import Foundation

public enum StreamObservation {
    /// Observes a stream immediately and reconnects after it completes or fails.
    ///
    /// A value resets retry backoff. If processing a value throws, the processing error follows
    /// the same failure and retry path as a transport error.
    public static func observe<Value: Sendable>(
        retrying makeStream: () -> AsyncThrowingStream<Value, any Error>,
        retryDelays: [Duration] = [.seconds(1)],
        shouldRetry: (any Error) -> Bool = { _ in true },
        onValue: (Value) async throws -> Void,
        onFailure: (any Error) async -> Void
    ) async {
        @Dependency(\.continuousClock) var clock

        precondition(!retryDelays.isEmpty, "Stream observation requires a retry delay.")
        var retryIndex = 0

        while !Task.isCancelled {
            do {
                for try await value in makeStream() {
                    try await onValue(value)
                    retryIndex = 0
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await onFailure(error)
                guard shouldRetry(error) else {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
                retryIndex = min(retryIndex + 1, retryDelays.count - 1)
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }
}
