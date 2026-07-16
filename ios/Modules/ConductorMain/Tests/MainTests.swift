//
//  MainTests.swift
//  ConductorMainTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Combine
import ComposableArchitecture
import ConductorSettings
import SharedConductorData
import ConductorMobileData
import ConductorWorkspaces
import Sharing
import SQLiteData
import SwiftUI
@testable import ConductorChat
@testable import ConductorMain
import Testing
import UIKit

@MainActor
struct MainTests {
    @Test("A fresh install requires the server address in Settings")
    func freshInstallRequiresServerAddress() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let state = Main.State()

            #expect(state.settings?.isServerAddressMissing == true)
        }
    }

    @Test("Settings button presents settings")
    func settingsButtonPresentsSettings() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.settingsButtonTapped)) {
                $0.settings = ConductorSettings.State()
            }
        }
    }

    @Test("Workspace selection pushes its chat")
    func workspaceSelectionPushesChat() async throws {
        let workspace = Workspace.preview(
            activeSessionID: "active",
            branch: "add-chat-screen"
        )
        let repository = Repository.preview()
        let item = WorkspaceWithRepository(workspace: workspace, repository: repository)

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(item))) {
                $0.path.append(
                    .workspaceChat(
                        WorkspaceChat.State(workspaceWithRepository: item)
                    )
                )
            }
        }
    }

    @Test("Workspace stream remains active while chat is pushed")
    func workspaceStreamRemainsActiveWhileChatIsPushed() async throws {
        let cachedSession = Session.preview(id: "cached")
        let activeSession = Session.preview(id: "active")
        let cachedWorkspace = Workspace.preview(
            activeSessionID: cachedSession.id,
            derivedStatus: Workspace.Status.inProgress.rawValue
        )
        var updatedWorkspace = cachedWorkspace
        updatedWorkspace.activeSessionID = activeSession.id
        let cachedItem = WorkspaceWithRepository(
            workspace: cachedWorkspace,
            repository: nil
        )
        let database = try appDatabase()

        try await database.write { db in
            try Workspace.upsert { cachedWorkspace }.execute(db)
            try Session.upsert { [cachedSession, activeSession] }.execute(db)
        }

        let (workspaceConnections, workspaceConnectionsContinuation) = AsyncStream<Void>
            .makeStream()
        let (workspaceSnapshots, workspaceSnapshotsContinuation) = AsyncThrowingStream<
            WorkspaceListSnapshot,
            any Error
        >.makeStream()
        let (sessionConnections, sessionConnectionsContinuation) = AsyncStream<Void>
            .makeStream()
        let (sessions, sessionsContinuation) = AsyncThrowingStream<
            [Session],
            any Error
        >.makeStream()
        let (messages, messagesContinuation) = AsyncThrowingStream<
            [Message],
            any Error
        >.makeStream()
        let workspaceConnectionCount = LockIsolated(0)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { workspaceID, _ in
                #expect(workspaceID == cachedWorkspace.id)
                return messages
            }
            $0.desktopClient.observeSessions = { workspaceID in
                #expect(workspaceID == cachedWorkspace.id)
                sessionConnectionsContinuation.yield()
                return sessions
            }
            $0.desktopClient.observeWorkspaces = {
                workspaceConnectionCount.withValue { $0 += 1 }
                workspaceConnectionsContinuation.yield()
                return workspaceSnapshots
            }
        } operation: {
            let store = Store(initialState: Main.State()) {
                Main()
            }
            let (activeSessionSelections, activeSessionSelectionsContinuation) = AsyncStream<Void>
                .makeStream()
            let stateObservation = store.publisher.sink { state in
                guard let pathID = state.path.ids.first,
                      case let .workspaceChat(chat) = state.path[id: pathID],
                      chat.chat?.sessionID == activeSession.id
                else {
                    return
                }

                activeSessionSelectionsContinuation.yield()
                activeSessionSelectionsContinuation.finish()
            }
            let hostingController = UIHostingController(
                rootView: MainView(store: store)
            )
            // Hostless unit tests have no UIWindowScene. A standalone window still gives SwiftUI
            // the real appearance/disappearance lifecycle this regression test needs.
            let window = UIWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            defer {
                stateObservation.cancel()
                activeSessionSelectionsContinuation.finish()
                messagesContinuation.finish()
                sessionConnectionsContinuation.finish()
                sessionsContinuation.finish()
                workspaceConnectionsContinuation.finish()
                workspaceSnapshotsContinuation.finish()
                window.isHidden = true
                window.rootViewController = nil
            }

            _ = try await firstValue(
                in: workspaceConnections,
                waitingFor: "the workspace connection"
            )
            #expect(workspaceConnectionCount.value == 1)

            store.send(.workspaces(.workspaceTapped(cachedItem)))
            _ = try await firstValue(
                in: sessionConnections,
                waitingFor: "the session connection"
            )

            workspaceSnapshotsContinuation.yield(
                WorkspaceListSnapshot(
                    repositories: [],
                    workspaces: [
                        WorkspaceSnapshot(
                            workspace: updatedWorkspace,
                            isWorking: false
                        )
                    ]
                )
            )

            _ = try await firstValue(
                in: activeSessionSelections,
                waitingFor: "the streamed active-session selection"
            )
            #expect(workspaceConnectionCount.value == 1)
        }
    }
}

private func firstValue<Value: Sendable>(
    in stream: AsyncStream<Value>,
    waitingFor description: String,
    timeout: Duration = .seconds(5)
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw TestTimeoutError(description: description)
        }
        group.addTask {
            try await ContinuousClock().sleep(for: timeout)
            throw TestTimeoutError(description: description)
        }

        guard let value = try await group.next() else {
            throw TestTimeoutError(description: description)
        }
        group.cancelAll()
        return value
    }
}

private struct TestTimeoutError: Error, CustomStringConvertible {
    let description: String
}
