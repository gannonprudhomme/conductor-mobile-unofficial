//
//  DatabaseChangeObserverTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/15/26.
//

import CustomDump
import Synchronization
import Testing

@testable import ConductorMobileServer

struct DatabaseChangeObserverTests {
    @Test("Subscribers share one polling task")
    func sharesPollingTask() async throws {
        let reads = Mutex(0)
        let observer = DatabaseChangeObserver(pollInterval: .seconds(60)) {
            reads.withLock {
                $0 += 1
                return $0
            }
        }
        let firstChanges = try await observer.changes()
        let secondChanges = try await observer.changes()

        try await Task.sleep(for: .milliseconds(20))

        expectNoDifference(reads.withLock { $0 }, 1)
        _ = (firstChanges, secondChanges)
    }

    @Test("Database changes are broadcast to every subscriber")
    func broadcastsChanges() async throws {
        let dataVersion = Mutex(0)
        let observer = DatabaseChangeObserver(pollInterval: .milliseconds(1)) {
            dataVersion.withLock { $0 }
        }
        let firstChanges = try await observer.changes()
        let secondChanges = try await observer.changes()

        async let firstChange = nextChange(from: firstChanges)
        async let secondChange = nextChange(from: secondChanges)
        dataVersion.withLock { $0 = 1 }

        let generations = try await (firstChange, secondChange)
        expectNoDifference(generations.0, 1)
        expectNoDifference(generations.1, 1)
    }

    @Test("Changes during the cooldown collapse into one trailing invalidation")
    func rateLimitsChanges() async throws {
        let dataVersion = Mutex(0)
        let observer = DatabaseChangeObserver(
            pollInterval: .milliseconds(1),
            broadcastInterval: .milliseconds(100)
        ) {
            dataVersion.withLock { $0 }
        }
        let changes = try await observer.changes()
        var iterator = changes.makeAsyncIterator()
        let initialGeneration = try await iterator.next()
        expectNoDifference(try #require(initialGeneration), 0)

        dataVersion.withLock { $0 = 1 }
        let firstGeneration = try await iterator.next()
        expectNoDifference(try #require(firstGeneration), 1)

        let clock = ContinuousClock()
        let start = clock.now
        dataVersion.withLock { $0 = 2 }
        try await Task.sleep(for: .milliseconds(10))
        dataVersion.withLock { $0 = 3 }

        let secondGeneration = try await iterator.next()
        expectNoDifference(try #require(secondGeneration), 2)
        #expect(start.duration(to: clock.now) >= .milliseconds(50))
    }
}

private struct TimeoutError: Error { }

private func nextChange(
    from changes: DatabaseChangeObserver.Changes
) async throws -> DatabaseChangeObserver.Generation {
    try await withThrowingTaskGroup(
        of: DatabaseChangeObserver.Generation.self
    ) { group in
        group.addTask {
            var iterator = changes.makeAsyncIterator()
            _ = try #require(await iterator.next())
            return try #require(await iterator.next())
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw TimeoutError()
        }

        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
