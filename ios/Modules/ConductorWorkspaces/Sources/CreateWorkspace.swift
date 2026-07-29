//
//  CreateWorkspace.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import Foundation
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
        public var mode: Mode
        public let repositories: [Repository]
        public let cloudCandidates: [CloudWorkspaceCreationCandidate]

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
            if mode == .cloud {
                return CloudCreationConfigurationCatalog.configurations
                    .first(where: { $0.model == selectedModel })?
                    .efforts
                    ?? []
            }
            return Session.availableReasoningEfforts(
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
            cloudCandidates: [CloudWorkspaceCreationCandidate] = [],
            selectedRepositoryIDFilter: Repository.ID? = nil
        ) {
            precondition(
                !repositories.isEmpty || !cloudCandidates.isEmpty,
                "CreateWorkspace requires a local or Cloud repository"
            )
            self.repositories = repositories
            self.cloudCandidates = cloudCandidates
            self.mode = repositories.isEmpty ? .cloud : .local
            self.selectedRepositoryID = repositories
                .first { $0.id == selectedRepositoryIDFilter }?.id
                ?? repositories.first?.id
                ?? cloudCandidates[0].id
            let modelSettings =
                mobileModelSettingsOverride ?? DesktopClient.ModelSettings.conductorDefaults
            if let agentType = modelSettings.defaultModel.agentType {
                self.agentType = agentType
                self.selectedModel = modelSettings.defaultModel
                self.selectedReasoningEffort = modelSettings.defaultReasoningEffort
                self.isFastModeEnabled = modelSettings.isFastModeEnabled
                self.reconcileSelectedReasoningEffort()
            }
            if mode == .cloud {
                self.applyCloudConfigurationDefault()
            }
        }

        mutating func applyCloudConfigurationDefault() {
            let configuration = CloudCreationConfigurationCatalog.configurations
                .first(where: {
                    $0.model == selectedModel
                        && selectedReasoningEffort.map(
                            $0.efforts.contains
                        ) != false
                })
                ?? CloudCreationConfigurationCatalog.defaultConfiguration
            agentType = configuration.agent
            selectedModel = configuration.model
            selectedReasoningEffort = selectedReasoningEffort.flatMap {
                configuration.efforts.contains($0) ? $0 : nil
            } ?? configuration.efforts.first
            isFastModeEnabled = false
        }

        var displayedRepositories: [Repository] {
            switch mode {
            case .local:
                repositories
            case .cloud:
                cloudCandidates.map(\.repository)
            }
        }
    }

    public enum Mode: Equatable, Sendable {
        case local
        case cloud
    }

    public enum Action: BindableAction {
        case task
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case createButtonTapped
        /// Clears in-flight UI when the desktop address changed during creation.
        case createWorkspaceDiscardedForStaleEndpoint
        case createWorkspaceFailed(String)
        case createWorkspaceSucceeded(
            CreatedWorkspace,
            selectedModel: Session.Model,
            selectedReasoningEffort: Session.ReasoningEffort?,
            requestLease: DesktopRequestLease,
            initialPrompt: WorkspaceCreationResult.InitialPrompt?
        )
        case modelSettingsFetched(DesktopClient.ModelSettings)
        case modeSelected(Mode)
        case reasoningEffortSelected(Session.ReasoningEffort)
        case delegate(Delegate)

        public enum Alert: Equatable {}

        public enum Delegate: Equatable {
            case cloudWorkspaceSubmitted(CloudWorkspaceCreationForm)
            case workspaceCreated(WorkspaceCreationResult)
        }
    }

    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                guard state.mode == .local else {
                    return .none
                }
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
                if state.mode == .cloud {
                    guard let candidate = state.cloudCandidates.first(
                        where: { $0.id == state.selectedRepositoryID }
                    ) else {
                        return .none
                    }
                    return .send(
                        .delegate(
                            .cloudWorkspaceSubmitted(
                                CloudWorkspaceCreationForm(
                                    candidate: candidate,
                                    prompt: state.prompt
                                        .trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ),
                                    selectedModel: state.selectedModel,
                                    selectedReasoningEffort:
                                        state.selectedReasoningEffort
                                )
                            )
                        )
                    )
                }
                let workspaceID = state.workspaceID ?? uuid().uuidString.lowercased()
                let prompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                let promptMessageID = prompt.isEmpty ? nil : uuid()
                state.isCreateAPIInFlight = true
                state.workspaceID = workspaceID
                return .run {
                    [
                        agentType = state.agentType,
                        isFastModeEnabled = state.isFastModeEnabled,
                        model = state.selectedModel,
                        prompt,
                        promptMessageID,
                        repositoryID = state.selectedRepositoryID,
                        reasoningEffort = state.selectedReasoningEffort,
                        workspaceID,
                    ] send in
                    do {
                        // Workspace creation and optional prompt delivery are one endpoint-pinned
                        // workflow. The lease prevents any obsolete-address result from entering the
                        // durable cache or navigation state after Settings changes the address.
                        let requestLease = try desktopClient.acquireRequestLease()
                        let createdWorkspace = try await DesktopRequestLeaseContext.$current
                            .withValue(requestLease) {
                                try await desktopClient.createWorkspace(
                                    workspaceID: workspaceID,
                                    repositoryID: repositoryID,
                                    agentType: agentType,
                                    model: model,
                                    isFastModeEnabled: isFastModeEnabled
                                )
                            }
                        let initialPrompt: WorkspaceCreationResult.InitialPrompt?
                        if let promptMessageID {
                            let result: MessageDeliveryResult
                            do {
                                result = try await DesktopRequestLeaseContext.$current
                                    .withValue(requestLease) {
                                        try await desktopClient.sendMessage(
                                            workspaceID: createdWorkspace.workspace.id,
                                            sessionID: createdWorkspace.session.id,
                                            message: prompt,
                                            model: model,
                                            isFastModeEnabled: isFastModeEnabled,
                                            mode: .sent,
                                            reasoningEffort: reasoningEffort,
                                            attemptID: promptMessageID
                                        )
                                    }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch DesktopClientError.staleRequestLease {
                                throw DesktopClientError.staleRequestLease
                            } catch {
                                result = .unknown(
                                    reason: "Prompt delivery could not be determined."
                                )
                            }
                            initialPrompt = WorkspaceCreationResult.InitialPrompt(
                                attemptID: promptMessageID,
                                content: prompt,
                                deliveryResult: result
                            )
                        } else {
                            initialPrompt = nil
                        }
                        try await desktopClient.persistCreatedWorkspace(
                            createdWorkspace: createdWorkspace,
                            requestLease: requestLease
                        )
                        await send(
                            .createWorkspaceSucceeded(
                                createdWorkspace,
                                selectedModel: model,
                                selectedReasoningEffort: reasoningEffort,
                                requestLease: requestLease,
                                initialPrompt: initialPrompt
                            )
                        )
                    } catch is CancellationError {
                        return
                    } catch DesktopClientError.staleRequestLease {
                        await send(.createWorkspaceDiscardedForStaleEndpoint)
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
                selectedReasoningEffort,
                requestLease,
                initialPrompt
            ):
                guard desktopClient.isRequestLeaseValid(lease: requestLease) else {
                    state.isCreateAPIInFlight = false
                    return .none
                }
                state.isCreateAPIInFlight = false
                state.$prompt.withLock { $0 = "" }
                let repository = state.repositories.first {
                    $0.id == createdWorkspace.workspace.repositoryID
                }
                return .send(
                    .delegate(
                        .workspaceCreated(
                            WorkspaceCreationResult(
                                initialPrompt: initialPrompt,
                                selectedModel: selectedModel,
                                selectedReasoningEffort: selectedReasoningEffort,
                                requestLease: requestLease,
                                workspace: WorkspaceWithRepository(
                                    workspace: createdWorkspace.workspace,
                                    repository: repository
                                )
                            )
                        )
                    )
                )

            case .createWorkspaceDiscardedForStaleEndpoint:
                state.isCreateAPIInFlight = false
                return .none

            case let .modelSettingsFetched(settings):
                guard state.mode == .local else {
                    return .none
                }
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

            case let .modeSelected(mode):
                guard state.mode != mode else {
                    return .none
                }
                state.mode = mode
                switch mode {
                case .local:
                    guard let repository = state.repositories.first else {
                        return .none
                    }
                    state.selectedRepositoryID = repository.id
                    return .send(.task)

                case .cloud:
                    guard let candidate = state.cloudCandidates.first else {
                        return .none
                    }
                    state.selectedRepositoryID = candidate.id
                    state.applyCloudConfigurationDefault()
                    return .none
                }

            case .alert, .binding, .delegate:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

public struct CloudWorkspaceCreationForm: Equatable, Sendable {
    public let candidate: CloudWorkspaceCreationCandidate
    public let prompt: String
    public let selectedModel: Session.Model
    public let selectedReasoningEffort: Session.ReasoningEffort?

    public init(
        candidate: CloudWorkspaceCreationCandidate,
        prompt: String,
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort?
    ) {
        self.candidate = candidate
        self.prompt = prompt
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
    }
}

/// The fully reconciled result handed from `CreateWorkspace` to its parent features.
///
/// `Workspaces` inserts the new item into navigation state, while `Main` uses the same value to
/// open chat and optionally surface an uncertain initial-prompt delivery. Local results carry a
/// request lease so consumers can reject them if Settings changed desktops after the child reducer
/// emitted them; Cloud results are account-scoped and do not need a desktop lease.
public struct WorkspaceCreationResult: Equatable, Sendable {
    public let completionID: UUID?
    public let initialPrompt: InitialPrompt?
    public let selectedModel: Session.Model
    public let selectedReasoningEffort: Session.ReasoningEffort?
    /// Endpoint identity on which local creation and its atomic persistence completed.
    public let requestLease: DesktopRequestLease?
    public let selectedSessionID: Session.ID?
    public let workspace: WorkspaceWithRepository

    /// Packages creation state for the parent delegate action after persistence has succeeded.
    public init(
        initialPrompt: InitialPrompt? = nil,
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort? = nil,
        requestLease: DesktopRequestLease? = nil,
        workspace: WorkspaceWithRepository,
        selectedSessionID: Session.ID? = nil,
        completionID: UUID? = nil
    ) {
        self.completionID = completionID
        self.initialPrompt = initialPrompt
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.requestLease = requestLease
        self.selectedSessionID = selectedSessionID
        self.workspace = workspace
    }

    public struct InitialPrompt: Equatable, Sendable {
        public let attemptID: UUID
        public let content: String
        public let deliveryResult: MessageDeliveryResult

        public init(
            attemptID: UUID,
            content: String,
            deliveryResult: MessageDeliveryResult
        ) {
            self.attemptID = attemptID
            self.content = content
            self.deliveryResult = deliveryResult
        }
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
        VStack(spacing: 0) {
            if !store.repositories.isEmpty,
               !store.cloudCandidates.isEmpty {
                Picker(
                    "Workspace location",
                    selection: Binding(
                        get: { store.mode },
                        set: { store.send(.modeSelected($0)) }
                    )
                ) {
                    Text("Local").tag(CreateWorkspace.Mode.local)
                    Text("Cloud").tag(CreateWorkspace.Mode.cloud)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
            }

            promptEditor
        }
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
                store.displayedRepositories,
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
                allowedModels: store.mode == .cloud
                    ? Set(
                        CloudCreationConfigurationCatalog.configurations
                            .map(\.model)
                    )
                    : nil,
                availableReasoningEfforts: store.availableReasoningEfforts,
                isFastModeEnabled: store.isFastModeEnabled,
                showsFastMode: store.mode == .local,
                selectedModel: store.selectedModel,
                selectedReasoningEffort: store.selectedReasoningEffort,
                onFastModeTapped: {
                    if store.mode == .local {
                        store.isFastModeEnabled.toggle()
                    }
                },
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
        .accessibilityIdentifier("create-workspace.submit")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var selectedRepository: Repository? {
        store.repositories
            .first(where: { $0.id == store.selectedRepositoryID })
            ?? store.cloudCandidates
            .map(\.repository)
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
