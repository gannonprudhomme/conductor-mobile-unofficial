//
//  DatabaseSnapshotCache.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/29/26.
//

/// Coalesces resource loads triggered by database invalidations.
///
/// Every connected device receives its own WebSocket message, but devices observing the same
/// resource should not each reread and decode the same SQLite rows. A completed value remains
/// available while that resource has subscribers so slightly staggered devices still share it.
/// The value is evicted as soon as the final subscriber disconnects.
actor DatabaseSnapshotCache<Key: Hashable & Sendable, Snapshot: Equatable & Sendable> {
    struct Value: Equatable, Sendable {
        let revision: UInt64
        let snapshot: Snapshot
    }

    private struct Completed: Sendable {
        let generation: DatabaseChangeObserver.Generation
        let revision: UInt64
        let snapshot: Snapshot
    }

    private struct Entry: Sendable {
        var completed: Completed?
        var loads: [
            DatabaseChangeObserver.Generation: Task<Snapshot, any Error>
        ] = [:]
        var subscriberCount = 0
    }

    private var entries: [Key: Entry] = [:]

    func addSubscriber(for key: Key) {
        var entry = entries[key, default: Entry()]
        entry.subscriberCount += 1
        entries[key] = entry
    }

    func removeSubscriber(for key: Key) {
        guard var entry = entries[key] else {
            return
        }

        entry.subscriberCount -= 1
        if entry.subscriberCount == 0 {
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }

    func withSubscriber<Result: Sendable>(
        for key: Key,
        operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        addSubscriber(for: key)
        do {
            let result = try await operation()
            removeSubscriber(for: key)
            return result
        } catch {
            removeSubscriber(for: key)
            throw error
        }
    }

    func value(
        for key: Key,
        generation: DatabaseChangeObserver.Generation,
        load loadSnapshot: @escaping @Sendable () async throws -> Snapshot
    ) async throws -> Value {
        if let completed = entries[key]?.completed,
           completed.generation >= generation {
            return Value(
                revision: completed.revision,
                snapshot: completed.snapshot
            )
        }
        if let existingLoad = entries[key]?.loads[generation] {
            let snapshot = try await existingLoad.value
            return completeLoad(
                for: key,
                generation: generation,
                snapshot: snapshot
            )
        }

        let task = Task {
            try await loadSnapshot()
        }
        var entry = entries[key, default: Entry()]
        entry.loads[generation] = task
        entries[key] = entry

        do {
            let snapshot = try await task.value
            let value = completeLoad(
                for: key,
                generation: generation,
                snapshot: snapshot
            )
            return value
        } catch {
            removeLoad(for: key, generation: generation)
            throw error
        }
    }

    private func removeLoad(
        for key: Key,
        generation: DatabaseChangeObserver.Generation
    ) {
        guard var entry = entries[key] else {
            return
        }
        entry.loads[generation] = nil
        entries[key] = entry
    }

    private func completeLoad(
        for key: Key,
        generation: DatabaseChangeObserver.Generation,
        snapshot: Snapshot
    ) -> Value {
        guard var entry = entries[key] else {
            return Value(revision: 0, snapshot: snapshot)
        }

        entry.loads[generation] = nil
        let completed: Completed
        if let existing = entry.completed,
           existing.generation >= generation {
            completed = existing
        } else if let existing = entry.completed,
                  existing.snapshot == snapshot {
            completed = Completed(
                generation: generation,
                revision: existing.revision,
                snapshot: existing.snapshot
            )
        } else {
            completed = Completed(
                generation: generation,
                revision: (entry.completed?.revision ?? 0) &+ 1,
                snapshot: snapshot
            )
        }
        entry.completed = completed
        entries[key] = entry
        return Value(
            revision: completed.revision,
            snapshot: completed.snapshot
        )
    }
}
