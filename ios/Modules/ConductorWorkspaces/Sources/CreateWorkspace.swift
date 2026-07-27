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
import Logging
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

        @Shared var outbox: MessageOutbox

        @Shared(.createWorkspacePrompt)
        public var prompt

        public var selectedRepositoryID: Repository.ID
        public var selectedModel = Session.Model.gpt_5_6_sol
        var workspaceID: Workspace.ID?

        public init(
            repositories: [Repository],
            selectedRepositoryIDFilter: Repository.ID? = nil,
            outbox: Shared<MessageOutbox> = Shared(.messageOutbox)
        ) {
            precondition(!repositories.isEmpty, "CreateWorkspace requires a repository")
            self._outbox = outbox
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
        case createWorkspaceSucceeded(
            CreatedWorkspace,
            selectedModel: Session.Model,
            promptFailureMessage: String?
        )
        case defaultModelFetched(Session.Model)
        case delegate(Delegate)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case workspaceCreated(WorkspaceCreationResult)
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date.now) var now
    @Dependency(\.desktopClient) var desktopClient
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
                guard !state.isCreateAPIInFlight else {
                    return .none
                }
                let workspaceID = state.workspaceID ?? uuid().uuidString.lowercased()
                let rawPrompt = state.prompt
                let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty,
                   let error = state.$outbox.loadError ?? state.$outbox.saveError {
                    state.alert = .failedToSavePrompt(message: error.localizedDescription)
                    return .none
                }
                let promptBubbleID = prompt.isEmpty ? nil : uuid()
                let promptAttemptID = prompt.isEmpty ? nil : uuid()
                let promptCreatedAt = prompt.isEmpty ? nil : now
                state.isCreateAPIInFlight = true
                state.workspaceID = workspaceID
                return .run {
                    [
                        agentType = state.agentType,
                        isFastModeEnabled = state.isFastModeEnabled,
                        model = state.selectedModel,
                        outbox = state.$outbox,
                        prompt,
                        promptAttemptID,
                        promptBubbleID,
                        promptCreatedAt,
                        promptDraft = state.$prompt,
                        rawPrompt,
                        repositoryID = state.selectedRepositoryID,
                        workspaceID,
                    ] send in
                    let createdWorkspace: CreatedWorkspace
                    do {
                        createdWorkspace = try await desktopClient.createWorkspace(
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
                    } catch {
                        await send(.createWorkspaceFailed(error.localizedDescription))
                        return
                    }

                    var promptFailureMessage: String?
                    if let promptBubbleID, let promptAttemptID, let promptCreatedAt {
                        do {
                            try await sendPrompt(
                                rawPrompt: rawPrompt,
                                content: prompt,
                                bubbleID: promptBubbleID,
                                attemptID: promptAttemptID,
                                createdAt: promptCreatedAt,
                                createdWorkspace: createdWorkspace,
                                model: model,
                                isFastModeEnabled: isFastModeEnabled,
                                promptDraft: promptDraft,
                                outbox: outbox
                            )
                        } catch {
                            promptFailureMessage = error.localizedDescription
                        }
                    } else {
                        promptDraft.withLock { promptDraft in
                            if promptDraft == rawPrompt {
                                promptDraft = ""
                            }
                        }
                    }
                    await send(
                        .createWorkspaceSucceeded(
                            createdWorkspace,
                            selectedModel: model,
                            promptFailureMessage: promptFailureMessage
                        )
                    )
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

            case let .createWorkspaceSucceeded(
                createdWorkspace,
                selectedModel,
                promptFailureMessage
            ):
                state.isCreateAPIInFlight = false
                let repository = state.repositories.first {
                    $0.id == createdWorkspace.workspace.repositoryID
                }
                return .send(
                    .delegate(
                        .workspaceCreated(
                            WorkspaceCreationResult(
                                promptFailureMessage: promptFailureMessage,
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

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func sendPrompt(
        rawPrompt: String,
        content: String,
        bubbleID: UUID,
        attemptID: UUID,
        createdAt: Date,
        createdWorkspace: CreatedWorkspace,
        model: Session.Model,
        isFastModeEnabled: Bool,
        promptDraft: Shared<String>,
        outbox: Shared<MessageOutbox>
    ) async throws {
        if let error = outbox.loadError {
            throw error
        }
        let workspaceID = createdWorkspace.workspace.id
        let sessionID = createdWorkspace.session.id
        let bubble = MessageOutbox.Bubble(
            bubbleID: bubbleID,
            content: content,
            createdAt: createdAt,
            isFastModeEnabled: isFastModeEnabled,
            model: model,
            attempts: [
                .init(attemptID: attemptID, state: .sending),
            ]
        )
        outbox.withLock { outbox in
            var bubbles = outbox[workspaceID, sessionID]
            bubbles.append(bubble)
            outbox[workspaceID, sessionID] = bubbles
        }
        do {
            try await outbox.save()
        } catch {
            outbox.withLock { outbox in
                var bubbles = outbox[workspaceID, sessionID]
                bubbles.removeAll { $0.bubbleID == bubbleID }
                outbox[workspaceID, sessionID] = bubbles
            }
            throw error
        }

        let shouldSend = outbox.withLock { outbox in
            outbox[workspaceID, sessionID].contains { bubble in
                bubble.bubbleID == bubbleID
                    && bubble.attempts.contains {
                        $0.attemptID == attemptID && $0.state == .sending
                    }
            }
        }
        guard shouldSend else {
            return
        }
        promptDraft.withLock { promptDraft in
            if promptDraft == rawPrompt {
                promptDraft = ""
            }
        }
        let result = await desktopClient.sendMessage(
            workspaceID: workspaceID,
            sessionID: sessionID,
            message: content,
            model: model,
            isFastModeEnabled: isFastModeEnabled,
            attemptID: attemptID
        )
        outbox.withLock { outbox in
            var bubbles = outbox[workspaceID, sessionID]
            let bubbleIndex = bubbles.firstIndex {
                $0.bubbleID == bubbleID
            }
            guard let bubbleIndex else {
                return
            }
            let attemptIndex = bubbles[bubbleIndex].attempts.firstIndex {
                $0.attemptID == attemptID && $0.state == .sending
            }
            guard let attemptIndex else {
                return
            }
            bubbles[bubbleIndex].attempts[attemptIndex].state = switch result {
            case .accepted(let messageID):
                .accepted(messageID: messageID)
            case .rejected:
                .rejected
            case .unknown:
                .unknown
            }
            outbox[workspaceID, sessionID] = bubbles
        }
        do {
            try await outbox.save()
        } catch {
            // The stronger evidence remains in shared memory and blocks sends until a save works.
            Logger.workspace.error("Failed to save creation prompt delivery: \(error)")
        }
    }
}

public struct WorkspaceCreationResult: Equatable, Sendable {
    public let promptFailureMessage: String?
    public let selectedModel: Session.Model
    public let workspace: WorkspaceWithRepository

    public init(
        promptFailureMessage: String? = nil,
        selectedModel: Session.Model,
        workspace: WorkspaceWithRepository
    ) {
        self.promptFailureMessage = promptFailureMessage
        self.selectedModel = selectedModel
        self.workspace = workspace
    }
}

extension AlertState where Action == CreateWorkspace.Action.Alert {
    static func failedToSavePrompt(message: String) -> Self {
        AlertState {
            TextState("Message outbox unavailable")
        } message: {
            TextState(message)
        }
    }

    static func failedToCreateWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to create workspace")
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
        .disabled(store.isCreateAPIInFlight)
    }

    private var promptEditor: some View {
        PromptTextView(
            text: Binding(store.$prompt),
            isEditable: !store.isCreateAPIInFlight
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
            .disabled(store.isCreateAPIInFlight)
            .accessibilityLabel("Workspace prompt")
    }

    private var bottomRow: some View {
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

            createButton
        }
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
