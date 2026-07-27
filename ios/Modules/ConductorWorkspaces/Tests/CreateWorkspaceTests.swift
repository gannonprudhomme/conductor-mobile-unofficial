//
//  CreateWorkspaceTests.swift
//  ConductorWorkspacesTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorMobileData
import CustomDump
import Foundation
import SharedConductorData
@_spi(Internals) import Sharing
import SQLiteData
import SwiftUI
@testable import ConductorWorkspaces
import Testing
import UIKit

@MainActor
struct CreateWorkspaceTests {
    @Test("Repository selection uses the requested repository when available")
    func repositorySelection() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let first = Repository.preview(id: "first")
            let selected = Repository.preview(id: "selected")

            expectNoDifference(
                CreateWorkspace.State(
                    repositories: [first, selected],
                    selectedRepositoryIDFilter: selected.id
                ).selectedRepositoryID,
                selected.id
            )
            expectNoDifference(
                CreateWorkspace.State(
                    repositories: [first, selected],
                    selectedRepositoryIDFilter: "missing"
                ).selectedRepositoryID,
                first.id
            )
            expectNoDifference(
                CreateWorkspace.State(
                    repositories: [first, selected]
                ).selectedRepositoryID,
                first.id
            )
        }
    }

    @Test("Create sends the selected repository, model, and Fast Mode")
    func createWorkspace() async throws {
        let repository = Repository.preview()
        let workspaceID = UUID(0).uuidString.lowercased()
        let session = Session.preview(
            id: "session",
            workspaceID: workspaceID,
            model: .gpt_5_6_terra,
            isFastModeEnabled: true
        )
        let workspace = Workspace.preview(
            id: workspaceID,
            activeSessionID: session.id,
            repositoryID: repository.id
        )
        let database = try appDatabase()
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = CreateWorkspace.State(repositories: [repository])
            state.isFastModeEnabled = true
            state.selectedModel = .gpt_5_6_terra
            state.$prompt.withLock { $0 = "  Run the tests.  " }
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
                $0.uuid = .incrementing
                $0.desktopClient.createWorkspace = {
                    requestedWorkspaceID,
                    repositoryID,
                    agentType,
                    model,
                    isFastModeEnabled in
                    #expect(requestedWorkspaceID == workspaceID)
                    #expect(repositoryID == repository.id)
                    #expect(agentType == .codex)
                    #expect(model == .gpt_5_6_terra)
                    #expect(isFastModeEnabled)
                    return CreatedWorkspace(workspace: workspace, session: session)
                }
                $0.desktopClient.sendMessage = {
                    requestedWorkspaceID,
                    sessionID,
                    message,
                    model,
                    isFastModeEnabled,
                    attemptID in
                    #expect(requestedWorkspaceID == workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Run the tests.")
                    #expect(model == .gpt_5_6_terra)
                    #expect(isFastModeEnabled)
                    #expect(attemptID == UUID(2))
                    return .accepted(messageID: "message")
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.createButtonTapped) {
                $0.isCreateAPIInFlight = true
                $0.workspaceID = workspaceID
            }
            await store.receive(\.createWorkspaceSucceeded) {
                $0.isCreateAPIInFlight = false
            }
            await store.receive(
                \.delegate,
                .workspaceCreated(
                    WorkspaceCreationResult(
                        selectedModel: .gpt_5_6_terra,
                        workspace: WorkspaceWithRepository(
                            workspace: workspace,
                            repository: repository
                        )
                    )
                )
            )
            #expect(store.state.prompt.isEmpty)
            let bubble = try #require(
                store.state.outbox[workspace.id, session.id].first
            )
            #expect(bubble.bubbleID == UUID(1))
            #expect(bubble.createdAt == Date(timeIntervalSince1970: 1_783_558_800))
            #expect(bubble.attempts == [
                .init(attemptID: UUID(2), state: .accepted(messageID: "message")),
            ])
        }
    }

    @Test("Unknown prompt delivery enters the workspace with its durable bubble")
    func unknownPromptDelivery() async throws {
        let repository = Repository.preview()
        let workspaceID = UUID(0).uuidString.lowercased()
        let session = Session.preview(id: "session", workspaceID: workspaceID)
        let workspace = Workspace.preview(
            id: workspaceID,
            activeSessionID: session.id,
            repositoryID: repository.id
        )
        let database = try appDatabase()
        let saveRecorder = LockIsolated<[MessageOutbox]>([])
        let outboxKey = RecordingOutboxKey(savedValues: saveRecorder)
        @Shared(outboxKey) var outbox = MessageOutbox()

        let state = CreateWorkspace.State(
            repositories: [repository],
            outbox: $outbox
        )
        state.$prompt.withLock { $0 = "Run the tests." }
        let store = TestStore(initialState: state) {
            CreateWorkspace()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
            $0.uuid = .incrementing
            $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                CreatedWorkspace(workspace: workspace, session: session)
            }
            $0.desktopClient.sendMessage = {
                _, _, _, _, _, attemptID in
                let stagedBubble = saveRecorder.value
                    .first?[workspace.id, session.id]
                    .first
                #expect(stagedBubble?.bubbleID == UUID(1))
                #expect(stagedBubble?.attempts == [
                    .init(attemptID: attemptID, state: .sending),
                ])
                return .unknown(reason: "Delivery could not be determined.")
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createButtonTapped) {
            $0.isCreateAPIInFlight = true
            $0.workspaceID = workspaceID
        }
        await store.receive(\.createWorkspaceSucceeded) {
            $0.isCreateAPIInFlight = false
        }
        await store.receive(
            \.delegate,
            .workspaceCreated(
                WorkspaceCreationResult(
                    selectedModel: .gpt_5_6_sol,
                    workspace: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: repository
                    )
                )
            )
        )

        #expect(store.state.alert == nil)
        #expect(store.state.prompt.isEmpty)
        #expect(store.state.outbox[workspace.id, session.id].first?.attempts == [
            .init(attemptID: UUID(2), state: .unknown),
        ])
        #expect(saveRecorder.value.count == 2)
    }

    @Test("A prompt save failure still enters the created workspace")
    func promptSaveFailureIsPartialCreation() async throws {
        let repository = Repository.preview()
        let workspaceID = UUID(0).uuidString.lowercased()
        let session = Session.preview(id: "session", workspaceID: workspaceID)
        let workspace = Workspace.preview(
            id: workspaceID,
            activeSessionID: session.id,
            repositoryID: repository.id
        )
        let database = try appDatabase()
        let outboxKey = RecordingOutboxKey(
            savedValues: LockIsolated([]),
            shouldFail: true
        )
        @Shared(outboxKey) var outbox = MessageOutbox()
        let requestCount = LockIsolated(0)

        let state = CreateWorkspace.State(
            repositories: [repository],
            outbox: $outbox
        )
        state.$prompt.withLock { $0 = "Run the tests." }
        let store = TestStore(initialState: state) {
            CreateWorkspace()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.date.now = Date(timeIntervalSince1970: 1_783_558_800)
            $0.uuid = .incrementing
            $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                CreatedWorkspace(workspace: workspace, session: session)
            }
            $0.desktopClient.sendMessage = { _, _, _, _, _, _ in
                requestCount.withValue { $0 += 1 }
                return .accepted(messageID: "unexpected")
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.createButtonTapped)
        await store.receive(\.createWorkspaceSucceeded) {
            $0.isCreateAPIInFlight = false
        }
        await store.receive(
            \.delegate,
            .workspaceCreated(
                WorkspaceCreationResult(
                    promptFailureMessage: TestError().localizedDescription,
                    selectedModel: .gpt_5_6_sol,
                    workspace: WorkspaceWithRepository(
                        workspace: workspace,
                        repository: repository
                    )
                )
            )
        )

        #expect(requestCount.value == 0)
        #expect(store.state.prompt == "Run the tests.")
        #expect(store.state.outbox[workspace.id, session.id].isEmpty)
        #expect(store.state.$outbox.saveError != nil)
        let persistedWorkspace = try await database.read { database in
            try Workspace.find(workspace.id).fetchOne(database)
        }
        #expect(persistedWorkspace == workspace)
    }

    @Test("A known outbox failure prevents workspace creation with a prompt")
    func knownPromptOutboxFailurePreflightsCreation() async {
        let repository = Repository.preview()
        let outboxKey = RecordingOutboxKey(
            savedValues: LockIsolated([]),
            shouldFail: true
        )
        @Shared(outboxKey) var outbox = MessageOutbox()
        try? await $outbox.save()
        let requestCount = LockIsolated(0)
        let state = CreateWorkspace.State(
            repositories: [repository],
            outbox: $outbox
        )
        state.$prompt.withLock { $0 = "Run the tests." }
        let store = TestStore(initialState: state) {
            CreateWorkspace()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                requestCount.withValue { $0 += 1 }
                throw TestError()
            }
        }

        await store.send(.createButtonTapped) {
            $0.alert = .failedToSavePrompt(
                message: TestError().localizedDescription
            )
        }

        #expect(requestCount.value == 0)
        #expect(store.state.workspaceID == nil)
    }

    @Test("Create shows an alert when creation fails")
    func createWorkspaceFailure() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let repository = Repository.preview()
            let state = CreateWorkspace.State(repositories: [repository])
            let database = try appDatabase()
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.uuid = .incrementing
                $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                    throw TestError()
                }
            }

            await store.send(.createButtonTapped) {
                $0.isCreateAPIInFlight = true
                $0.workspaceID = UUID(0).uuidString.lowercased()
            }
            await store.receive(\.createWorkspaceFailed) {
                $0.alert = .failedToCreateWorkspace(message: TestError().localizedDescription)
                $0.isCreateAPIInFlight = false
            }
        }
    }

    @Test("The desktop default model seeds the picker until the user selects one")
    func defaultModel() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let repository = Repository.preview()
            let store = TestStore(
                initialState: CreateWorkspace.State(repositories: [repository])
            ) {
                CreateWorkspace()
            } withDependencies: {
                $0.desktopClient.fetchDefaultModel = { .sonnet5_1M }
            }

            await store.send(.task)
            await store.receive(\.defaultModelFetched) {
                $0.agentType = .claude
                $0.selectedModel = .sonnet5_1M
            }

            await store.send(.binding(.set(\.selectedModel, .opus4_8_1M))) {
                $0.hasUserSelectedModel = true
                $0.selectedModel = .opus4_8_1M
            }
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_sol))) {
                $0.agentType = .codex
                $0.selectedModel = .gpt_5_6_sol
            }
            await store.send(.defaultModelFetched(.gpt_5_6_sol))
        }
    }

    @Test("The workspace prompt is restored from file storage")
    func promptDraft() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let repository = Repository.preview()
            let state = CreateWorkspace.State(repositories: [repository])
            state.$prompt.withLock { $0 = "Persist this prompt" }

            expectNoDifference(
                CreateWorkspace.State(repositories: [repository]).prompt,
                "Persist this prompt"
            )
        }
    }

    @Test("The create sheet renders and focuses an editable prompt")
    func promptEditor() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = Store(
                initialState: CreateWorkspace.State(repositories: [.preview()])
            ) {
                CreateWorkspace()
            }
            let hostingController = UIHostingController(
                rootView: CreateWorkspaceView(store: store)
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while firstTextView(in: hostingController.view) == nil,
                  clock.now < deadline {
                await Task.yield()
            }

            let textView = try #require(firstTextView(in: hostingController.view))
            #expect(textView.isFirstResponder)

            textView.insertText("Build the feature")

            while store.state.prompt != "Build the feature", clock.now < deadline {
                await Task.yield()
            }
            expectNoDifference(store.state.prompt, "Build the feature")
        }
    }
}

@MainActor
private func firstTextView(in view: UIView) -> UITextView? {
    if let textView = view as? UITextView {
        return textView
    }
    for subview in view.subviews {
        if let textView = firstTextView(in: subview) {
            return textView
        }
    }
    return nil
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}

private struct RecordingOutboxKey: SharedKey {
    let id = UUID()
    let savedValues: LockIsolated<[MessageOutbox]>
    var shouldFail = false

    func load(
        context: LoadContext<MessageOutbox>,
        continuation: LoadContinuation<MessageOutbox>
    ) {
        continuation.resumeReturningInitialValue()
    }

    func subscribe(
        context: LoadContext<MessageOutbox>,
        subscriber: SharedSubscriber<MessageOutbox>
    ) -> SharedSubscription {
        SharedSubscription { }
    }

    func save(
        _ value: MessageOutbox,
        context: SaveContext,
        continuation: SaveContinuation
    ) {
        if shouldFail {
            continuation.resume(throwing: TestError())
            return
        }
        switch context {
        case .didSet:
            break
        case .userInitiated:
            savedValues.withValue { $0.append(value) }
        }
        continuation.resume()
    }
}
