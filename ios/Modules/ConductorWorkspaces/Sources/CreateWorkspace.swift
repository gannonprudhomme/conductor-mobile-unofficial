//
//  CreateWorkspace.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorCloud
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
        @Shared(.cloudCredentialConfigured)
        public var isCloudCredentialConfigured

        public var agentType = Session.AgentType.codex
        public let cloudProjects: [CloudProject]
        public var hasUserSelectedModel = false
        public var isCreateAPIInFlight = false
        public var isCloudWorkspace = false
        public var isFastModeEnabled = false
        public let repositories: [Repository]

        @Shared(.createWorkspacePrompt)
        public var prompt

        public var selectedRepositoryID: Repository.ID
        public var selectedModel = Session.Model.gpt_5_6_sol
        var workspaceID: Workspace.ID?

        public init(
            repositories: [Repository],
            cloudProjects: [CloudProject] = [],
            selectedRepositoryIDFilter: Repository.ID? = nil
        ) {
            precondition(!repositories.isEmpty, "CreateWorkspace requires a repository")
            self.repositories = repositories
            self.cloudProjects = cloudProjects
            self.selectedRepositoryID = repositories
                .first { $0.id == selectedRepositoryIDFilter }?
                .id
                ?? repositories[0].id
        }

        var isCloudCreationAvailable: Bool {
            isCloudCredentialConfigured && cloudCreationRequest != nil
        }

        var selectedRepository: Repository? {
            repositories.first { $0.id == selectedRepositoryID }
        }

        var cloudCreationRequest: CloudCreateWorkspaceRequest? {
            guard let repository = selectedRepository else {
                return nil
            }
            if let repositoryRemote = repository.remoteURL.map(Self.normalizedGitRemote),
               let project = cloudProjects.first(where: {
                   Self.normalizedGitRemote($0.gitRemote) == repositoryRemote
               }) {
                return CloudCreateWorkspaceRequest(
                    projectID: project.id,
                    agent: agentType.rawValue,
                    model: selectedModel.rawValue
                )
            }
            guard let remote = repository.remoteURL,
                  let remoteURL = URL(string: remote),
                  remoteURL.scheme != nil
            else {
                return nil
            }
            return CloudCreateWorkspaceRequest(
                repositoryURL: remoteURL,
                agent: agentType.rawValue,
                model: selectedModel.rawValue
            )
        }

        private static func normalizedGitRemote(_ remote: String) -> String {
            let normalized = remote
                .lowercased()
                .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if normalized.hasSuffix(".git") {
                return String(normalized.dropLast(4))
            }
            return normalized
        }
    }

    public enum Action: BindableAction {
        case task
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case createButtonTapped
        case createCloudWorkspaceSucceeded(CloudWorkspaceCreationResult)
        case createWorkspaceFailed(String)
        case createWorkspaceSucceeded(CreatedWorkspace, selectedModel: Session.Model)
        case defaultModelFetched(Session.Model)
        case delegate(Delegate)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case cloudWorkspaceCreated(CloudWorkspaceCreationResult)
            case workspaceCreated(WorkspaceCreationResult)
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.cloudAPIClient) var cloudAPIClient
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
                if state.isCloudWorkspace {
                    guard let request = state.cloudCreationRequest else {
                        state.alert = .failedToCreateWorkspace(
                            message: "The selected repository is not available to Conductor Cloud."
                        )
                        return .none
                    }
                    state.isCreateAPIInFlight = true
                    return .run {
                        [prompt = state.prompt, request] send in
                        do {
                            let response = try await cloudAPIClient.createWorkspace(
                                request: request
                            )
                            await send(
                                .createCloudWorkspaceSucceeded(
                                    CloudWorkspaceCreationResult(
                                        response: response,
                                        initialPrompt: prompt.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        )
                                    )
                                )
                            )
                        } catch {
                            await send(.createWorkspaceFailed(error.localizedDescription))
                        }
                    }
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

            case .binding(\.isCloudWorkspace):
                if state.isCloudWorkspace {
                    state.isFastModeEnabled = false
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

            case let .createCloudWorkspaceSucceeded(creation):
                state.isCreateAPIInFlight = false
                state.$prompt.withLock { $0 = "" }
                return .send(.delegate(.cloudWorkspaceCreated(creation)))

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

public struct CloudWorkspaceCreationResult: Equatable, Sendable {
    public let response: CloudCreateWorkspaceResponse
    public let initialPrompt: String

    public init(
        response: CloudCreateWorkspaceResponse,
        initialPrompt: String
    ) {
        self.response = response
        self.initialPrompt = initialPrompt
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
                HStack(spacing: 12) {
                    repositoryMenu
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if store.isCloudCredentialConfigured {
                        Toggle(isOn: $store.isCloudWorkspace) {
                            HStack(spacing: 5) {
                                CloudWorkspaceIcon(size: 16)

                                Text("Cloud")
                            }
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.textPrimary))
                        }
                        .fixedSize()
                        .tint(.theme(.accent))
                        .disabled(
                            store.isCreateAPIInFlight
                                || (!store.isCloudWorkspace && !store.isCloudCreationAvailable)
                        )
                        .accessibilityHint(
                            store.isCloudCreationAvailable
                                ? "Creates this workspace in Conductor Cloud"
                                : "The selected repository is unavailable in Conductor Cloud"
                        )
                    }
                }
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
                isFastModeButtonDisabled: store.isCloudWorkspace,
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
