//
//  DatabaseChangeObserver.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/15/26.
//

import SQLiteData

/// Polls SQLite's connection-local `data_version` and change count, then broadcasts invalidations
/// to WebSocket subscribers using one shared polling task.
///
/// This is an actor because sockets subscribe and disconnect concurrently while the polling task
/// reads and mutates the same continuation collection, version, and task lifecycle state. Actor
/// isolation serializes those operations and guarantees that at most one polling task is active.
actor DatabaseChangeObserver {
    typealias Changes = AsyncThrowingStream<Void, any Error>

    private let pollInterval: Duration
    private let readDatabaseVersion: @Sendable () throws -> DatabaseVersion
    private var continuations: [Int: Changes.Continuation] = [:]
    /// The last observed database version, established when the first subscriber arrives.
    private var databaseVersion: DatabaseVersion?
    private var nextSubscriberID = 0
    /// Exists only while there is at least one subscriber.
    private var pollingTask: Task<Void, Never>?

    init(
        database: DatabaseQueue,
        pollInterval: Duration = .milliseconds(3)
    ) {
        self.init(pollInterval: pollInterval, readDatabaseVersion: {
            // These scalar reads do not need a transactionally consistent snapshot. Avoiding the
            // transaction that `read` creates keeps high-frequency polling inexpensive.
            try database.unsafeRead { database in
                DatabaseVersion(
                    dataVersion: try #sql("PRAGMA data_version", as: Int.self)
                        .fetchOne(database) ?? 0,
                    totalChangesCount: database.totalChangesCount
                )
            }
        })
    }

    init(
        pollInterval: Duration,
        readDataVersion: @escaping @Sendable () throws -> Int
    ) {
        self.init(pollInterval: pollInterval, readDatabaseVersion: {
            DatabaseVersion(
                dataVersion: try readDataVersion(),
                totalChangesCount: 0
            )
        })
    }

    private init(
        pollInterval: Duration,
        readDatabaseVersion: @escaping @Sendable () throws -> DatabaseVersion
    ) {
        self.pollInterval = pollInterval
        self.readDatabaseVersion = readDatabaseVersion
    }

    func changes() throws -> Changes {
        // Establish a baseline once per polling lifetime so existing data is not reported as a
        // new change and all subscribers compare against the same version.
        if pollingTask == nil {
            databaseVersion = try readDatabaseVersion()
        }

        let subscriberID = nextSubscriberID
        nextSubscriberID += 1

        // A change is only an instruction to reload current state. If a subscriber is busy,
        // collapsing multiple pending invalidations into the newest one loses no information.
        let (stream, continuation) = Changes.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[subscriberID] = continuation
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
                guard nextDatabaseVersion != databaseVersion else {
                    continue
                }

                databaseVersion = nextDatabaseVersion
                for continuation in continuations.values {
                    continuation.yield(())
                }
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
        }
        startPollingIfNeeded()
    }

    private struct DatabaseVersion: Equatable {
        let dataVersion: Int
        let totalChangesCount: Int
    }

    private func removeContinuation(for subscriberID: Int) {
        continuations[subscriberID] = nil
        if continuations.isEmpty {
            pollingTask?.cancel()
        }
    }
}
