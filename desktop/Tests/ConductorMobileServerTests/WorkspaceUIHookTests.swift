//
//  WorkspaceUIHookTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Foundation
import SharedConductorData
import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookTests {
    @Test("Commands return generic browser acceptance or rejection")
    func sendMessage() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let unavailableRequestID = UUID()
        await #expect(throws: WorkspaceUIHook.CommandDispatchError.listenerUnavailable) {
            try await uiHook.sendMessage(
                requestID: unavailableRequestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Run the tests.",
                mode: .sent
            )
        }

        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let sentRequestID = UUID()
        let send = Task {
            try await uiHook.sendMessage(
                requestID: sentRequestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Run the tests.",
                mode: .sent
            )
        }
        let command = try decodeMessageCommand(try #require(await events.next()))
        #expect(command.requestID == sentRequestID)
        #expect(command.sessionID == "session-1")
        #expect(command.workspaceID == "workspace-1")
        #expect(command.sendMessage.content == "Run the tests.")
        #expect(command.sendMessage.mode == "sent")
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(
                    requestID: command.requestID,
                    error: nil
                )
            )
        )
        try await send.value

        let rejectedRequestID = UUID()
        let rejectedSend = Task {
            try await uiHook.sendMessage(
                requestID: rejectedRequestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Fail.",
                mode: .queued
            )
        }
        let rejectedCommand = try decodeMessageCommand(try #require(await events.next()))
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(
                    requestID: rejectedCommand.requestID,
                    error: "Nope."
                )
            )
        )
        await #expect(throws: WorkspaceUIHook.CommandDispatchError.commandFailed("Nope.")) {
            try await rejectedSend.value
        }
    }

    @Test("Message command acknowledgements complete independently across sessions")
    func overlappingMessages() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let firstRequestID = UUID()
        let secondRequestID = UUID()

        let first = Task {
            try await uiHook.sendMessage(
                requestID: firstRequestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "First",
                mode: .sent
            )
        }
        let second = Task {
            try await uiHook.sendMessage(
                requestID: secondRequestID,
                sessionID: "session-2",
                workspaceID: "workspace-1",
                content: "Second",
                mode: .sent
            )
        }

        let commands = try [
            decodeMessageCommand(try #require(await events.next())),
            decodeMessageCommand(try #require(await events.next())),
        ]
        #expect(Set(commands.map(\.requestID)) == [firstRequestID, secondRequestID])
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(
                    requestID: secondRequestID,
                    error: nil
                )
            )
        )
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(
                    requestID: firstRequestID,
                    error: nil
                )
            )
        )
        try await first.value
        try await second.value
    }

    @Test("Canceling a message command removes its pending callback")
    func cancelMessage() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let requestID = UUID()
        let send = Task {
            try await uiHook.sendMessage(
                requestID: requestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Slow",
                mode: .sent
            )
        }
        _ = await events.next()

        send.cancel()
        await #expect(throws: CancellationError.self) {
            try await send.value
        }
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(
                    requestID: requestID,
                    error: nil
                )
            ) == false
        )
    }

    @Test("Disconnecting loses an enqueued command callback")
    func disconnectMessage() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let requestID = UUID()
        let send = Task {
            try await uiHook.sendMessage(
                requestID: requestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Slow",
                mode: .sent
            )
        }
        _ = await events.next()

        await uiHook.disconnect(connectionID: connection.id)
        await #expect(throws: WorkspaceUIHook.CommandDispatchError.deliveryUnknown) {
            try await send.value
        }
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(requestID: requestID, error: nil)
            ) == false
        )
    }

    @Test("Stop commands serialize mutations until accepted persistence completes")
    func stopSession() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let stoppedSession = workspaceUIHookSession()
        let (persistence, persistenceContinuation) = AsyncStream<Session>.makeStream()
        let stop = Task {
            try await uiHook.stopSession(
                requestID: requestID,
                sessionID: "session-\"1"
            ) {
                for await session in persistence {
                    return session
                }
                return nil
            }
        }

        #expect(
            await events.next()
                == "data: {\"requestId\":\"11111111-2222-3333-4444-555555555555\",\"sessionId\":\"session-\\\"1\",\"stopSession\":true}\n\n"
        )
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(requestID: requestID, error: nil)
            )
        )
        await #expect(throws: WorkspaceUIHook.DispatchError.mutationInFlight) {
            try await uiHook.dispatch(
                command: .workspace(
                    id: "workspace-1",
                    mutation: .pinned(isPinned: true)
                ),
                fallback: {},
                waitUntilChangeAvailableInDatabase: {}
            )
        }

        persistenceContinuation.yield(stoppedSession)
        persistenceContinuation.finish()
        #expect(try await stop.value == stoppedSession)
    }

    @Test("Stop commands classify accepted and unknown persistence timeouts")
    func stopTimeouts() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let acceptedRequestID = UUID()
        let (acceptedGate, acceptedGateContinuation) = AsyncStream<Void>.makeStream()
        let accepted = Task {
            try await uiHook.stopSession(
                requestID: acceptedRequestID,
                sessionID: "session-1"
            ) {
                for await _ in acceptedGate {
                    return nil
                }
                return nil
            }
        }
        _ = await events.next()
        #expect(
            await uiHook.didCompleteCommand(
                result: WorkspaceUIHook.CommandResult(requestID: acceptedRequestID, error: nil)
            )
        )
        await Task.yield()
        acceptedGateContinuation.yield(())
        acceptedGateContinuation.finish()
        await #expect(throws: WorkspaceUIHook.CommandDispatchError.persistenceTimedOut) {
            try await accepted.value
        }

        let unknownRequestID = UUID()
        let (unknownGate, unknownGateContinuation) = AsyncStream<Void>.makeStream()
        let unknown = Task {
            try await uiHook.stopSession(
                requestID: unknownRequestID,
                sessionID: "session-1"
            ) {
                for await _ in unknownGate {
                    return nil
                }
                return nil
            }
        }
        _ = await events.next()
        await uiHook.disconnect(connectionID: connection.id)
        unknownGateContinuation.yield(())
        unknownGateContinuation.finish()
        await #expect(throws: WorkspaceUIHook.CommandDispatchError.deliveryUnknown) {
            try await unknown.value
        }
    }

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

private func decodeMessageCommand(_ event: String) throws -> TestMessageCommand {
    let prefix = "data: "
    #expect(event.hasPrefix(prefix))
    #expect(event.hasSuffix("\n\n"))
    let payload = event.dropFirst(prefix.count).dropLast(2)
    return try JSONDecoder().decode(TestMessageCommand.self, from: Data(payload.utf8))
}

private func workspaceUIHookSession() -> Session {
    Session(
        id: "session-1",
        workspaceID: "workspace-1",
        title: "Stopped",
        agentType: .codex,
        isHidden: false,
        createdAt: "2026-07-12T00:00:00Z",
        updatedAt: "2026-07-12T00:00:01Z",
        lastUserMessageAt: nil,
        status: .idle,
        model: .gpt5_5,
        unreadCount: 0,
        freshlyCompacted: 0,
        contextTokenCount: 0
    )
}

private struct TestMessageCommand: Decodable {
    let requestID: UUID
    let sessionID: String
    let workspaceID: String
    let sendMessage: SendMessage

    struct SendMessage: Decodable {
        let content: String
        let mode: String
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sessionID = "sessionId"
        case workspaceID = "workspaceId"
        case sendMessage
    }
}

private enum PersistenceError: Error, Equatable {
    case expectedFailure
    case unexpectedWait
}
