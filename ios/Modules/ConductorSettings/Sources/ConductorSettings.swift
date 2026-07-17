//
//  ConductorSettings.swift
//  ConductorSettings
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ComposableArchitecture
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

        @Shared(.desktopDisplayConfiguration)
        public var storedDisplayConfiguration

        @Shared(.desktopServerAddress)
        public var storedServerAddress

        var connectionTestSource: ConnectionTestSource?
        public var deviceIcon: DesktopClient.DeviceIcon
        public var displayName: String
        public var initialServerAddress: String

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

        var hasChanges: Bool {
            initialServerAddress != (storedServerAddress ?? "")
                || displayName != (storedDisplayConfiguration?.name ?? "")
                || deviceIcon != (storedDisplayConfiguration?.icon ?? .laptop)
        }

        var isSaveButtonDisabled: Bool {
            isConnectionTestInFlight
                || normalizedServerAddress.isEmpty
        }

        public var isServerAddressMissing: Bool {
            storedServerAddress == nil
        }

        var isServerAddressConnected: Bool {
            testedServerAddress == normalizedServerAddress
        }

        var isTestButtonDisabled: Bool {
            isConnectionTestInFlight
                || normalizedServerAddress.isEmpty
        }

        var normalizedServerAddress: String {
            initialServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var normalizedDisplayName: String {
            displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        enum ConnectionTestSource: Equatable {
            case saveButtonTapped
            case testButtonTapped
        }
    }

    public enum Action: BindableAction {
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case connectionTestResult(
            serverAddress: String,
            result: Result<Void, any Error>
        )
        case saveButtonTapped
        case testButtonTapped

        public enum Alert: Equatable { }
    }

    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.dismiss) var dismiss

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
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
}

public struct ConductorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
        .interactiveDismissDisabled(store.isServerAddressMissing)
        .preferredColorScheme(.dark)
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
                Text("Connection") // font 2xl (24 px)
                    .font(.theme(.heading).weight(.medium)) // need 500
                    .foregroundStyle(.theme(.textPrimary))
            }
        }
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .themedNavigationTitle("Settings", alignment: .center)
        .toolbar {
            if !store.isServerAddressMissing {
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
                }
            }
        }
        .listStyle(.inset)
        .animation(.default, value: store.isServerAddressConnected)
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
