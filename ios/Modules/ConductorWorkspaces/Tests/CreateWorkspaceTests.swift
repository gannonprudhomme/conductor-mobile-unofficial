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
import Sharing
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
        let sentMessage = Message(
            id: "message",
            sessionID: session.id,
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_555_200),
            turnID: "turn"
        )

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
                    isFastModeEnabled in
                    #expect(requestedWorkspaceID == workspaceID)
                    #expect(sessionID == session.id)
                    #expect(message == "Run the tests.")
                    #expect(model == .gpt_5_6_terra)
                    #expect(isFastModeEnabled)
                    return sentMessage
                }
            }

            await store.send(.createButtonTapped) {
                $0.isCreateAPIInFlight = true
                $0.workspaceID = workspaceID
            }
            await store.receive(\.createWorkspaceSucceeded) {
                $0.$prompt.withLock { $0 = "" }
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

            let message = try await database.read { database in
                try Message.find(sentMessage.id).fetchOne(database)
            }
            expectNoDifference(message, sentMessage)
        }
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

    @Test("Voice input appends to the latest workspace prompt")
    func voiceInputAppendsToLatestPrompt() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let (transcripts, transcriptContinuation) = AsyncStream<String>.makeStream()
            let state = CreateWorkspace.State(repositories: [.preview()])
            state.$prompt.withLock { $0 = "Inspect this file." }
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.speechTranscriptionClient.startRecording = { }
                $0.speechTranscriptionClient.stopRecordingAndTranscribe = {
                    for await transcript in transcripts {
                        return transcript
                    }
                    throw CancellationError()
                }
            }

            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .startingRecording
            }
            await store.receive(\.voiceInput.recordingStarted) {
                $0.voiceInput.phase = .recording
            }
            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .transcribing
            }
            store.state.$prompt.withLock { $0 = "Inspect these files." }

            transcriptContinuation.yield("Then run the tests.")
            await store.receive(\.voiceInput.transcriptionResponse) {
                $0.$prompt.withLock {
                    $0 = "Inspect these files. Then run the tests."
                }
                $0.voiceInput.phase = .idle
            }
            await store.receive(\.voiceInput.delegate.transcriptionFinished)
            transcriptContinuation.finish()
            await store.finish()
        }
    }

    @Test("Voice input fills an empty workspace prompt")
    func voiceInputFillsEmptyPrompt() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = TestStore(
                initialState: CreateWorkspace.State(repositories: [.preview()])
            ) {
                CreateWorkspace()
            } withDependencies: {
                $0.speechTranscriptionClient.startRecording = { }
                $0.speechTranscriptionClient.stopRecordingAndTranscribe = {
                    "Run the tests."
                }
            }

            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .startingRecording
            }
            await store.receive(\.voiceInput.recordingStarted) {
                $0.voiceInput.phase = .recording
            }
            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .transcribing
            }
            await store.receive(\.voiceInput.transcriptionResponse) {
                $0.$prompt.withLock { $0 = "Run the tests." }
                $0.voiceInput.phase = .idle
            }
            await store.receive(\.voiceInput.delegate.transcriptionFinished)
        }
    }

    @Test("Voice input with no transcript preserves the workspace prompt")
    func voiceInputWithoutTranscript() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CreateWorkspace.State(repositories: [.preview()])
            state.$prompt.withLock { $0 = "Keep this prompt." }
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.speechTranscriptionClient.startRecording = { }
                $0.speechTranscriptionClient.stopRecordingAndTranscribe = { "" }
            }

            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .startingRecording
            }
            await store.receive(\.voiceInput.recordingStarted) {
                $0.voiceInput.phase = .recording
            }
            await store.send(.voiceInput(.microphoneButtonTapped)) {
                $0.voiceInput.phase = .transcribing
            }
            await store.receive(\.voiceInput.transcriptionResponse) {
                $0.voiceInput.phase = .idle
            }

            #expect(store.state.prompt == "Keep this prompt.")
        }
    }

    @Test("Leaving create workspace always cancels the shared recorder")
    func voiceInputCancellation() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let wasCancelled = LockIsolated(false)
            let store = TestStore(
                initialState: CreateWorkspace.State(repositories: [.preview()])
            ) {
                CreateWorkspace()
            } withDependencies: {
                $0.speechTranscriptionClient.cancelRecording = {
                    wasCancelled.setValue(true)
                }
            }

            await store.send(.voiceInput(.cancel))
            await store.finish()

            #expect(wasCancelled.value)
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
