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
        public var agentType = Session.AgentType.claude
        public var hasUserSelectedFastMode = false
        public var hasUserSelectedModel = false
        public var hasUserSelectedReasoningEffort = false
        public var isCreateAPIInFlight = false
        public var isFastModeEnabled = false
        public let repositories: [Repository]

        @Shared(.createWorkspacePrompt)
        public var prompt

        @Shared(.mobileModelSettingsOverride)
        var mobileModelSettingsOverride

        public var selectedRepositoryID: Repository.ID
        public var selectedModel = DesktopClient.ModelSettings.conductorDefaults.defaultModel
        public var selectedReasoningEffort: Session.ReasoningEffort? =
            DesktopClient.ModelSettings.conductorDefaults.defaultReasoningEffort
        var workspaceID: Workspace.ID?

        var availableReasoningEfforts: [Session.ReasoningEffort] {
            Session.availableReasoningEfforts(
                agentType: agentType,
                model: selectedModel
            )
        }

        mutating func reconcileSelectedReasoningEffort() {
            let efforts = availableReasoningEfforts
            guard let selectedReasoningEffort,
                  efforts.contains(selectedReasoningEffort) else {
                selectedReasoningEffort = efforts.contains(selectedModel.defaultReasoningEffort)
                    ? selectedModel.defaultReasoningEffort
                    : efforts.first
                return
            }
        }

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
            let modelSettings =
                mobileModelSettingsOverride ?? DesktopClient.ModelSettings.conductorDefaults
            if let agentType = modelSettings.defaultModel.agentType {
                self.agentType = agentType
                self.selectedModel = modelSettings.defaultModel
                self.selectedReasoningEffort = modelSettings.defaultReasoningEffort
                self.isFastModeEnabled = modelSettings.isFastModeEnabled
                self.reconcileSelectedReasoningEffort()
            }
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
            selectedReasoningEffort: Session.ReasoningEffort?
        )
        case modelSettingsFetched(DesktopClient.ModelSettings)
        case reasoningEffortSelected(Session.ReasoningEffort)
        case delegate(Delegate)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case workspaceCreated(WorkspaceCreationResult)
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    guard let settings = try? await desktopClient.fetchModelSettings() else {
                        return
                    }
                    await send(.modelSettingsFetched(settings))
                }

            case .createButtonTapped:
                guard !state.isCreateAPIInFlight else {
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
                        reasoningEffort = state.selectedReasoningEffort,
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
                                isFastModeEnabled: isFastModeEnabled,
                                reasoningEffort: reasoningEffort
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
                                selectedModel: model,
                                selectedReasoningEffort: reasoningEffort
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
                state.reconcileSelectedReasoningEffort()
                return .none

            case let .reasoningEffortSelected(reasoningEffort):
                guard state.availableReasoningEfforts.contains(reasoningEffort) else {
                    return .none
                }
                state.hasUserSelectedReasoningEffort = true
                state.selectedReasoningEffort = reasoningEffort
                return .none

            case .binding(\.isFastModeEnabled):
                state.hasUserSelectedFastMode = true
                return .none

            case let .createWorkspaceFailed(message):
                state.alert = .failedToCreateWorkspace(message: message)
                state.isCreateAPIInFlight = false
                return .none

            case let .createWorkspaceSucceeded(
                createdWorkspace,
                selectedModel,
                selectedReasoningEffort
            ):
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
                                selectedReasoningEffort: selectedReasoningEffort,
                                workspace: WorkspaceWithRepository(
                                    workspace: createdWorkspace.workspace,
                                    repository: repository
                                )
                            )
                        )
                    )
                )

            case let .modelSettingsFetched(settings):
                let settings = state.mobileModelSettingsOverride ?? settings
                if !state.hasUserSelectedModel {
                    let model = settings.defaultModel
                    if Session.Model.models(for: .claude).contains(model) {
                        state.agentType = .claude
                        state.selectedModel = model
                    } else if Session.Model.models(for: .codex).contains(model) {
                        state.agentType = .codex
                        state.selectedModel = model
                    }
                }
                if !state.hasUserSelectedFastMode {
                    state.isFastModeEnabled = settings.isFastModeEnabled
                }
                if !state.hasUserSelectedReasoningEffort {
                    state.selectedReasoningEffort = settings.defaultReasoningEffort
                }
                state.reconcileSelectedReasoningEffort()
                return .none

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

public struct WorkspaceCreationResult: Equatable, Sendable {
    public let selectedModel: Session.Model
    public let selectedReasoningEffort: Session.ReasoningEffort?
    public let workspace: WorkspaceWithRepository

    public init(
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort? = nil,
        workspace: WorkspaceWithRepository
    ) {
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
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
                availableReasoningEfforts: store.availableReasoningEfforts,
                isFastModeEnabled: store.isFastModeEnabled,
                selectedModel: store.selectedModel,
                selectedReasoningEffort: store.selectedReasoningEffort,
                onFastModeTapped: { store.isFastModeEnabled.toggle() },
                onSelectReasoningEffort: {
                    store.send(.reasoningEffortSelected($0))
                },
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
