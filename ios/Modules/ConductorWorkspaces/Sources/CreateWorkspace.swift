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

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
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
}

public struct CreateWorkspaceView: View {
    @Bindable var store: StoreOf<CreateWorkspace>
    @FocusState private var isPromptFocused: Bool

    public init(store: StoreOf<CreateWorkspace>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
        }
        .alert($store.scope(state: \.alert, action: \.alert))
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
            .presentationDetents([.medium, .large])
            .safeAreaBar(edge: .bottom) {
                bottomRow
                    .padding(.horizontal, 24)
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
        TextEditor(text: Binding(store.$prompt))
            .scrollContentBackground(.hidden)
            .font(.theme(.body))
            .foregroundStyle(.theme(.textPrimary))
            .tint(.theme(.accent))
            .focused($isPromptFocused)
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
            .task {
                await Task.yield()
                isPromptFocused = true
            }
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
