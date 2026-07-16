//
//  WorkspaceUIHookBrokerTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookBrokerTests {
    @Test("SSE frames escape mutation values without command IDs")
    func escapedFrame() async throws {
        let broker = WorkspaceUIHookBroker()
        let connection = await broker.connect()
        var events = connection.events.makeAsyncIterator()

        let path = try await broker.dispatch(
            .status("in-\nprogress"),
            workspaceID: "workspace-\"2"
        ) {}
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-\\\"2\",\"status\":\"in-\\nprogress\"}\n\n"
        )
        #expect(path == .hook)
    }

    @Test("Fallback holds the global slot without waiting for persistence")
    func disconnectedFallback() async throws {
        let broker = WorkspaceUIHookBroker()
        let (fallbackStarted, fallbackStartedContinuation) = AsyncStream<Void>.makeStream()
        var fallbackStarts = fallbackStarted.makeAsyncIterator()
        let (fallbackGate, fallbackGateContinuation) = AsyncStream<Void>.makeStream()

        let fallback = Task {
            try await broker.dispatch(.pinned(isPinned: true), workspaceID: "workspace-1") {
                fallbackStartedContinuation.yield(())
                for await _ in fallbackGate {}
            } waitForPersistence: {
                throw PersistenceError.unexpectedWait
            }
        }
        _ = await fallbackStarts.next()

        await #expect(throws: WorkspaceUIHookBroker.DispatchError.mutationInFlight) {
            try await broker.dispatch(.unread(isUnread: true), workspaceID: "workspace-2") {}
        }

        fallbackGateContinuation.finish()
        #expect(try await fallback.value == .sqliteFallback)
    }

    @Test("One global slot is held until authoritative persistence completes")
    func globalSerialization() async throws {
        let broker = WorkspaceUIHookBroker()
        let connection = await broker.connect()
        var events = connection.events.makeAsyncIterator()
        let (persistence, persistenceContinuation) = AsyncStream<Void>.makeStream()

        let first = Task {
            try await broker.dispatch(.pinned(isPinned: true), workspaceID: "workspace-1") {
                for await _ in persistence {
                    return
                }
            }
        }
        _ = await events.next()

        await #expect(throws: WorkspaceUIHookBroker.DispatchError.mutationInFlight) {
            try await broker.dispatch(.unread(isUnread: true), workspaceID: "workspace-2") {}
        }

        persistenceContinuation.finish()
        #expect(try await first.value == .hook)

        #expect(
            try await broker.dispatch(
                .unread(isUnread: true),
                workspaceID: "workspace-2"
            ) {} == .hook
        )
    }

    @Test("Connection replacement terminates the old stream and ignores stale disconnects")
    func replacement() async throws {
        let broker = WorkspaceUIHookBroker()
        let firstConnection = await broker.connect()
        var firstEvents = firstConnection.events.makeAsyncIterator()
        let secondConnection = await broker.connect()
        var secondEvents = secondConnection.events.makeAsyncIterator()
        #expect(await firstEvents.next() == nil)

        #expect(
            try await broker.dispatch(
                .unread(isUnread: true),
                workspaceID: "workspace-1"
            ) {} == .hook
        )
        #expect(await secondEvents.next() != nil)

        await broker.disconnect(connectionID: firstConnection.id)
        #expect(await broker.isConnected)
        await broker.disconnect(connectionID: secondConnection.id)
        #expect(await broker.isConnected == false)
    }
}

private enum PersistenceError: Error, Equatable {
    case unexpectedWait
}
