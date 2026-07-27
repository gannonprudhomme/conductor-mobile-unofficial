//
//  MainTests.swift
//  ConductorMainTests
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Combine
import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import ConductorSettings
import ConductorWorkspaces
import SharedConductorData
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

    @Test("A cloud-badged desktop workspace uses the cloud chat backend")
    func localCloudWorkspaceSelectionUsesCloud() async throws {
        let workspace = Workspace.preview(
            activeSessionID: "cloud-session",
            branch: "cloud-workspace",
            hostingServerURL: "https://hosting.example.test"
        )
        let item = WorkspaceWithRepository(
            workspace: workspace,
            repository: .preview()
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(item))) {
                $0.path.append(
                    .cloudWorkspace(
                        CloudWorkspaceFeature.State(
                            workspaceID: item.id,
                            fallbackTitle: item.workspace.displayName
                        )
                    )
                )
            }
        }
    }

    @Test("The Cloud API path wins when both backends know a workspace")
    func catalogWorkspaceSelectionUsesCloud() async throws {
        let workspace = Workspace.preview(
            activeSessionID: "cloud-session",
            branch: "cloud-workspace"
        )
        let item = WorkspaceWithRepository(
            workspace: workspace,
            repository: .preview()
        )
        let cloudWorkspace = CloudWorkspace(
            id: workspace.id,
            name: workspace.displayName,
            createdAt: .now,
            deepLink: try #require(URL(string: "conductor://cloud-workspace"))
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            var initialState = Main.State()
            initialState.workspaces.cloudCatalog.workspaces = [
                CloudProjectWorkspace(
                    project: CloudProject(
                        id: "project",
                        name: "Project",
                        gitRemote: "https://example.test/repository.git"
                    ),
                    workspace: cloudWorkspace
                )
            ]
            let store = TestStore(initialState: initialState) {
                Main()
            }

            await store.send(.workspaces(.workspaceTapped(item))) {
                $0.path.append(
                    .cloudWorkspace(
                        CloudWorkspaceFeature.State(
                            workspaceID: cloudWorkspace.id,
                            fallbackTitle: cloudWorkspace.name
                        )
                    )
                )
            }
        }
    }

    @Test("An API-only cloud workspace uses the cloud backend")
    func cloudCatalogWorkspaceSelectionUsesCloud() async throws {
        let item = CloudProjectWorkspace(
            project: CloudProject(
                id: "project",
                name: "Project",
                gitRemote: "https://example.test/repository.git"
            ),
            workspace: CloudWorkspace(
                id: "cloud-workspace",
                name: "API-only workspace",
                createdAt: .now,
                deepLink: try #require(URL(string: "conductor://cloud-workspace"))
            )
        )

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.cloudCatalog(.workspaceTapped(item)))) {
                $0.path.append(
                    .cloudWorkspace(
                        CloudWorkspaceFeature.State(
                            workspaceID: item.id,
                            fallbackTitle: item.workspace.name
                        )
                    )
                )
            }
        }
    }

    @Test("Archived workspace delegate pops its chat")
    func archivedWorkspacePopsChat() async throws {
        let item = WorkspaceWithRepository(
            workspace: .preview(id: "workspace"),
            repository: nil
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            var initialState = Main.State()
            initialState.path.append(
                .workspaceChat(WorkspaceChat.State(workspaceWithRepository: item))
            )
            let pathID = try #require(initialState.path.ids.first)
            let store = TestStore(initialState: initialState) {
                Main()
            }

            await store.send(
                .path(
                    .element(
                        id: pathID,
                        action: .workspaceChat(.delegate(.workspaceArchived))
                    )
                )
            ) {
                $0.path.pop(from: pathID)
            }
        }
    }

    @Test("Workspace creation pushes its chat")
    func workspaceCreationPushesChat() async throws {
        let workspace = Workspace.preview(activeSessionID: "active")
        let item = WorkspaceWithRepository(workspace: workspace, repository: .preview())
        let creation = WorkspaceCreationResult(
            selectedModel: .gpt_5_6_terra,
            workspace: item
        )

        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Main.State()) {
                Main()
            }

            await store.send(.workspaces(.workspaceCreated(creation))) {
                $0.path.append(
                    .workspaceChat(
                        WorkspaceChat.State(
                            workspaceWithRepository: item,
                            selectedModel: .gpt_5_6_terra,
                            shouldFocusMessageField: true
                        )
                    )
                )
            }
        }
    }

    @Test("A newly created workspace's message field accepts text")
    func newlyCreatedWorkspaceMessageFieldAcceptsText() async throws {
        let repository = Repository.preview()
        let workspace = Workspace.preview(
            activeSessionID: "active",
            derivedStatus: Workspace.Status.inProgress.rawValue,
            repositoryID: repository.id
        )
        let session = Session.preview(id: "active", workspaceID: workspace.id)
        let item = WorkspaceWithRepository(
            workspace: workspace,
            repository: repository
        )
        let creation = WorkspaceCreationResult(
            selectedModel: session.model,
            workspace: item
        )
        let database = try appDatabase()

        try await database.write { db in
            try Repository.upsert { repository }.execute(db)
            try Workspace.upsert { workspace }.execute(db)
            try Session.upsert { session }.execute(db)
        }

        try await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.desktopClient.observeMessages = { _, _, _ in
                AsyncThrowingStream { $0.finish() }
            }
            $0.desktopClient.observeSessions = { _ in
                AsyncThrowingStream { $0.finish() }
            }
            $0.desktopClient.observeWorkspaces = {
                AsyncThrowingStream { $0.finish() }
            }
            $0.desktopClient.ping = { }
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }

            let store = Store(initialState: Main.State()) {
                Main()
            }
            let hostingController = UIHostingController(
                rootView: MainView(store: store)
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            store.send(.workspaces(.workspaceCreated(creation)))

            while firstTextInputResponder(in: hostingController.view) == nil,
                  clock.now < deadline {
                await Task.yield()
            }

            let responder = try #require(firstTextInputResponder(in: hostingController.view))
            let center = responder.convert(
                CGPoint(x: responder.bounds.midX, y: responder.bounds.midY),
                to: hostingController.view
            )
            let hitView = hostingController.view.hitTest(center, with: nil)
            #expect(
                hitView === responder
                    || hitView?.isDescendant(of: responder) == true
            )

            responder.insertText("Test message")

            while messageDraft(in: store.state) != "Test message",
                  clock.now < deadline {
                await Task.yield()
            }
            #expect(messageDraft(in: store.state) == "Test message")
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
            MessageSyncResponse,
            any Error
        >.makeStream()
        let workspaceConnectionCount = LockIsolated(0)

        try await withDependencies {
            $0.defaultDatabase = database
            $0.desktopClient.observeMessages = { workspaceID, _, _ in
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

@MainActor
private func firstTextInputResponder(in view: UIView) -> (UIView & UIKeyInput)? {
    if view.isFirstResponder, let textInput = view as? UIView & UIKeyInput {
        return textInput
    }
    for subview in view.subviews {
        if let responder = firstTextInputResponder(in: subview) {
            return responder
        }
    }
    return nil
}

@MainActor
private func messageDraft(in state: Main.State) -> String? {
    guard let pathID = state.path.ids.first,
          case let .workspaceChat(workspaceChat) = state.path[id: pathID]
    else {
        return nil
    }
    return workspaceChat.chat?.messageDraft
}

private struct TestTimeoutError: Error, CustomStringConvertible {
    let description: String
}
