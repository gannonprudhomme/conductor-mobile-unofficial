//
//  WorkspaceUIHookTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookTests {
    @Test("SSE frames escape mutation values without command IDs")
    func escapedFrame() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()

        let path = try await uiHook.dispatch(
            mutation: .status("in-\nprogress"),
            workspaceID: "workspace-\"2",
            fallback: {},
            waitUntilChangeAvailableInDatabase: {}
        )
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-\\\"2\",\"status\":\"in-\\nprogress\"}\n\n"
        )
        #expect(path == .hook)

        let didDispatchModel = try await uiHook.updateSessionModel(
            sessionID: "session-\"3",
            model: .gpt_5_6_terra,
            waitUntilChangeAvailableInDatabase: {}
        )
        #expect(
            await events.next()
                == "data: {\"sessionId\":\"session-\\\"3\",\"model\":\"gpt-5.6-terra\"}\n\n"
        )
        #expect(didDispatchModel)
    }

    @Test("Fallback holds the global slot without waiting for persistence")
    func disconnectedFallback() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let (fallbackStarted, fallbackStartedContinuation) = AsyncStream<Void>.makeStream()
        var fallbackStarts = fallbackStarted.makeAsyncIterator()
        let (fallbackGate, fallbackGateContinuation) = AsyncStream<Void>.makeStream()

        let fallback = Task {
            try await uiHook.dispatch(
                mutation: .pinned(isPinned: true),
                workspaceID: "workspace-1",
                fallback: {
                    fallbackStartedContinuation.yield(())
                    for await _ in fallbackGate {}
                },
                waitUntilChangeAvailableInDatabase: {
                    throw PersistenceError.unexpectedWait
                }
            )
        }
        _ = await fallbackStarts.next()

        await #expect(throws: WorkspaceUIHook.DispatchError.mutationInFlight) {
            try await uiHook.dispatch(
                mutation: .unread(isUnread: true),
                workspaceID: "workspace-2",
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            )
        }

        fallbackGateContinuation.finish()
        #expect(try await fallback.value == .sqliteFallback)
    }

    @Test("One global slot is held until authoritative persistence completes")
    func globalSerialization() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let (persistence, persistenceContinuation) = AsyncStream<Void>.makeStream()

        let first = Task {
            try await uiHook.dispatch(
                mutation: .pinned(isPinned: true),
                workspaceID: "workspace-1",
                fallback: {},
                waitUntilChangeAvailableInDatabase: {
                    for await _ in persistence {
                        return
                    }
                }
            )
        }
        _ = await events.next()

        await #expect(throws: WorkspaceUIHook.DispatchError.mutationInFlight) {
            try await uiHook.dispatch(
                mutation: .unread(isUnread: true),
                workspaceID: "workspace-2",
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            )
        }

        persistenceContinuation.finish()
        #expect(try await first.value == .hook)

        #expect(
            try await uiHook.dispatch(
                mutation: .unread(isUnread: true),
                workspaceID: "workspace-2",
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            ) == .hook
        )
    }

    @Test("Connection replacement terminates the old stream and ignores stale disconnects")
    func replacement() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let firstConnection = await uiHook.connect()
        var firstEvents = firstConnection.events.makeAsyncIterator()
        let secondConnection = await uiHook.connect()
        var secondEvents = secondConnection.events.makeAsyncIterator()
        #expect(await firstEvents.next() == nil)

        #expect(
            try await uiHook.dispatch(
                mutation: .unread(isUnread: true),
                workspaceID: "workspace-1",
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            ) == .hook
        )
        #expect(await secondEvents.next() != nil)

        await uiHook.disconnect(connectionID: firstConnection.id)
        #expect(await uiHook.isConnected())
        await uiHook.disconnect(connectionID: secondConnection.id)
        #expect(await uiHook.isConnected() == false)
    }
}

private enum PersistenceError: Error, Equatable {
    case unexpectedWait
}
