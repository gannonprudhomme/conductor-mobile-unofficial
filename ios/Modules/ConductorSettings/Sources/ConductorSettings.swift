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
import Sharing
import SwiftUI

@Reducer
public struct ConductorSettings: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        @Shared(.cloudCredentialConfigured)
        public var isCloudCredentialConfigured

        @Shared(.cloudAccountID)
        public var cloudAccountID

        @Shared(.desktopDisplayConfiguration)
        public var storedDisplayConfiguration

        @Shared(.desktopServerAddress)
        public var storedServerAddress

        var connectionTestSource: ConnectionTestSource?
        var cloudOperation: CloudOperation?
        public var cloudAPIKey = ""
        public var deviceIcon: DesktopClient.DeviceIcon
        public var displayName: String
        public var initialServerAddress: String
        var isCloudConnectionTested = false
        var testedCloudAccountID: String?

        /// The server address we actually submitted & tested this session (i.e. lifetime of this view)
        ///
        /// Mostly stored to prevent us from testing the connection again when pressing the save button
        var testedServerAddress: String?

        public init() {
            @Shared(.desktopDisplayConfiguration) var storedDisplayConfiguration
            @Shared(.desktopServerAddress) var storedServerAddress
            self.deviceIcon = storedDisplayConfiguration?.icon ?? .laptop
            self.displayName = storedDisplayConfiguration?.name ?? ""
            self.initialServerAddress = storedServerAddress ?? ""
        }

        var isConnectionTestInFlight: Bool {
            connectionTestSource != nil
        }

        var isCloudOperationInFlight: Bool {
            cloudOperation != nil
        }

        var hasChanges: Bool {
            !normalizedCloudAPIKey.isEmpty
                || initialServerAddress != (storedServerAddress ?? "")
                || displayName != (storedDisplayConfiguration?.name ?? "")
                || deviceIcon != (storedDisplayConfiguration?.icon ?? .laptop)
        }

        var isSaveButtonDisabled: Bool {
            isConnectionTestInFlight || normalizedServerAddress.isEmpty
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
            isConnectionTestInFlight || normalizedServerAddress.isEmpty
        }

        var isCloudTestButtonDisabled: Bool {
            isCloudOperationInFlight
                || (normalizedCloudAPIKey.isEmpty && !isCloudCredentialConfigured)
        }

        var isCloudSaveButtonDisabled: Bool {
            isCloudOperationInFlight || normalizedCloudAPIKey.isEmpty
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
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case cloudConnectionTestResult(
            operation: State.CloudOperation,
            result: Result<CloudIdentity, any Error>
        )
        case cloudCredentialAvailabilityLoaded(Result<Bool, any Error>)
        case cloudCredentialDeleteResult(Result<Void, any Error>)
        case cloudSaveResult(
            accountID: String,
            result: Result<Void, any Error>
        )
        case connectCloudButtonTapped
        case deleteCloudCredentialButtonTapped
        case connectionTestResult(
            serverAddress: String,
            result: Result<Void, any Error>
        )
        case saveButtonTapped
        case task
        case testCloudConnectionButtonTapped
        case testButtonTapped

        public enum Alert: Equatable { }
    }

    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.cloudCredentialClient) var cloudCredentialClient
    @Dependency(\.cloudWorkspacePersistenceClient) var cloudWorkspacePersistenceClient
    @Dependency(\.dismiss) var dismiss

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                guard state.isCloudCredentialConfigured else {
                    return .none
                }
                return .run { send in
                    await send(
                        .cloudCredentialAvailabilityLoaded(
                            await Result {
                                let isConfigured = try await cloudCredentialClient
                                    .loadAPIKey() != nil
                                if !isConfigured {
                                    try await cloudWorkspacePersistenceClient
                                        .clearCachedCatalog()
                                }
                                return isConfigured
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

                if state.initialServerAddress == state.storedServerAddress
                    || state.isServerAddressConnected {
                    return save(state: &state)
                } else {
                    return testConnection(state: &state, source: .saveButtonTapped)
                }

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

            case .connectCloudButtonTapped:
                guard !state.isCloudSaveButtonDisabled else {
                    return .none
                }
                return testCloudConnection(state: &state, operation: .saving)

            case .binding(\.cloudAPIKey):
                state.isCloudConnectionTested = false
                state.testedCloudAccountID = nil
                return .none

            case let .cloudConnectionTestResult(operation, result):
                state.cloudOperation = nil
                switch result {
                case let .failure(error):
                    state.alert = .failedToConnectToCloud(error: error)
                    return .none

                case let .success(identity):
                    state.isCloudConnectionTested = true
                    state.testedCloudAccountID = identity.cacheID
                    return operation == .saving
                        ? saveCloud(state: &state)
                        : .none
                }

            case let .cloudCredentialAvailabilityLoaded(result):
                switch result {
                case let .failure(error):
                    state.alert = .failedToUpdateCloudCredential(error: error)

                case let .success(isConfigured):
                    state.$isCloudCredentialConfigured.withLock { $0 = isConfigured }
                    if !isConfigured {
                        state.$cloudAccountID.withLock { $0 = nil }
                    }
                }
                return .none

            case .deleteCloudCredentialButtonTapped:
                guard !state.isCloudOperationInFlight else {
                    return .none
                }
                state.cloudOperation = .deleting
                return .run { send in
                    await send(
                        .cloudCredentialDeleteResult(
                            await Result {
                                try await cloudCredentialClient.deleteAPIKey()
                                try await cloudWorkspacePersistenceClient.clearCachedCatalog()
                            }
                        )
                    )
                }

            case let .cloudCredentialDeleteResult(result):
                state.cloudOperation = nil
                switch result {
                case let .failure(error):
                    state.alert = .failedToUpdateCloudCredential(error: error)

                case .success:
                    state.$isCloudCredentialConfigured.withLock { $0 = false }
                    state.$cloudAccountID.withLock { $0 = nil }
                    state.cloudAPIKey = ""
                    state.isCloudConnectionTested = false
                    state.testedCloudAccountID = nil
                }
                return .none

            case let .cloudSaveResult(accountID, result):
                state.cloudOperation = nil
                switch result {
                case let .failure(error):
                    state.alert = .failedToUpdateCloudCredential(error: error)
                    return .none

                case .success:
                    state.$isCloudCredentialConfigured.withLock { $0 = true }
                    state.$cloudAccountID.withLock { $0 = accountID }
                    state.cloudAPIKey = ""
                    return .none
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
                    return source == .saveButtonTapped ? save(state: &state) : .none
                }

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

        return .run { send in
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

    private func testCloudConnection(
        state: inout State,
        operation: State.CloudOperation
    ) -> Effect<Action> {
        let cloudAPIKey = state.normalizedCloudAPIKey
        state.alert = nil
        state.cloudOperation = operation
        state.cloudAPIKey = cloudAPIKey

        return .run { send in
            let result = await Result {
                let apiKey: String
                if cloudAPIKey.isEmpty {
                    guard let storedAPIKey = try await cloudCredentialClient.loadAPIKey() else {
                        throw CloudAPIClientError.missingCredential
                    }
                    apiKey = storedAPIKey
                } else {
                    apiKey = cloudAPIKey
                }
                return try await cloudAPIClient.getIdentity(apiKey: apiKey)
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
        return .run { send in
            let result = await Result {
                if !cloudAPIKey.isEmpty {
                    try await cloudCredentialClient.saveAPIKey(apiKey: cloudAPIKey)
                }
                try await cloudWorkspacePersistenceClient.switchAccount(
                    accountID: accountID
                )
            }
            await send(.cloudSaveResult(accountID: accountID, result: result))
        }
    }

    private func save(state: inout State) -> Effect<Action> {
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
        state.$storedServerAddress.withLock { $0 = state.initialServerAddress }
        return .run { _ in
            await dismiss()
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
                isConnectionErrorPresented: store.alert != nil,
                connectionTestSource: store.connectionTestSource,
                testedServerAddress: store.testedServerAddress
            )
        )
        .interactiveDismissDisabled(store.requiresConnectionConfiguration)
        .preferredColorScheme(.dark)
        .task {
            await store.send(.task).finish()
        }
    }

    private var settings: some View {
        List {
            Section {
                connectionRow
                    .listRowBackground(Color.clear)

                displayRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .bottom)
            } header: {
                Text("Local Mac") // font 2xl (24 px)
                    .font(.theme(.heading).weight(.medium)) // need 500
                    .foregroundStyle(.theme(.textPrimary))
            }

            Section {
                cloudConnectionRow
                    .listRowBackground(Color.clear)

                if store.isCloudCredentialConfigured {
                    deleteCloudCredentialButton
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Conductor Cloud · Experimental")
                    .font(.theme(.heading).weight(.medium))
                    .foregroundStyle(.theme(.textPrimary))
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
                if store.connectionTestSource == .saveButtonTapped {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textPrimary))
                        .accessibilityLabel("Checking connection")
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

                Text(
                    store.isCloudCredentialConfigured
                        ? "A key is saved securely in Keychain. Enter a replacement or test the saved key."
                        : "Create a beta API key in Conductor Cloud, then test and save it here."
                )
                .font(.theme(.small))
                .foregroundStyle(.theme(.textSecondary))
            }
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)

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

            HStack(spacing: 8) {
                testCloudConnectionButton

                connectCloudButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deleteCloudCredentialButton: some View {
        Button(role: .destructive) {
            store.send(.deleteCloudCredentialButtonTapped)
        } label: {
            Label {
                Text("Delete saved API key")
            } icon: {
                LucideIcon(Lucide.trash2, style: .small)
            }
            .font(.theme(.body))
        }
        .disabled(store.isCloudOperationInFlight)
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
        .accessibilityIdentifier("serverAddressField")
        .keyboardType(.URL)
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

    private var connectCloudButton: some View {
        let isLoading = store.cloudOperation == .saving
        let isEnabled = !store.isCloudSaveButtonDisabled

        return Button {
            store.send(.connectCloudButtonTapped)
        } label: {
            Text(store.isCloudCredentialConfigured ? "Replace key" : "Save key")
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.background))
                    }
                }
        }
        .buttonStyle(.borderedProminent)
        .tint(.theme(.foreground))
        .foregroundStyle(.theme(.background))
        .disabled(!isEnabled)
        .accessibilityLabel(
            isLoading
                ? "Saving cloud API key"
                : store.isCloudCredentialConfigured
                    ? "Replace cloud API key"
                    : "Save cloud API key"
        )
    }

    // This modifier exists only because the compiler could not type-check all three feedbacks in `body`.
    private struct SensoryFeedbacksViewModifier: ViewModifier {
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

        private func shouldPlaySuccessFeedback(oldValue: String?, newValue: String?) -> Bool {
            newValue != nil && newValue != oldValue
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
