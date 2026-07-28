//
//  StreamObservationTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Dependencies
import Foundation
@testable import ConductorMobileData
import Testing

@MainActor
struct StreamObservationTests {
    @Test("A received value resets retry backoff")
    func successfulValueResetsBackoff() async {
        let clock = TestClock()
        let connectionCount = LockIsolated(0)
        let receivedValues = LockIsolated<[Int]>([])
        let failureCount = LockIsolated(0)
        let finalContinuation = LockIsolated<
            AsyncThrowingStream<Int, any Error>.Continuation?
        >(nil)

        let task = withDependencies {
            $0.continuousClock = clock
        } operation: {
            Task {
                await StreamObservation.observe(
                    retrying: {
                        let connection = connectionCount.withValue {
                            $0 += 1
                            return $0
                        }
                        let (stream, continuation) = AsyncThrowingStream<
                            Int,
                            any Error
                        >.makeStream()
                        switch connection {
                        case 1:
                            continuation.finish(
                                throwing: ObservationError.failed
                            )

                        case 2:
                            continuation.yield(42)
                            continuation.finish(
                                throwing: ObservationError.failed
                            )

                        default:
                            finalContinuation.setValue(continuation)
                        }
                        return stream
                    },
                    retryDelays: [
                        .seconds(1),
                        .seconds(2),
                        .seconds(4),
                    ],
                    onValue: { value in
                        receivedValues.withValue { $0.append(value) }
                    },
                    onFailure: { _ in
                        failureCount.withValue { $0 += 1 }
                    }
                )
            }
        }

        await waitUntil { connectionCount.value == 1 }
        await clock.advance(by: .milliseconds(999))
        #expect(connectionCount.value == 1)

        await clock.advance(by: .milliseconds(1))
        await waitUntil { connectionCount.value == 2 }
        #expect(receivedValues.value == [42])
        #expect(failureCount.value == 2)

        await clock.advance(by: .milliseconds(999))
        #expect(connectionCount.value == 2)
        await clock.advance(by: .milliseconds(1))
        await waitUntil { connectionCount.value == 3 }

        task.cancel()
        finalContinuation.value?.finish()
        await task.value
    }

    @Test("A non-retryable failure stops observation")
    func nonRetryableFailureStopsObservation() async {
        let connectionCount = LockIsolated(0)
        let failureCount = LockIsolated(0)

        await StreamObservation.observe(
            retrying: {
                connectionCount.withValue { $0 += 1 }
                let (stream, continuation) = AsyncThrowingStream<
                    Int,
                    any Error
                >.makeStream()
                continuation.finish(throwing: ObservationError.failed)
                return stream
            },
            retryDelays: [.seconds(1)],
            shouldRetry: { _ in false },
            onValue: { _ in },
            onFailure: { _ in
                failureCount.withValue { $0 += 1 }
            }
        )

        #expect(connectionCount.value == 1)
        #expect(failureCount.value == 1)
    }
}

private enum ObservationError: Error {
    case failed
}

@MainActor
private func waitUntil(
    _ condition: @escaping () -> Bool
) async {
    for _ in 0..<1_000 {
        guard !condition() else {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for an asynchronous test condition.")
}
