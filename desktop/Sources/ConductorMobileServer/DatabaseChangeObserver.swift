//
//  DatabaseChangeObserver.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/15/26.
//

import SQLiteData

/// Polls SQLite's connection-local `data_version` and total change count, then broadcasts invalidations
/// to WebSocket subscribers using one shared polling task.
///
/// This is an actor because sockets subscribe and disconnect concurrently while the polling task
/// reads and mutates the same continuation collection, version, and task lifecycle state. Actor
/// isolation serializes those operations and guarantees that at most one polling task is active.
actor DatabaseChangeObserver {
    typealias Generation = UInt64
    typealias Changes = AsyncThrowingStream<Generation, any Error>

    private let broadcastInterval: Duration
    private let clock = ContinuousClock()
    private let pollInterval: Duration
    private let readDatabaseVersion: @Sendable () throws -> DatabaseVersion
    private var continuations: [Int: Changes.Continuation] = [:]
    /// The last observed database version, established when the first subscriber arrives.
    private var databaseVersion: DatabaseVersion?
    /// Identifies the database state that each invalidation belongs to so subscribers loading the
    /// same resource can share one read without reusing a snapshot from an older invalidation.
    private var generation: Generation = 0
    /// Commits observed during the broadcast cooldown collapse into one trailing invalidation.
    private var hasPendingChange = false
    private var nextBroadcastInstant: ContinuousClock.Instant?
    private var nextSubscriberID = 0
    /// Exists only while there is at least one subscriber.
    private var pollingTask: Task<Void, Never>?

    init(
        database: DatabaseQueue,
        pollInterval: Duration = .milliseconds(25),
        broadcastInterval: Duration = .milliseconds(200)
    ) {
        self.init(
            pollInterval: pollInterval,
            broadcastInterval: broadcastInterval,
            readDatabaseVersion: {
                // These scalar reads do not need a transactionally consistent snapshot. Avoiding
                // the transaction that `read` creates keeps high-frequency polling inexpensive.
                try database.unsafeRead { database in
                    DatabaseVersion(
                        // `data_version` changes when another connection commits.
                        dataVersion: try #sql("PRAGMA data_version", as: Int.self)
                            .fetchOne(database) ?? 0,
                        // `data_version` deliberately ignores this connection's own commits. Pair
                        // it with the cumulative count so server-side fallback writes also
                        // invalidate subscribers. Without this value, those writes could leave
                        // sockets stale.
                        totalChangesCount: database.totalChangesCount
                    )
                }
            }
        )
    }

    init(
        pollInterval: Duration,
        broadcastInterval: Duration = .milliseconds(200),
        readDataVersion: @escaping @Sendable () throws -> Int
    ) {
        self.init(
            pollInterval: pollInterval,
            broadcastInterval: broadcastInterval,
            readDatabaseVersion: {
                DatabaseVersion(
                    dataVersion: try readDataVersion(),
                    totalChangesCount: 0
                )
            }
        )
    }

    private init(
        pollInterval: Duration,
        broadcastInterval: Duration,
        readDatabaseVersion: @escaping @Sendable () throws -> DatabaseVersion
    ) {
        self.broadcastInterval = broadcastInterval
        self.pollInterval = pollInterval
        self.readDatabaseVersion = readDatabaseVersion
    }

    func changes() throws -> Changes {
        // Establish a baseline once per polling lifetime so existing data is not reported as a
        // new change and all subscribers compare against the same version.
        if pollingTask == nil {
            databaseVersion = try readDatabaseVersion()
            hasPendingChange = false
            nextBroadcastInstant = nil
        }

        let subscriberID = nextSubscriberID
        nextSubscriberID += 1

        // A change is only an instruction to reload current state. If a subscriber is busy,
        // collapsing multiple pending invalidations into the newest one loses no information.
        let (stream, continuation) = Changes.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[subscriberID] = continuation
        continuation.yield(generation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(for: subscriberID)
            }
        }
        startPollingIfNeeded()
        return stream
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil, !continuations.isEmpty else {
            return
        }

        pollingTask = Task { [weak self] in
            await self?.poll()
        }
    }

    private func poll() async {
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: pollInterval)
                let nextDatabaseVersion = try readDatabaseVersion()
                if nextDatabaseVersion != databaseVersion {
                    databaseVersion = nextDatabaseVersion
                    hasPendingChange = true
                }

                guard hasPendingChange else {
                    continue
                }

                let now = clock.now
                if let nextBroadcastInstant,
                   now < nextBroadcastInstant {
                    continue
                }

                generation &+= 1
                for continuation in continuations.values {
                    continuation.yield(generation)
                }
                hasPendingChange = false
                nextBroadcastInstant = now.advanced(by: broadcastInterval)
            }
        } catch is CancellationError {
        } catch {
            for continuation in continuations.values {
                continuation.finish(throwing: error)
            }
            continuations.removeAll()
        }

        pollingTask = nil
        if continuations.isEmpty {
            databaseVersion = nil
            hasPendingChange = false
            nextBroadcastInstant = nil
        }
        startPollingIfNeeded()
    }

    private struct DatabaseVersion: Equatable {
        let dataVersion: Int
        /// Catches writes made through the same connection that reads `dataVersion`.
        let totalChangesCount: Int
    }

    private func removeContinuation(for subscriberID: Int) {
        continuations[subscriberID] = nil
        if continuations.isEmpty {
            pollingTask?.cancel()
        }
    }
}
