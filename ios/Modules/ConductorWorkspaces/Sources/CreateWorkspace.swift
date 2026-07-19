//
//  CreateWorkspace.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import LucideIcons
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI
import UIKit

@Reducer
public struct CreateWorkspace: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?
        public var agentType = Session.AgentType.codex
        public var hasUserSelectedModel = false
        public var isCreateAPIInFlight = false
        public var isFastModeEnabled = false
        public let repositories: [Repository]

        @Shared(.createWorkspacePrompt)
        public var prompt

        public var selectedRepositoryID: Repository.ID
        public var selectedModel = Session.Model.gpt_5_6_sol
        var voiceInputLevels: [Float] = []
        var voiceInputPhase = VoiceInputPhase.idle
        var workspaceID: Workspace.ID?

        public init(
            repositories: [Repository],
            selectedRepositoryIDFilter: Repository.ID? = nil
        ) {
            precondition(!repositories.isEmpty, "CreateWorkspace requires a repository")
            self.repositories = repositories
            self.selectedRepositoryID = repositories
                .first { $0.id == selectedRepositoryIDFilter }?
                .id
                ?? repositories[0].id
        }
    }

    public enum Action: BindableAction {
        case task
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case createButtonTapped
        case createWorkspaceFailed(String)
        case createWorkspaceSucceeded(CreatedWorkspace, selectedModel: Session.Model)
        case defaultModelFetched(Session.Model)
        case delegate(Delegate)
        case microphoneButtonTapped
        case speechRecordingCancelled
        case speechRecordingLevelUpdated(Float)
        case speechRecordingStarted(Result<Void, any Error>)
        case speechTranscriptionResponse(Result<String, any Error>)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case workspaceCreated(WorkspaceCreationResult)
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.speechTranscriptionClient) var speechTranscriptionClient
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    guard let model = try? await desktopClient.fetchDefaultModel() else {
                        return
                    }
                    await send(.defaultModelFetched(model))
                }

            case .createButtonTapped:
                guard !state.isCreateAPIInFlight, state.voiceInputPhase == .idle else {
                    return .none
                }
                let workspaceID = state.workspaceID ?? uuid().uuidString.lowercased()
                state.isCreateAPIInFlight = true
                state.workspaceID = workspaceID
                return .run {
                    [
                        agentType = state.agentType,
                        isFastModeEnabled = state.isFastModeEnabled,
                        model = state.selectedModel,
                        prompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        repositoryID = state.selectedRepositoryID,
                        workspaceID,
                    ] send in
                    do {
                        let createdWorkspace = try await desktopClient.createWorkspace(
                            workspaceID: workspaceID,
                            repositoryID: repositoryID,
                            agentType: agentType,
                            model: model,
                            isFastModeEnabled: isFastModeEnabled
                        )
                        try await database.write { database in
                            try Workspace.upsert { createdWorkspace.workspace }.execute(database)
                            try Session.upsert { createdWorkspace.session }.execute(database)
                        }
                        let message: Message? = if prompt.isEmpty {
                            nil
                        } else {
                            try await desktopClient.sendMessage(
                                workspaceID: createdWorkspace.workspace.id,
                                sessionID: createdWorkspace.session.id,
                                message: prompt,
                                model: model,
                                isFastModeEnabled: isFastModeEnabled
                            )
                        }
                        if let message {
                            try await database.write { database in
                                try Message.upsert { message }.execute(database)
                            }
                        }
                        await send(
                            .createWorkspaceSucceeded(
                                createdWorkspace,
                                selectedModel: model
                            )
                        )
                    } catch {
                        await send(.createWorkspaceFailed(error.localizedDescription))
                    }
                }

            case .binding(\.selectedModel):
                state.hasUserSelectedModel = true
                if let agentType = state.selectedModel.agentType {
                    state.agentType = agentType
                }
                return .none

            case let .createWorkspaceFailed(message):
                state.alert = .failedToCreateWorkspace(message: message)
                state.isCreateAPIInFlight = false
                return .none

            case let .createWorkspaceSucceeded(createdWorkspace, selectedModel):
                state.isCreateAPIInFlight = false
                state.$prompt.withLock { $0 = "" }
                let repository = state.repositories.first {
                    $0.id == createdWorkspace.workspace.repositoryID
                }
                return .send(
                    .delegate(
                        .workspaceCreated(
                            WorkspaceCreationResult(
                                selectedModel: selectedModel,
                                workspace: WorkspaceWithRepository(
                                    workspace: createdWorkspace.workspace,
                                    repository: repository
                                )
                            )
                        )
                    )
                )

            case let .defaultModelFetched(model):
                guard !state.hasUserSelectedModel else {
                    return .none
                }
                if Session.Model.models(for: .claude).contains(model) {
                    state.agentType = .claude
                    state.selectedModel = model
                } else if Session.Model.models(for: .codex).contains(model) {
                    state.agentType = .codex
                    state.selectedModel = model
                }
                return .none

            case .microphoneButtonTapped:
                guard !state.isCreateAPIInFlight else {
                    return .none
                }
                switch state.voiceInputPhase {
                case .idle:
                    state.voiceInputPhase = .startingRecording
                    state.voiceInputLevels.removeAll()
                    return .run { send in
                        do {
                            try await speechTranscriptionClient.startRecording()
                            await send(.speechRecordingStarted(.success(())))
                        } catch is CancellationError {
                            return
                        } catch {
                            await send(.speechRecordingStarted(.failure(error)))
                        }
                    }
                    .cancellable(id: CancelID.speechRecording, cancelInFlight: true)

                case .recording:
                    state.voiceInputPhase = .transcribing
                    state.voiceInputLevels.removeAll()
                    return .merge(
                        .cancel(id: CancelID.speechRecordingLevels),
                        .run { send in
                            do {
                                let transcript = try await speechTranscriptionClient
                                    .stopRecordingAndTranscribe()
                                await send(.speechTranscriptionResponse(.success(transcript)))
                            } catch is CancellationError {
                                return
                            } catch {
                                await send(.speechTranscriptionResponse(.failure(error)))
                            }
                        }
                        .cancellable(id: CancelID.speechRecording, cancelInFlight: true)
                    )

                case .startingRecording, .transcribing:
                    return .none
                }

            case .speechRecordingCancelled:
                state.voiceInputPhase = .idle
                state.voiceInputLevels.removeAll()
                return .merge(
                    .cancel(id: CancelID.speechRecording),
                    .cancel(id: CancelID.speechRecordingLevels),
                    .run { _ in
                        await speechTranscriptionClient.cancelRecording()
                    }
                )

            case let .speechRecordingLevelUpdated(level):
                guard state.voiceInputPhase == .recording else {
                    return .none
                }
                state.voiceInputLevels.append(min(max(level, 0), 1))
                if state.voiceInputLevels.count > 48 {
                    state.voiceInputLevels.removeFirst(state.voiceInputLevels.count - 48)
                }
                return .none

            case let .speechRecordingStarted(result):
                guard state.voiceInputPhase == .startingRecording else {
                    return .none
                }
                switch result {
                case .success:
                    state.voiceInputPhase = .recording
                    return .run { send in
                        for await level in speechTranscriptionClient.recordingLevels() {
                            await send(.speechRecordingLevelUpdated(level))
                        }
                    }
                    .cancellable(id: CancelID.speechRecordingLevels, cancelInFlight: true)

                case let .failure(error):
                    state.alert = .failedToTranscribeSpeech(
                        message: error.localizedDescription
                    )
                    state.voiceInputPhase = .idle
                    state.voiceInputLevels.removeAll()
                    return .none
                }

            case let .speechTranscriptionResponse(result):
                guard state.voiceInputPhase == .transcribing else {
                    return .none
                }
                state.voiceInputPhase = .idle
                state.voiceInputLevels.removeAll()
                switch result {
                case let .success(transcript):
                    guard !transcript.isEmpty else {
                        return .none
                    }
                    state.$prompt.withLock { prompt in
                        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            prompt = transcript
                        } else {
                            let separator = prompt.last?.isWhitespace == true ? "" : " "
                            prompt += separator + transcript
                        }
                    }
                    return .none

                case let .failure(error):
                    state.alert = .failedToTranscribeSpeech(
                        message: error.localizedDescription
                    )
                    return .none
                }

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

private extension CreateWorkspace {
    enum CancelID {
        case speechRecording
        case speechRecordingLevels
    }
}

public struct WorkspaceCreationResult: Equatable, Sendable {
    public let selectedModel: Session.Model
    public let workspace: WorkspaceWithRepository

    public init(
        selectedModel: Session.Model,
        workspace: WorkspaceWithRepository
    ) {
        self.selectedModel = selectedModel
        self.workspace = workspace
    }
}

extension AlertState where Action == CreateWorkspace.Action.Alert {
    static func failedToCreateWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to create workspace")
        } message: {
            TextState(message)
        }
    }

    static func failedToTranscribeSpeech(message: String) -> Self {
        AlertState {
            TextState("Failed to transcribe speech")
        } message: {
            TextState(message)
        }
    }
}

public struct CreateWorkspaceView: View {
    @Bindable var store: StoreOf<CreateWorkspace>

    public init(store: StoreOf<CreateWorkspace>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .task {
            await store.send(.task).finish()
        }
        .onDisappear {
            store.send(.speechRecordingCancelled)
        }
    }

    private var content: some View {
        promptEditor
            .padding(.horizontal, 16)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    topRow
                }
            }
            .frame(maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .background(.theme(.background))
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .bottom) {
                bottomRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .ignoresSafeArea()
            }
    }

    private var topRow: some View {
        Text(Array(repeating: "A", count: 100).joined())
            .opacity(0)
            .accessibilityHidden(true)
            .overlay {
                repositoryMenu
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private var repositoryMenu: some View {
        let selectedRepositoryName = selectedRepository?.displayName ?? store.selectedRepositoryID

        return Menu {
            RepositoryPicker(
                store.repositories,
                selection: $store.selectedRepositoryID
            )
        } label: {
            Label {
                Text(verbatim: selectedRepositoryName)

                LucideIcon(Lucide.chevronDown, style: .body)
            } icon: {
                if let selectedRepository {
                    RepositoryIcon(repository: selectedRepository, size: 20, relativeTo: .body)
                }
            }
            .labelStyle(.conductorSmall)
            .foregroundStyle(.theme(.textPrimary))
            .font(.theme(.small))
        }
        .accessibilityLabel("Repository")
        .accessibilityValue(selectedRepositoryName)
        .tint(.theme(.textPrimary))
        .disabled(store.isCreateAPIInFlight || store.voiceInputPhase != .idle)
    }

    private var promptEditor: some View {
        PromptTextView(
            text: Binding(store.$prompt),
            isEditable: !store.isCreateAPIInFlight && store.voiceInputPhase == .idle
        )
            .font(.theme(.body))
            .foregroundStyle(.theme(.textPrimary))
            .tint(.theme(.accent))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if store.prompt.isEmpty {
                    Text("What do you want to work on?")
                        .font(.theme(.body))
                        .foregroundStyle(.theme(.textSecondary))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .disabled(store.isCreateAPIInFlight || store.voiceInputPhase != .idle)
            .accessibilityLabel("Workspace prompt")
    }

    private var bottomRow: some View {
        Group {
            if store.voiceInputPhase == .idle {
                HStack(spacing: 8) {
                    ModelAndFastModeControls(
                        agentType: store.agentType,
                        allowsAgentSwitching: true,
                        isFastModeEnabled: store.isFastModeEnabled,
                        selectedModel: store.selectedModel,
                        onFastModeTapped: { store.isFastModeEnabled.toggle() },
                        onSelectModel: { store.selectedModel = $0 }
                    )
                    .tint(.theme(.textPrimary))
                    .disabled(store.isCreateAPIInFlight)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VoiceInputButton(
                        phase: store.voiceInputPhase,
                        isEnabled: !store.isCreateAPIInFlight,
                        accessibilityIdentifier: "createWorkspace.voiceInput",
                        idleAccessibilityLabel: "Record workspace prompt",
                        action: { store.send(.microphoneButtonTapped) }
                    )

                    createButton
                }
            } else {
                VoiceInputTakeover(
                    phase: store.voiceInputPhase,
                    levels: store.voiceInputLevels,
                    accessibilityIdentifier: "createWorkspace.voiceInput",
                    onStopTapped: { store.send(.microphoneButtonTapped) }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: store.voiceInputPhase)
        .padding(.top, 8)
    }

    private var createButton: some View {
        let isEnabled = !store.isCreateAPIInFlight

        return Button {
            store.send(.createButtonTapped)
        } label: {
            Text("Create")
                .opacity(store.isCreateAPIInFlight ? 0 : 1)
                .font(.theme(.body))
                .foregroundStyle(.theme(.background))
                .padding(EdgeInsets(vertical: 12, horizontal: 16))
                .glassEffect(
                    .regular
                        .tint(.theme(.foreground))
                        .interactive(isEnabled),
                    in: .rect(cornerRadius: 26)
                )
                .overlay {
                    if store.isCreateAPIInFlight {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.background))
                            .frame(width: 24, height: 24)
                    }
                }
        }
        .buttonStyle(.spring)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var selectedRepository: Repository? {
        store.repositories
            .first(where: { $0.id == store.selectedRepositoryID })
    }
}

@MainActor
private struct PromptTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        let bodyFont = UIFont(
            name: ThemeFontStyle.body.fontName,
            size: ThemeFontStyle.body.size
        ) ?? UIFont.systemFont(ofSize: ThemeFontStyle.body.size)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: bodyFont)
        textView.isEditable = isEditable
        textView.text = text
        textView.textColor = UIColor(Color.theme(.textPrimary))
        textView.tintColor = UIColor(Color.theme(.accent))
        if isEditable {
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        if textView.text != text {
            textView.text = text
        }
        textView.isEditable = isEditable
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

#Preview {
    Text("")
        .sheet(isPresented: .constant(true)) {
            CreateWorkspaceView(
                store: Store(
                    initialState: CreateWorkspace.State(
                        repositories: [.preview()]
                    )
                ) {
                    CreateWorkspace()
                }
            )
        }
        .preferredColorScheme(.dark)
}
