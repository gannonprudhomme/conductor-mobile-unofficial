//
//  WorkspaceUIHookTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Foundation
import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookTests {
    @Test("Session creation requires a listener and emits its workspace command")
    func createSession() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        await #expect(throws: WorkspaceUIHook.DispatchError.listenerUnavailable) {
            try await uiHook.createSession(
                workspaceID: "workspace-1",
                waitUntilChangeAvailableInDatabase: {}
            )
        }

        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let creation = Task {
            try await uiHook.createSession(
                workspaceID: "workspace-\"2",
                waitUntilChangeAvailableInDatabase: {}
            )
        }
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-\\\"2\",\"createSession\":true}\n\n"
        )
        try await creation.value
    }

    @Test("Workspace creation frames preserve the Conductor service argument names")
    func createWorkspaceFrame() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let command = CreateWorkspaceCommand(
            repositoryID: "repository-1",
            workspaceID: "workspace-1",
            agentType: "codex",
            model: "gpt-5.6-sol"
        )

        let didDispatch = try await uiHook.createWorkspace(
            command: command,
            waitUntilChangeAvailableInDatabase: {}
        )
        let frame = try #require(await events.next())
        let data = try #require(
            frame
                .replacingOccurrences(of: "data: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8)
        )
        let payload = try JSONDecoder().decode(
            [String: CreateWorkspaceCommand].self,
            from: data
        )

        #expect(didDispatch)
        #expect(payload == ["createWorkspace": command])
    }

    @Test("Workspace creation retries observe persistence without enqueueing twice")
    func createWorkspaceRetry() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let command = CreateWorkspaceCommand(
            repositoryID: "repository-1",
            workspaceID: "workspace-1",
            agentType: "codex",
            model: "gpt-5.6-sol"
        )

        await #expect(throws: PersistenceError.expectedFailure) {
            try await uiHook.createWorkspace(
                command: command,
                waitUntilChangeAvailableInDatabase: {
                    throw PersistenceError.expectedFailure
                }
            )
        }
        _ = try #require(await events.next())

        #expect(
            try await uiHook.createWorkspace(
                command: command,
                waitUntilChangeAvailableInDatabase: {}
            )
        )
        #expect(
            try await uiHook.dispatch(
                command: .workspace(
                    id: "workspace-2",
                    mutation: .pinned(isPinned: true)
                ),
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            ) == .hook
        )
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-2\",\"pinned\":true}\n\n"
        )
    }

    @Test("SSE frames escape mutation values without command IDs")
    func escapedFrame() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()

        let path = try await uiHook.dispatch(
            command: .workspace(
                id: "workspace-\"2",
                mutation: .status("in-\nprogress")
            ),
            fallback: {},
            waitUntilChangeAvailableInDatabase: {}
        )
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-\\\"2\",\"status\":\"in-\\nprogress\"}\n\n"
        )
        #expect(path == .hook)

        let archivePath = try await uiHook.dispatch(
            command: .workspace(
                id: "workspace-\"2",
                mutation: .archive
            ),
            fallback: {},
            waitUntilChangeAvailableInDatabase: {}
        )
        #expect(
            await events.next()
                == "data: {\"workspaceId\":\"workspace-\\\"2\",\"archive\":true}\n\n"
        )
        #expect(archivePath == .hook)

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

        let didDispatchAgentAndModel = try await uiHook.updateSessionAgentAndModel(
            sessionID: "session-\"4",
            agentType: .claude,
            model: .fable5,
            waitUntilChangeAvailableInDatabase: {}
        )
        #expect(
            await events.next()
                == "data: {\"sessionId\":\"session-\\\"4\",\"agentAndModel\":{\"agentType\":\"claude\",\"model\":\"fable-5\"}}\n\n"
        )
        #expect(didDispatchAgentAndModel)
    }

    @Test("Fallback holds the global slot without waiting for persistence")
    func disconnectedFallback() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let (fallbackStarted, fallbackStartedContinuation) = AsyncStream<Void>.makeStream()
        var fallbackStarts = fallbackStarted.makeAsyncIterator()
        let (fallbackGate, fallbackGateContinuation) = AsyncStream<Void>.makeStream()

        let fallback = Task {
            try await uiHook.dispatch(
                command: .workspace(
                    id: "workspace-1",
                    mutation: .pinned(isPinned: true)
                ),
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
                command: .workspace(
                    id: "workspace-2",
                    mutation: .unread(isUnread: true)
                ),
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
                command: .workspace(
                    id: "workspace-1",
                    mutation: .pinned(isPinned: true)
                ),
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
                command: .workspace(
                    id: "workspace-2",
                    mutation: .unread(isUnread: true)
                ),
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            )
        }

        persistenceContinuation.finish()
        #expect(try await first.value == .hook)

        #expect(
            try await uiHook.dispatch(
                command: .workspace(
                    id: "workspace-2",
                    mutation: .unread(isUnread: true)
                ),
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
                command: .sessionFastMode(
                    sessionID: "session-1",
                    isEnabled: true
                ),
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            ) == .hook
        )
        #expect(
            await secondEvents.next()
                == "data: {\"sessionId\":\"session-1\",\"fastMode\":true}\n\n"
        )

        await uiHook.disconnect(connectionID: firstConnection.id)
        #expect(await uiHook.isConnected())
        await uiHook.disconnect(connectionID: secondConnection.id)
        #expect(await uiHook.isConnected() == false)
    }
}

private enum PersistenceError: Error, Equatable {
    case expectedFailure
    case unexpectedWait
}
