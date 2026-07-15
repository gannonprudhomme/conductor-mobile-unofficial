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

        async let firstChange: Void = nextChange(from: firstChanges)
        async let secondChange: Void = nextChange(from: secondChanges)
        dataVersion.withLock { $0 = 1 }

        _ = try await (firstChange, secondChange)
    }
}

private struct TimeoutError: Error { }

private func nextChange(
    from changes: DatabaseChangeObserver.Changes
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            var iterator = changes.makeAsyncIterator()
            _ = try #require(await iterator.next())
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw TimeoutError()
        }

        defer { group.cancelAll() }
        return try await group.next()!
    }
}
