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

    @Test("Cloud org is the default when Cloud creation is available")
    func cloudOrganizationDefault() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let local = Repository.preview(id: "local")
            let firstCloud = Repository.preview(id: "first-cloud")
            let selectedCloud = Repository.preview(id: "selected-cloud")
            let state = CreateWorkspace.State(
                repositories: [local],
                cloudCandidates: [
                    CloudWorkspaceCreationCandidate(
                        repository: firstCloud,
                        projectID: "first-project",
                        repositoryURL: nil
                    ),
                    CloudWorkspaceCreationCandidate(
                        repository: selectedCloud,
                        projectID: "selected-project",
                        repositoryURL: nil
                    ),
                ],
                selectedRepositoryIDFilter: selectedCloud.id
            )

            expectNoDifference(state.mode, .cloud)
            expectNoDifference(state.selectedRepositoryID, selectedCloud.id)

            let localState = CreateWorkspace.State(repositories: [local])
            expectNoDifference(localState.mode, .local)
            expectNoDifference(localState.selectedRepositoryID, local.id)
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
            state.agentType = .codex
            state.isFastModeEnabled = true
            state.selectedModel = .gpt_5_6_terra
            state.selectedReasoningEffort = .ultra
            state.$prompt.withLock { $0 = "  Run the tests.  " }
            let requestLease = try makeRequestLease()
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.uuid = .incrementing
                $0.desktopClient.acquireRequestLease = { requestLease }
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
                $0.desktopClient.isRequestLeaseValid = { $0 == requestLease }
                $0.desktopClient.persistCreatedWorkspace = { created, lease in
                    #expect(lease == requestLease)
                    try await database.write { database in
                        try Workspace.upsert { created.workspace }.execute(database)
                        try Session.upsert { created.session }.execute(database)
                    }
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
                        selectedReasoningEffort: .ultra,
                        requestLease: requestLease,
                        workspace: WorkspaceWithRepository(
                            workspace: workspace,
                            repository: repository
                        )
                    )
                )
            )

            let attempt = try await database.read { database in
                try #require(
                    try MessageDeliveryAttempt.find(UUID(1))
                        .fetchOne(database)
                )
            }
            #expect(attempt.deliveryRoute == .desktop)
            #expect(attempt.deliveryState == .ready)
            #expect(
                attempt.desktopEndpoint
                    == requestLease.baseURL.absoluteString
            )
            #expect(attempt.canonicalWorkspaceID == workspace.id)
            #expect(attempt.canonicalSessionID == session.id)
            #expect(attempt.content == "Run the tests.")
            #expect(attempt.selectedModel == .gpt_5_6_terra)
            #expect(attempt.isFastModeEnabled)
            #expect(attempt.selectedReasoningEffort == .ultra)
        }
    }

    @Test("Initial prompt creation does not wait for transport")
    func initialPromptDoesNotWaitForTransport() async throws {
        let repository = Repository.preview()
        let workspaceID = UUID(0).uuidString.lowercased()
        let session = Session.preview(id: "session", workspaceID: workspaceID)
        let workspace = Workspace.preview(
            id: workspaceID,
            activeSessionID: session.id,
            repositoryID: repository.id
        )
        let database = try appDatabase()

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CreateWorkspace.State(repositories: [repository])
            state.$prompt.withLock { $0 = "Run it." }
            let requestLease = try makeRequestLease()
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.uuid = .incrementing
                $0.desktopClient.acquireRequestLease = { requestLease }
                $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                    CreatedWorkspace(workspace: workspace, session: session)
                }
                $0.desktopClient.isRequestLeaseValid = { $0 == requestLease }
                $0.desktopClient.persistCreatedWorkspace = { created, lease in
                    #expect(lease == requestLease)
                    try await database.write { database in
                        try Workspace.upsert { created.workspace }.execute(database)
                        try Session.upsert { created.session }.execute(database)
                    }
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
                        selectedModel: state.selectedModel,
                        selectedReasoningEffort: state.selectedReasoningEffort,
                        requestLease: requestLease,
                        workspace: WorkspaceWithRepository(
                            workspace: workspace,
                            repository: repository
                        )
                    )
                )
            )
            let attempt = try await database.read { database in
                try #require(
                    try MessageDeliveryAttempt.find(UUID(1))
                        .fetchOne(database)
                )
            }
            #expect(attempt.deliveryState == .ready)
            #expect(attempt.content == "Run it.")
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
            let requestLease = try makeRequestLease()
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.uuid = .incrementing
                $0.desktopClient.acquireRequestLease = { requestLease }
                $0.desktopClient.createWorkspace = { _, _, _, _, _ in
                    throw TestError()
                }
                $0.desktopClient.isRequestLeaseValid = { $0 == requestLease }
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

    @Test("Creation uses Conductor defaults before the desktop responds")
    func conductorModelDefaults() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CreateWorkspace.State(repositories: [.preview()])

            #expect(state.agentType == .claude)
            #expect(state.selectedModel == .opus5_1M)
            #expect(state.selectedReasoningEffort == .high)
            #expect(!state.isFastModeEnabled)
        }
    }

    @Test("Desktop model settings seed creation until the user makes a selection")
    func modelSettings() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let repository = Repository.preview()
            let store = TestStore(
                initialState: CreateWorkspace.State(repositories: [repository])
            ) {
                CreateWorkspace()
            } withDependencies: {
                $0.desktopClient.fetchModelSettings = {
                    DesktopClient.ModelSettings(
                        defaultModel: .sonnet5_1M,
                        defaultReasoningEffort: .extraHigh,
                        isFastModeEnabled: true
                    )
                }
            }

            await store.send(.task)
            await store.receive(\.modelSettingsFetched) {
                $0.agentType = .claude
                $0.isFastModeEnabled = true
                $0.selectedModel = .sonnet5_1M
                $0.selectedReasoningEffort = .extraHigh
            }

            await store.send(.binding(.set(\.selectedModel, .opus4_8_1M))) {
                $0.hasUserSelectedModel = true
                $0.selectedModel = .opus4_8_1M
            }
            await store.send(.binding(.set(\.selectedModel, .gpt_5_6_sol))) {
                $0.agentType = .codex
                $0.selectedModel = .gpt_5_6_sol
            }
            await store.send(.binding(.set(\.isFastModeEnabled, false))) {
                $0.hasUserSelectedFastMode = true
                $0.isFastModeEnabled = false
            }
            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: true
                    )
                )
            ) {
                $0.selectedReasoningEffort = .low
            }
        }
    }

    @Test("Reasoning effort selects values supported by the selected model")
    func reasoningEffortSelection() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = TestStore(
                initialState: CreateWorkspace.State(repositories: [.preview()])
            ) {
                CreateWorkspace()
            }

            await store.send(.reasoningEffortSelected(.medium)) {
                $0.hasUserSelectedReasoningEffort = true
                $0.selectedReasoningEffort = .medium
            }
            await store.send(.reasoningEffortSelected(.ultra))
            await store.send(.binding(.set(\.selectedModel, .gpt5_4))) {
                $0.agentType = .codex
                $0.hasUserSelectedModel = true
                $0.selectedModel = .gpt5_4
            }
            await store.send(.binding(.set(\.selectedModel, .fable5))) {
                $0.agentType = .claude
                $0.selectedModel = .fable5
            }
            await store.send(.reasoningEffortSelected(.ultracode)) {
                $0.hasUserSelectedReasoningEffort = true
                $0.selectedReasoningEffort = .ultracode
            }
        }
    }

    @Test("Creation uses a saved mobile override before the desktop responds")
    func offlineMobileModelSettingsOverride() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.mobileModelSettingsOverride) var mobileModelSettingsOverride
            $mobileModelSettingsOverride.withLock {
                $0 = DesktopClient.ModelSettings(
                    defaultModel: .gpt_5_6_terra,
                    defaultReasoningEffort: .ultra,
                    isFastModeEnabled: true
                )
            }

            let state = CreateWorkspace.State(repositories: [.preview()])

            #expect(state.agentType == .codex)
            #expect(state.selectedModel == .gpt_5_6_terra)
            #expect(state.selectedReasoningEffort == .ultra)
            #expect(state.isFastModeEnabled)
        }
    }

    @Test("Mobile model settings override Conductor defaults")
    func mobileModelSettingsOverride() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = CreateWorkspace.State(repositories: [.preview()])
            state.$mobileModelSettingsOverride.withLock {
                $0 = DesktopClient.ModelSettings(
                    defaultModel: .fable5,
                    defaultReasoningEffort: .ultracode,
                    isFastModeEnabled: true
                )
            }
            let store = TestStore(initialState: state) {
                CreateWorkspace()
            }

            await store.send(
                .modelSettingsFetched(
                    DesktopClient.ModelSettings(
                        defaultModel: .gpt_5_6_sol,
                        defaultReasoningEffort: .low,
                        isFastModeEnabled: false
                    )
                )
            ) {
                $0.agentType = .claude
                $0.isFastModeEnabled = true
                $0.selectedModel = .fable5
                $0.selectedReasoningEffort = .ultracode
            }
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

private func makeRequestLease() throws -> DesktopRequestLease {
    DesktopRequestLease(
        baseURL: try #require(URL(string: "http://desktop:3768")),
        endpointEpoch: 1
    )
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
