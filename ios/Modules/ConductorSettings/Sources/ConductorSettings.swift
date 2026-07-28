//
//  ConductorSettings.swift
//  ConductorSettings
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import SharedConductorData
import Sharing
import SwiftUI

@Reducer
public struct ConductorSettings: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        @Shared(.cloudConfiguration)
        public var cloudConfiguration

        @Shared(.desktopDisplayConfiguration)
        public var storedDisplayConfiguration

        @Shared(.desktopServerAddress)
        public var storedServerAddress

        @Shared(.mobileModelSettingsOverride)
        public var mobileModelSettingsOverride

        var connectionTestSource: ConnectionTestSource?
        public var conductorModelSettings: DesktopClient.ModelSettings?
        var cloudOperation: CloudOperation?
        var cloudConnectionTestSuccessCount = 0
        public var cloudAPIKey = ""
        public var deviceIcon: DesktopClient.DeviceIcon
        public var displayName: String
        public var draftModelSettings: DesktopClient.ModelSettings?
        public var initialServerAddress: String
        var initialModelSettings: DesktopClient.ModelSettings?
        public var isLoadingModelSettings = false
        var testedCloudAccountID: String?

        /// The server address we actually submitted & tested this session (i.e. lifetime of this view)
        ///
        /// Mostly stored to prevent us from testing the connection again when pressing the save button
        var testedServerAddress: String?

        public init() {
            @Shared(.desktopDisplayConfiguration) var storedDisplayConfiguration
            @Shared(.desktopServerAddress) var storedServerAddress
            @Shared(.mobileModelSettingsOverride) var mobileModelSettingsOverride
            let initialModelSettings =
                mobileModelSettingsOverride ?? DesktopClient.ModelSettings.conductorDefaults
            self.conductorModelSettings = .conductorDefaults
            self.deviceIcon = storedDisplayConfiguration?.icon ?? .laptop
            self.displayName = storedDisplayConfiguration?.name ?? ""
            self.draftModelSettings = initialModelSettings
            self.initialServerAddress = storedServerAddress ?? ""
            self.initialModelSettings = initialModelSettings
        }

        var isConnectionTestInFlight: Bool {
            connectionTestSource != nil
        }

        var isCloudOperationInFlight: Bool {
            cloudOperation != nil
        }

        var availableReasoningEfforts: [Session.ReasoningEffort] {
            guard let model = modelSettings?.defaultModel,
                  let agentType = model.agentType else {
                return []
            }
            return Session.availableReasoningEfforts(
                agentType: agentType,
                model: model
            )
        }

        public var isCloudCredentialConfigured: Bool {
            cloudConfiguration != nil
        }

        var isCloudConnectionTested: Bool {
            testedCloudAccountID != nil
        }

        var isSettingsSaveInFlight: Bool {
            connectionTestSource == .saveButtonTapped
                || cloudOperation == .saving
        }

        var hasChanges: Bool {
            !normalizedCloudAPIKey.isEmpty
                || initialServerAddress != (storedServerAddress ?? "")
                || displayName != (storedDisplayConfiguration?.name ?? "")
                || deviceIcon != (storedDisplayConfiguration?.icon ?? .laptop)
                || draftModelSettings != initialModelSettings
        }

        var hasDraftMobileModelSettingsOverride: Bool {
            isDefaultModelOverridden
                || isDefaultThinkingOverridden
                || isFastModeOverridden
        }

        var isDefaultModelOverridden: Bool {
            guard let draftModelSettings,
                  let conductorModelSettings else {
                return false
            }
            return draftModelSettings.defaultModel != conductorModelSettings.defaultModel
        }

        var isDefaultThinkingOverridden: Bool {
            guard let draftModelSettings,
                  let conductorModelSettings else {
                return false
            }
            return draftModelSettings.defaultReasoningEffort
                != conductorModelSettings.defaultReasoningEffort
        }

        var isFastModeOverridden: Bool {
            guard let draftModelSettings,
                  let conductorModelSettings else {
                return false
            }
            return draftModelSettings.isFastModeEnabled
                != conductorModelSettings.isFastModeEnabled
        }

        var isSaveButtonDisabled: Bool {
            isConnectionTestInFlight
                || isCloudOperationInFlight
                || (
                    normalizedServerAddress.isEmpty
                        && normalizedCloudAPIKey.isEmpty
                        && storedServerAddress == nil
                        && !isCloudCredentialConfigured
                )
        }

        public var isServerAddressMissing: Bool {
            storedServerAddress == nil
        }

        public var requiresConnectionConfiguration: Bool {
            isServerAddressMissing && !isCloudCredentialConfigured
        }

        var isServerAddressConnected: Bool {
            testedServerAddress == normalizedServerAddress
        }

        var isTestButtonDisabled: Bool {
            isConnectionTestInFlight
                || cloudOperation == .saving
                || normalizedServerAddress.isEmpty
        }

        var isCloudTestButtonDisabled: Bool {
            isCloudOperationInFlight
                || connectionTestSource == .saveButtonTapped
                || (normalizedCloudAPIKey.isEmpty && !isCloudCredentialConfigured)
        }

        var normalizedCloudAPIKey: String {
            cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var normalizedServerAddress: String {
            initialServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var normalizedDisplayName: String {
            displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var modelSettings: DesktopClient.ModelSettings? {
            draftModelSettings
        }

        func reconciledReasoningEffort(
            for model: Session.Model,
            preferredEffort: Session.ReasoningEffort
        ) -> Session.ReasoningEffort {
            guard let agentType = model.agentType else {
                return model.defaultReasoningEffort
            }
            let efforts = Session.availableReasoningEfforts(
                agentType: agentType,
                model: model
            )
            if efforts.contains(preferredEffort) {
                return preferredEffort
            }
            if efforts.contains(model.defaultReasoningEffort) {
                return model.defaultReasoningEffort
            }
            return efforts.first ?? model.defaultReasoningEffort
        }

        public enum ConnectionTestSource: Equatable, Sendable {
            case saveButtonTapped
            case testButtonTapped
        }

        public enum CloudOperation: Equatable, Sendable {
            case deleting
            case saving
            case testing
        }
    }

    public enum Action: BindableAction {
        case task
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case cloudConnectionTestResult(
            operation: State.CloudOperation,
            result: Result<CloudIdentity, any Error>
        )
        case cloudCacheCleanupResult(
            context: CloudCacheCleanupContext,
            result: Result<Void, any Error>
        )
        case cloudCredentialDeleteResult(Result<Void, any Error>)
        case cloudSaveResult(
            accountID: String,
            didReplaceCredential: Bool,
            result: Result<Void, any Error>
        )
        case deleteCloudCredentialButtonTapped
        case connectionTestResult(
            serverAddress: String,
            result: Result<Void, any Error>
        )
        case fastModeToggled(Bool)
        case modelSelected(Session.Model)
        case modelSettingsResponse(Result<DesktopClient.ModelSettings, any Error>)
        case reasoningEffortSelected(Session.ReasoningEffort)
        case resetModelSettingsButtonTapped
        case saveButtonTapped
        case testCloudConnectionButtonTapped
        case testButtonTapped

        public enum Alert: Equatable { }

        public enum CloudCacheCleanupContext: Equatable, Sendable {
            case deleting
            case saving
        }
    }

    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.cloudCredentialClient) var cloudCredentialClient
    @Dependency(\.cloudMutationRunner) var cloudMutationRunner
    @Dependency(\.cloudWorkspaceCacheClient) var cloudWorkspaceCacheClient
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                guard !state.isServerAddressMissing else {
                    return .none
                }
                state.isLoadingModelSettings = true
                return .run { send in
                    await send(
                        .modelSettingsResponse(
                            Result {
                                try await desktopClient.fetchModelSettings()
                            }
                        )
                    )
                }

            case .saveButtonTapped:
                guard !state.isSaveButtonDisabled else {
                    return .none
                }

                state.displayName = state.normalizedDisplayName
                state.initialServerAddress = state.normalizedServerAddress
                state.cloudAPIKey = state.normalizedCloudAPIKey
                return continueSaving(state: &state)

            case .testButtonTapped:
                guard !state.isTestButtonDisabled else {
                    return .none
                }

                return testConnection(state: &state, source: .testButtonTapped)

            case .testCloudConnectionButtonTapped:
                guard !state.isCloudTestButtonDisabled else {
                    return .none
                }
                return testCloudConnection(state: &state, operation: .testing)

            case .binding(\.cloudAPIKey):
                state.testedCloudAccountID = nil
                return .none

            case let .cloudConnectionTestResult(operation, result):
                state.cloudOperation = nil
                switch result {
                case let .failure(error):
                    state.alert = .failedToConnectToCloud(error: error)
                    return .none

                case let .success(identity):
                    state.cloudConnectionTestSuccessCount += 1
                    state.testedCloudAccountID = identity.cacheID
                    return operation == .saving
                        ? continueSaving(state: &state)
                        : .none
                }

            case let .cloudCacheCleanupResult(context, result):
                state.cloudOperation = nil
                switch result {
                case let .failure(error):
                    state.alert = .failedToUpdateCloudCredential(error: error)
                    if context == .saving {
                        saveLocalSettings(state: &state)
                    }
                    return .none

                case .success:
                    return context == .saving
                        ? saveLocalSettingsAndDismiss(state: &state)
                        : .none
                }

            case .deleteCloudCredentialButtonTapped:
                guard !state.isCloudOperationInFlight else {
                    return .none
                }
                state.cloudOperation = .deleting
                return .run {
                    [
                        cloudCredentialClient,
                        cloudMutationRunner,
                        configuration = state.cloudConfiguration,
                    ] send in
                    await send(
                        .cloudCredentialDeleteResult(
                            await Result {
                                if let configuration {
                                    await cloudMutationRunner.cancelAndAwait(
                                        accountID: configuration.accountID,
                                        credentialGeneration: configuration
                                            .credentialGeneration
                                    )
                                }
                                try await cloudCredentialClient.deleteAPIKey()
                            }
                        )
                    )
                }

            case let .cloudCredentialDeleteResult(result):
                switch result {
                case let .failure(error):
                    state.cloudOperation = nil
                    state.alert = .failedToUpdateCloudCredential(error: error)
                    return .none

                case .success:
                    state.$cloudConfiguration.withLock { $0 = nil }
                    state.cloudAPIKey = ""
                    state.testedCloudAccountID = nil
                    return cleanCloudCache(
                        context: .deleting,
                        keepingAccountID: nil
                    )
                }

            case let .cloudSaveResult(
                accountID,
                didReplaceCredential,
                result
            ):
                switch result {
                case let .failure(error):
                    state.cloudOperation = nil
                    state.alert = .failedToUpdateCloudCredential(error: error)
                    return .none

                case .success:
                    let credentialGeneration =
                        if !didReplaceCredential,
                           state.cloudConfiguration?.accountID == accountID,
                           let existingGeneration = state.cloudConfiguration?
                            .credentialGeneration {
                            existingGeneration
                        } else {
                            uuid()
                        }
                    state.$cloudConfiguration.withLock {
                        $0 = CloudConfiguration(
                            accountID: accountID,
                            credentialGeneration: credentialGeneration
                        )
                    }
                    state.cloudAPIKey = ""
                    return cleanCloudCache(
                        context: .saving,
                        keepingAccountID: accountID
                    )
                }

            case let .connectionTestResult(serverAddress, result):
                guard let source = state.connectionTestSource else {
                    return .none
                }

                state.connectionTestSource = nil

                switch result {
                case let .failure(error):
                    state.alert = .failedToConnect(to: serverAddress, error: error)
                    return .none

                case .success:
                    state.testedServerAddress = serverAddress
                    return source == .saveButtonTapped
                        ? persistSettings(state: &state)
                        : .none
                }

            case let .modelSettingsResponse(.success(settings)):
                state.isLoadingModelSettings = false
                let shouldApplyDesktopSettings =
                    state.mobileModelSettingsOverride == nil
                    && state.draftModelSettings == state.initialModelSettings
                state.conductorModelSettings = settings
                if shouldApplyDesktopSettings {
                    state.draftModelSettings = settings
                    state.initialModelSettings = settings
                }
                return .none

            case .modelSettingsResponse(.failure):
                state.isLoadingModelSettings = false
                return .none

            case let .modelSelected(model):
                guard var settings = state.modelSettings,
                      model.agentType != nil else {
                    return .none
                }
                settings.defaultModel = model
                settings.defaultReasoningEffort = state.reconciledReasoningEffort(
                    for: model,
                    preferredEffort: settings.defaultReasoningEffort
                )
                state.draftModelSettings = settings
                return .none

            case let .reasoningEffortSelected(reasoningEffort):
                guard var settings = state.modelSettings,
                      state.availableReasoningEfforts.contains(reasoningEffort) else {
                    return .none
                }
                settings.defaultReasoningEffort = reasoningEffort
                state.draftModelSettings = settings
                return .none

            case let .fastModeToggled(isFastModeEnabled):
                guard var settings = state.modelSettings else {
                    return .none
                }
                settings.isFastModeEnabled = isFastModeEnabled
                state.draftModelSettings = settings
                return .none

            case .resetModelSettingsButtonTapped:
                guard let conductorModelSettings = state.conductorModelSettings,
                      state.hasDraftMobileModelSettingsOverride else {
                    return .none
                }
                state.draftModelSettings = conductorModelSettings
                return .none

            case .alert, .binding:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func testConnection(
        state: inout State,
        source: State.ConnectionTestSource
    ) -> Effect<Action> {
        let serverAddress = state.normalizedServerAddress
        state.alert = nil
        state.connectionTestSource = source
        state.initialServerAddress = serverAddress

        return .run { [desktopClient] send in
            do {
                try await desktopClient.checkConnection(serverAddress: serverAddress)
                await send(
                    .connectionTestResult(
                        serverAddress: serverAddress,
                        result: .success(())
                    )
                )
            } catch {
                await send(
                    .connectionTestResult(
                        serverAddress: serverAddress,
                        result: .failure(error)
                    )
                )
            }
        }
    }

    private func continueSaving(state: inout State) -> Effect<Action> {
        if !state.normalizedCloudAPIKey.isEmpty
            && (!state.isCloudConnectionTested || state.testedCloudAccountID == nil) {
            return testCloudConnection(state: &state, operation: .saving)
        }

        if !state.normalizedServerAddress.isEmpty,
           state.normalizedServerAddress != state.storedServerAddress,
           !state.isServerAddressConnected {
            return testConnection(state: &state, source: .saveButtonTapped)
        }

        return persistSettings(state: &state)
    }

    private func persistSettings(state: inout State) -> Effect<Action> {
        if !state.normalizedCloudAPIKey.isEmpty {
            return saveCloud(state: &state)
        }

        return saveLocalSettingsAndDismiss(state: &state)
    }

    private func testCloudConnection(
        state: inout State,
        operation: State.CloudOperation
    ) -> Effect<Action> {
        let cloudAPIKey = state.normalizedCloudAPIKey
        state.alert = nil
        state.cloudOperation = operation
        state.cloudAPIKey = cloudAPIKey

        return .run { [cloudAPIClient, cloudAPIKey, operation] send in
            let result = await Result {
                if cloudAPIKey.isEmpty {
                    return try await cloudAPIClient.getIdentity()
                } else {
                    return try await cloudAPIClient.validateIdentity(
                        apiKey: cloudAPIKey
                    )
                }
            }
            await send(.cloudConnectionTestResult(operation: operation, result: result))
        }
    }

    private func saveCloud(state: inout State) -> Effect<Action> {
        let cloudAPIKey = state.normalizedCloudAPIKey
        guard let accountID = state.testedCloudAccountID else {
            return .none
        }
        state.cloudOperation = .saving
        return .run {
            [
                accountID,
                cloudAPIKey,
                cloudCredentialClient,
                cloudMutationRunner,
                configuration = state.cloudConfiguration,
            ] send in
            let didReplaceCredential = !cloudAPIKey.isEmpty
            let result = await Result {
                if didReplaceCredential {
                    if let configuration {
                        await cloudMutationRunner.cancelAndAwait(
                            accountID: configuration.accountID,
                            credentialGeneration: configuration
                                .credentialGeneration
                        )
                    }
                    try await cloudCredentialClient.saveAPIKey(apiKey: cloudAPIKey)
                }
            }
            await send(
                .cloudSaveResult(
                    accountID: accountID,
                    didReplaceCredential: didReplaceCredential,
                    result: result
                )
            )
        }
    }

    private func cleanCloudCache(
        context: Action.CloudCacheCleanupContext,
        keepingAccountID: String?
    ) -> Effect<Action> {
        .run {
            [cloudWorkspaceCacheClient, context, keepingAccountID] send in
            await send(
                .cloudCacheCleanupResult(
                    context: context,
                    result: await Result {
                        try await cloudWorkspaceCacheClient.clear(
                            keepingAccountID: keepingAccountID
                        )
                    }
                )
            )
        }
    }

    private func saveLocalSettingsAndDismiss(
        state: inout State
    ) -> Effect<Action> {
        saveLocalSettings(state: &state)
        return .run { [dismiss] _ in
            await dismiss()
        }
    }

    private func saveLocalSettings(state: inout State) {
        if state.normalizedServerAddress.isEmpty {
            state.$storedDisplayConfiguration.withLock { $0 = nil }
            state.$storedServerAddress.withLock { $0 = nil }
        } else {
            state.$storedDisplayConfiguration.withLock {
                $0 = if state.displayName.isEmpty {
                    nil
                } else {
                    DesktopClient.DisplayConfiguration(
                        name: state.displayName,
                        icon: state.deviceIcon
                    )
                }
            }
            state.$storedServerAddress.withLock {
                $0 = state.normalizedServerAddress
            }
        }
        if let draftModelSettings = state.draftModelSettings {
            state.$mobileModelSettingsOverride.withLock {
                $0 = draftModelSettings == state.conductorModelSettings
                    ? nil
                    : draftModelSettings
            }
        }
    }
}

extension AlertState where Action == ConductorSettings.Action.Alert {
    static func failedToConnect(to serverAddress: String, error: any Error) -> Self {
        AlertState {
            TextState("Failed to connect to '\(serverAddress)'")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToConnectToCloud(error: any Error) -> Self {
        AlertState {
            TextState("Failed to connect to Conductor Cloud")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToUpdateCloudCredential(error: any Error) -> Self {
        AlertState {
            TextState("Failed to update the Conductor API key")
        } message: {
            TextState(error.localizedDescription)
        }
    }
}

public struct ConductorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCloudAPIKeyFocused: Bool
    @FocusState private var isDisplayNameFocused: Bool
    @FocusState private var isServerAddressFocused: Bool
    @ScaledMetric(relativeTo: ThemeFontStyle.heading.textStyle)
    private var modelsHeaderHeight = ThemeFontStyle.heading.size + 6
    @State private var isDiscardConfirmationPresented = false
    @Bindable var store: StoreOf<ConductorSettings>

    public init(store: StoreOf<ConductorSettings>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            settings
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .modifier(
            SensoryFeedbacksViewModifier(
                cloudConnectionTestSuccessCount: store.cloudConnectionTestSuccessCount,
                cloudOperation: store.cloudOperation,
                isConnectionErrorPresented: store.alert != nil,
                connectionTestSource: store.connectionTestSource,
                testedServerAddress: store.testedServerAddress
            )
        )
        .interactiveDismissDisabled(store.requiresConnectionConfiguration || store.hasChanges)
        .preferredColorScheme(.dark)
        .task {
            await store.send(.task).finish()
        }
    }

    private var settings: some View {
        List {
            Section {
                cloudConnectionRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .bottom)
            } header: {
                Text("Conductor Cloud")
                    .font(.theme(.heading).weight(.medium))
                    .foregroundStyle(.theme(.textPrimary))
            }

            Section {
                connectionRow
                    .listRowBackground(Color.clear)

                displayRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .bottom)
            } header: {
                Text("Conductor Local") // font 2xl (24 px)
                    .font(.theme(.heading).weight(.medium)) // need 500
                    .foregroundStyle(.theme(.textPrimary))
            }
            Section {
                ModelSettingRow(
                    title: "Default model",
                    subtitle: "Model for new chats",
                    isLoading: store.isLoadingModelSettings && store.modelSettings == nil,
                    isOverridden: store.isDefaultModelOverridden
                ) {
                    modelSettingsMenu
                }
                .listRowBackground(Color.clear)

                ModelSettingRow(
                    title: "Default thinking",
                    subtitle: "Thinking level for new chats",
                    isLoading: store.isLoadingModelSettings && store.modelSettings == nil,
                    isOverridden: store.isDefaultThinkingOverridden
                ) {
                    thinkingSettingsMenu
                }
                .listRowBackground(Color.clear)

                ModelSettingRow(
                    title: "Default to fast mode",
                    subtitle: "Start new chats in fast mode",
                    isLoading: store.isLoadingModelSettings && store.modelSettings == nil,
                    isOverridden: store.isFastModeOverridden
                ) {
                    if let modelSettings = store.modelSettings {
                        Toggle(
                            "Default to fast mode",
                            isOn: Binding(
                                get: { modelSettings.isFastModeEnabled },
                                set: {
                                    store.send(
                                        .fastModeToggled($0),
                                        animation: .default
                                    )
                                }
                            )
                        )
                        .labelsHidden()
                        .tint(.theme(.accent))
                    } else {
                        Text("Unavailable")
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.textSecondary))
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden, edges: .bottom)
            } header: {
                HStack(spacing: 12) {
                    Text("Models")
                        .font(.theme(.heading).weight(.medium))
                        .foregroundStyle(.theme(.textPrimary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: modelsHeaderHeight, alignment: .leading)

                    if store.hasDraftMobileModelSettingsOverride {
                        resetModelSettingsButton
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .themedNavigationTitle("Settings", alignment: .center)
        .toolbar {
            if !store.requiresConnectionConfiguration {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        if store.hasChanges {
                            isDiscardConfirmationPresented = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(.theme(.textPrimary))
                    .confirmationDialog(
                        "Are you sure you want to discard changes?",
                        isPresented: $isDiscardConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button("Discard changes", role: .destructive) {
                            dismiss()
                        }
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if store.isSettingsSaveInFlight {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textPrimary))
                        .accessibilityLabel("Saving settings")
                } else {
                    SaveButton {
                        store.send(.saveButtonTapped)
                    }
                    .disabled(store.isSaveButtonDisabled)
                    .accessibilityLabel("Save settings")
                }
            }
        }
        .listStyle(.inset)
        .animation(.default, value: store.isServerAddressConnected)
        .animation(.default, value: store.hasDraftMobileModelSettingsOverride)
        .sensoryFeedback(
            .success,
            trigger: store.hasDraftMobileModelSettingsOverride
        ) { wasOverridden, isOverridden in
            wasOverridden && !isOverridden
        }
    }

    private var resetModelSettingsButton: some View {
        Button {
            store.send(
                .resetModelSettingsButtonTapped,
                animation: .default
            )
        } label: {
            Label {
                Text("Reset to desktop")
                    .lineLimit(1)
            } icon: {
                LucideIcon(Lucide.history, style: .small)
            }
            .labelStyle(.conductorSmall)
            .padding(.horizontal, 12)
            .frame(height: modelsHeaderHeight)
            .font(.theme(.small))
            .foregroundStyle(.theme(.textPrimary))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.theme(.border))
            }
        }
        .buttonStyle(.spring)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var modelSettingsMenu: some View {
        let selectedModel =
            store.modelSettings?.defaultModel
            ?? DesktopClient.ModelSettings.conductorDefaults.defaultModel

        return ModelMenu(
            agentType: selectedModel.agentType ?? .codex,
            allowsAgentSwitching: true,
            selectedModel: selectedModel,
            onSelect: {
                store.send(.modelSelected($0), animation: .default)
            }
        ) { model, _ in
            ModelSettingMenuLabel(
                value: store.modelSettings == nil ? nil : model.displayName
            )
        }
        .disabled(store.modelSettings == nil)
        .accessibilityLabel("Default model")
        .accessibilityValue(
            store.modelSettings?.defaultModel.displayName ?? "Unavailable"
        )
    }

    private var thinkingSettingsMenu: some View {
        ReasoningEffortMenu(
            availableEfforts: store.availableReasoningEfforts,
            selectedEffort: store.modelSettings?.defaultReasoningEffort,
            isDisabled: store.availableReasoningEfforts.isEmpty,
            onSelect: {
                store.send(
                    .reasoningEffortSelected($0),
                    animation: .default
                )
            }
        ) { effort in
            ModelSettingMenuLabel(
                value: store.availableReasoningEfforts.isEmpty
                    ? nil
                    : effort?.displayName
            )
        }
        .accessibilityLabel("Default thinking")
        .accessibilityValue(
            store.availableReasoningEfforts.isEmpty
                ? "Unavailable"
                : store.modelSettings?.defaultReasoningEffort.displayName ?? "Unavailable"
        )
    }

    private var cloudConnectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("API key")
                        .font(.theme(.small).weight(.medium))
                        .foregroundStyle(.theme(.textPrimary))

                    if store.isCloudConnectionTested {
                        LucideIcon(Lucide.circleCheck, style: .small)
                            .foregroundStyle(.theme(.success))
                            .accessibilityLabel("Connected")
                    }
                }

                Text("Enter your API key. The key is stored in the Keychain")
                    .font(.theme(.small))
                    .foregroundStyle(.theme(.textSecondary))
            }
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                SecureField(
                    "Conductor API key",
                    text: $store.cloudAPIKey,
                    prompt: Text(
                        store.isCloudCredentialConfigured
                            ? "Saved in Keychain"
                            : "API key"
                    )
                    .foregroundStyle(.theme(.textSecondary))
                )
                .textFieldStyle(
                    .conductor(
                        text: $store.cloudAPIKey,
                        isClearButtonVisible: isCloudAPIKeyFocused
                    )
                )
                .focused($isCloudAPIKeyFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .accessibilityIdentifier("cloudAPIKeyField")
                .submitLabel(.done)
                .onSubmit {
                    store.send(.testCloudConnectionButtonTapped)
                }
                .disabled(store.isCloudOperationInFlight)

                testCloudConnectionButton
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Host address") // font-sm (14pt)
                        .font(.theme(.small).weight(.medium))
                        .foregroundStyle(.theme(.textPrimary))

                    if store.isServerAddressConnected {
                        LucideIcon(Lucide.circleCheck, style: .small)
                            .foregroundStyle(.theme(.success))
                            .accessibilityLabel("Connected")
                    }
                }

                Text("Enter an IP address or Tailscale MagicDNS name. Uses port 3768 by default.")
                    .font(.theme(.small))
                    .foregroundStyle(.theme(.textSecondary))
            }
            .padding(.leading, 2) // Honestly just felt right idk why
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                ipAddressTextField

                testConnectionButton
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Host display name & icon")
                    .font(.theme(.small).weight(.medium))
                    .foregroundStyle(.theme(.textPrimary))

                Text("Shown with the connection status on the Workspaces screen.")
                    .font(.theme(.small))
                    .foregroundStyle(.theme(.textSecondary))
            }
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                deviceIconMenu

                displayNameTextField
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceIconMenu: some View {
        Menu {
            Picker("Device icon", selection: $store.deviceIcon) {
                ForEach(DesktopClient.DeviceIcon.allCases, id: \.self) { icon in
                    Label {
                        Text(icon.title)
                    } icon: {
                        ColoredMenuImage(icon.lucideImage)
                    }
                    .tag(icon)
                }
            }
        } label: {
            Label {
                Text(store.deviceIcon.title)
            } icon: {
                LucideIcon(store.deviceIcon.lucideImage, style: .small)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.conductorSecondary)
        .accessibilityLabel("Device icon")
        .accessibilityValue(store.deviceIcon.title)
    }

    private var displayNameTextField: some View {
        TextField(
            "Display name",
            text: $store.displayName,
            prompt: Text(verbatim: "MacBook Pro")
                .foregroundStyle(.theme(.textSecondary))
        )
        .textFieldStyle(
            .conductor(
                text: $store.displayName,
                isClearButtonVisible: isDisplayNameFocused
            )
        )
        .focused($isDisplayNameFocused)
        .textContentType(.name)
        .submitLabel(.done)
        .disabled(store.isConnectionTestInFlight)
    }

    private var ipAddressTextField: some View {
        TextField(
            "Server address",
            text: $store.initialServerAddress,
            prompt: Text(verbatim: "my-mac")
                .foregroundStyle(.theme(.textSecondary)) // TODO: uses text-muted-foreground
        )
        .textFieldStyle(
            .conductor(
                text: $store.initialServerAddress,
                isClearButtonVisible: isServerAddressFocused
            )
        )
        .focused($isServerAddressFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.URL)
        .keyboardType(.URL)
        .accessibilityIdentifier("serverAddressField")
        .submitLabel(.done)
        .onSubmit {
            store.send(.testButtonTapped)
        }
        .disabled(store.isConnectionTestInFlight)
    }

    private var testConnectionButton: some View {
        let isLoading = store.connectionTestSource == .testButtonTapped
        let isEnabled = !store.isTestButtonDisabled

        return Button {
            store.send(.testButtonTapped)
        } label: {
            Label {
                Text("Test")
            } icon: {
                LucideIcon(Lucide.gauge, style: .small)
            }
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textPrimary))
                }
            }
        }
        .buttonStyle(.conductorSecondary)
        .disabled(!isEnabled)
        .accessibilityLabel(isLoading ? "Testing connection" : "Test connection")
    }

    private var testCloudConnectionButton: some View {
        let isLoading = store.cloudOperation == .testing
        let isEnabled = !store.isCloudTestButtonDisabled

        return Button {
            store.send(.testCloudConnectionButtonTapped)
        } label: {
            Label {
                Text("Test")
            } icon: {
                LucideIcon(Lucide.gauge, style: .small)
            }
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textPrimary))
                }
            }
        }
        .buttonStyle(.conductorSecondary)
        .disabled(!isEnabled)
        .accessibilityLabel(isLoading ? "Testing cloud connection" : "Test cloud connection")
    }

    // This modifier exists only because the compiler could not type-check all feedbacks in `body`.
    private struct SensoryFeedbacksViewModifier: ViewModifier {
        var cloudConnectionTestSuccessCount: Int
        var cloudOperation: ConductorSettings.State.CloudOperation?
        var isConnectionErrorPresented: Bool
        var connectionTestSource: ConductorSettings.State.ConnectionTestSource?
        var testedServerAddress: String?

        func body(content: Content) -> some View {
            content
                // Whenever a connection error alert is presented.
                .sensoryFeedback(
                    .error,
                    trigger: isConnectionErrorPresented,
                    condition: shouldPlayErrorFeedback
                )
                // Whenever Save or Test is tapped and starts a connection test.
                .sensoryFeedback(
                    .selection,
                    trigger: connectionTestSource,
                    condition: shouldPlaySelectionFeedback
                )
                // Whenever a connection test succeeds.
                .sensoryFeedback(
                    .success,
                    trigger: testedServerAddress,
                    condition: shouldPlaySuccessFeedback
                )
                // Whenever an explicit Cloud Test starts.
                .sensoryFeedback(
                    .selection,
                    trigger: cloudOperation,
                    condition: shouldPlayCloudSelectionFeedback
                )
                // Whenever a Cloud connection test succeeds, including repeated tests.
                .sensoryFeedback(
                    .success,
                    trigger: cloudConnectionTestSuccessCount,
                    condition: shouldPlayCloudSuccessFeedback
                )
        }

        private func shouldPlayErrorFeedback(oldValue: Bool, newValue: Bool) -> Bool {
            !oldValue && newValue
        }

        private func shouldPlaySelectionFeedback(
            oldValue: ConductorSettings.State.ConnectionTestSource?,
            newValue: ConductorSettings.State.ConnectionTestSource?
        ) -> Bool {
            oldValue == nil && newValue != nil
        }

        private func shouldPlayCloudSelectionFeedback(
            oldValue: ConductorSettings.State.CloudOperation?,
            newValue: ConductorSettings.State.CloudOperation?
        ) -> Bool {
            oldValue == nil && newValue == .testing
        }

        private func shouldPlayCloudSuccessFeedback(
            oldValue: Int,
            newValue: Int
        ) -> Bool {
            newValue > oldValue
        }

        private func shouldPlaySuccessFeedback(oldValue: String?, newValue: String?) -> Bool {
            newValue != nil && newValue != oldValue
        }
    }
}

private struct ModelSettingMenuLabel: View {
    let value: String?

    var body: some View {
        Label {
            Text(value ?? "Unavailable")
                .lineLimit(1)
                .contentTransition(.opacity)
        } icon: {
            LucideIcon(Lucide.chevronDown, style: .small)
                .foregroundStyle(.theme(.textSecondary))
        }
        .labelStyle(.conductorSettingsMenu)
    }
}

private struct ModelSettingRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let isLoading: Bool
    let isOverridden: Bool
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        isLoading: Bool,
        isOverridden: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isLoading = isLoading
        self.isOverridden = isOverridden
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.theme(.small).weight(.medium))
                    .foregroundStyle(.theme(.textPrimary))

                Text(subtitle)
                    .font(.theme(.small))
                    .foregroundStyle(.theme(.textSecondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isOverridden {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.theme(.accent))
                        .frame(width: 2)
                        .offset(x: -8)
                }
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textPrimary))
                    .accessibilityLabel("Loading \(title.lowercased())")
            } else {
                accessory
                    .layoutPriority(1)
            }
        }
    }
}

private extension DesktopClient.DeviceIcon {
    var lucideImage: UIImage {
        switch self {
        case .desktop:
            Lucide.monitor

        case .laptop:
            Lucide.laptop

        case .server:
            Lucide.server
        }
    }

    var title: String {
        switch self {
        case .desktop:
            "Desktop"

        case .laptop:
            "Laptop"

        case .server:
            "Server"
        }
    }
}

#Preview("Settings") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            settingsPreview { _ in }
        }
}

#Preview("Connection test: 100.64.0.1 succeeds") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            settingsPreview(initialServerAddress: "100.64.0.1") { serverAddress in
                try await Task.sleep(for: .seconds(2))
                guard serverAddress == "100.64.0.1" else {
                    throw URLError(.cannotConnectToHost)
                }
            }
        }
}

@MainActor
private func settingsPreview(
    initialServerAddress: String = "",
    checkConnection: @escaping @Sendable (String) async throws -> Void
) -> some View {
    let store = withDependencies {
        $0.defaultFileStorage = .inMemory
        $0.desktopClient.checkConnection = checkConnection
    } operation: {
        var state = ConductorSettings.State()
        state.initialServerAddress = initialServerAddress
        return Store(initialState: state) {
            ConductorSettings()
        }
    }

    return ConductorSettingsView(store: store)
}
