//
//  DatabaseSnapshotCacheTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

import CustomDump
import Dependencies
import Testing

@testable import ConductorMobileServer

struct DatabaseSnapshotCacheTests {
    @Test("Concurrent loads for one resource and generation share work")
    func coalescesConcurrentLoads() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        async let first = cache.value(for: "resource", generation: 1) {
            try await Task.sleep(for: .milliseconds(50))
            return loadCount.withValue {
                $0 += 1
                return $0
            }
        }
        async let second = cache.value(for: "resource", generation: 1) {
            try await Task.sleep(for: .milliseconds(50))
            return loadCount.withValue {
                $0 += 1
                return $0
            }
        }

        let values = try await (first, second)
        expectNoDifference(values.0.snapshot, 1)
        expectNoDifference(values.1.snapshot, 1)
        expectNoDifference(values.0.revision, values.1.revision)
        expectNoDifference(loadCount.value, 1)
    }

    @Test("Sequential loads reuse the completed value while subscribed")
    func reusesCompletedLoad() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        let first = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue {
                $0 += 1
                return $0
            }
        }
        let second = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue {
                $0 += 1
                return $0
            }
        }

        expectNoDifference(first.snapshot, 1)
        expectNoDifference(second.snapshot, 1)
        expectNoDifference(first.revision, second.revision)
        expectNoDifference(loadCount.value, 1)
    }

    @Test("A failed load is removed so the same generation can retry")
    func retriesFailedLoad() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        await #expect(throws: LoadError.expected) {
            try await cache.value(for: "resource", generation: 1) {
                loadCount.withValue { $0 += 1 }
                throw LoadError.expected
            }
        }
        let recovered = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue { $0 += 1 }
            return 42
        }

        expectNoDifference(recovered.snapshot, 42)
        expectNoDifference(loadCount.value, 2)
    }

    @Test("A newer completed generation satisfies an older invalidation")
    func newerGenerationSatisfiesOlderLoad() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        let newer = try await cache.value(for: "resource", generation: 2) {
            loadCount.withValue {
                $0 += 1
                return 2
            }
        }
        let older = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue {
                $0 += 1
                return 1
            }
        }

        expectNoDifference(newer.snapshot, 2)
        expectNoDifference(older.snapshot, 2)
        expectNoDifference(newer.revision, older.revision)
        expectNoDifference(loadCount.value, 1)
    }

    @Test("Only a changed snapshot advances the resource revision")
    func advancesRevisionForChangedSnapshot() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        await cache.addSubscriber(for: "resource")

        let first = try await cache.value(for: "resource", generation: 1) {
            1
        }
        let unchanged = try await cache.value(for: "resource", generation: 2) {
            1
        }
        let changed = try await cache.value(for: "resource", generation: 3) {
            2
        }

        expectNoDifference(first.snapshot, 1)
        expectNoDifference(unchanged.snapshot, 1)
        expectNoDifference(first.revision, unchanged.revision)
        expectNoDifference(changed.snapshot, 2)
        #expect(changed.revision != unchanged.revision)
    }

    @Test("A newer database generation starts a new load")
    func separatesGenerations() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        async let first = cache.value(for: "resource", generation: 1) {
            try await Task.sleep(for: .milliseconds(50))
            return loadCount.withValue {
                $0 += 1
                return $0
            }
        }
        async let second = cache.value(for: "resource", generation: 2) {
            try await Task.sleep(for: .milliseconds(50))
            return loadCount.withValue {
                $0 += 1
                return $0
            }
        }

        _ = try await (first, second)
        expectNoDifference(loadCount.value, 2)
    }

    @Test("The final subscriber evicts the completed value")
    func evictsCompletedLoad() async throws {
        let cache = DatabaseSnapshotCache<String, Int>()
        let loadCount = LockIsolated(0)
        await cache.addSubscriber(for: "resource")

        _ = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue {
                $0 += 1
                return $0
            }
        }
        await cache.removeSubscriber(for: "resource")
        await cache.addSubscriber(for: "resource")
        _ = try await cache.value(for: "resource", generation: 1) {
            loadCount.withValue {
                $0 += 1
                return $0
            }
        }

        expectNoDifference(loadCount.value, 2)
    }
}

private enum LoadError: Error {
    case expected
}
