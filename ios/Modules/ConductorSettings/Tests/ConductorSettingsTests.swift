//
//  ConductorSettingsTests.swift
//  ConductorSettingsTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import CustomDump
import Dependencies
@testable import ConductorSettings
import Foundation
import SharedConductorData
import Testing

@MainActor
struct ConductorSettingsTests {
    @Test("Settings starts with Conductor defaults before connecting")
    func conductorModelDefaults() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = ConductorSettings.State()

            expectNoDifference(
                state.modelSettings,
                DesktopClient.ModelSettings.conductorDefaults
            )
            expectNoDifference(
                state.conductorModelSettings,
                DesktopClient.ModelSettings.conductorDefaults
            )
            #expect(!state.hasChanges)
            #expect(!state.hasDraftMobileModelSettingsOverride)
        }
    }

    @Test("Settings loads the desktop model defaults")
    func modelSettings() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let state = ConductorSettings.State()
            state.$storedServerAddress.withLock { $0 = "my-mac" }
            let settings = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .high,
                isFastModeEnabled: true
            )
            let store = TestStore(initialState: state) {
                ConductorSettings()
            } withDependencies: {
                $0.desktopClient.fetchModelSettings = { settings }
            }

            await store.send(.task) {
                $0.isLoadingModelSettings = true
            }
            await store.receive(\.modelSettingsResponse.success) {
                $0.isLoadingModelSettings = false
                $0.conductorModelSettings = settings
                $0.draftModelSettings = settings
                $0.initialModelSettings = settings
            }
        }
    }

    @Test("Desktop defaults do not replace model edits made while loading")
    func modelSettingsPreserveDraftEdits() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }
            let desktopSettings = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .low,
                isFastModeEnabled: false
            )

            await store.send(.modelSelected(.sonnet5_1M)) {
                $0.draftModelSettings?.defaultModel = .sonnet5_1M
            }
            await store.send(.modelSettingsResponse(.success(desktopSettings))) {
                $0.conductorModelSettings = desktopSettings
            }

            #expect(store.state.modelSettings?.defaultModel == .sonnet5_1M)
            #expect(store.state.isDefaultModelOverridden)
        }
    }

    @Test("Mobile model overrides stay drafted until Save")
    func mobileModelSettingsOverride() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.dismiss = DismissEffect { }
        } operation: {
            let conductorSettings = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .ultra,
                isFastModeEnabled: false
            )
            var state = ConductorSettings.State()
            state.initialServerAddress = "my-mac"
            state.$storedServerAddress.withLock { $0 = "my-mac" }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.modelSettingsResponse(.success(conductorSettings))) {
                $0.conductorModelSettings = conductorSettings
                $0.draftModelSettings = conductorSettings
                $0.initialModelSettings = conductorSettings
            }
            await store.send(.modelSelected(.fable5)) {
                $0.draftModelSettings = DesktopClient.ModelSettings(
                    defaultModel: .fable5,
                    defaultReasoningEffort: .high,
                    isFastModeEnabled: false
                )
            }
            await store.send(.reasoningEffortSelected(.max)) {
                $0.draftModelSettings?.defaultReasoningEffort = .max
            }
            await store.send(.fastModeToggled(true)) {
                $0.draftModelSettings?.isFastModeEnabled = true
            }

            @Shared(.mobileModelSettingsOverride) var reloadedOverride
            expectNoDifference(reloadedOverride, nil)
            #expect(store.state.hasChanges)
            #expect(store.state.isDefaultModelOverridden)
            #expect(store.state.isDefaultThinkingOverridden)
            #expect(store.state.isFastModeOverridden)

            let expectedOverride = DesktopClient.ModelSettings(
                defaultModel: .fable5,
                defaultReasoningEffort: .max,
                isFastModeEnabled: true
            )
            await store.send(.saveButtonTapped) {
                $0.$mobileModelSettingsOverride.withLock { $0 = expectedOverride }
            }
            await store.finish()
            expectNoDifference(reloadedOverride, expectedOverride)

            let reopenedStore = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }
            await reopenedStore.send(.modelSettingsResponse(.success(conductorSettings))) {
                $0.conductorModelSettings = conductorSettings
            }

            await reopenedStore.send(.resetModelSettingsButtonTapped) {
                $0.draftModelSettings = conductorSettings
            }
            expectNoDifference(reloadedOverride, expectedOverride)
            #expect(reopenedStore.state.hasChanges)
            #expect(!reopenedStore.state.hasDraftMobileModelSettingsOverride)

            await reopenedStore.send(.saveButtonTapped) {
                $0.$mobileModelSettingsOverride.withLock { $0 = nil }
            }
            await reopenedStore.finish()
            expectNoDifference(reloadedOverride, nil)
        }
    }

    @Test("Offline edits to an existing mobile override persist on Save")
    func offlineMobileModelSettingsOverride() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.dismiss = DismissEffect { }
        } operation: {
            let savedOverride = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .high,
                isFastModeEnabled: false
            )
            @Shared(.desktopServerAddress) var storedServerAddress
            $storedServerAddress.withLock { $0 = "my-mac" }
            @Shared(.mobileModelSettingsOverride) var reloadedOverride
            $reloadedOverride.withLock { $0 = savedOverride }

            var state = ConductorSettings.State()
            state.isLoadingModelSettings = true
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .modelSettingsResponse(.failure(ConnectionError.unreachable))
            ) {
                $0.isLoadingModelSettings = false
            }
            await store.send(.fastModeToggled(true)) {
                $0.draftModelSettings?.isFastModeEnabled = true
            }
            expectNoDifference(reloadedOverride, savedOverride)

            var editedOverride = savedOverride
            editedOverride.isFastModeEnabled = true
            await store.send(.saveButtonTapped) {
                $0.$mobileModelSettingsOverride.withLock { $0 = editedOverride }
            }
            await store.finish()
            expectNoDifference(reloadedOverride, editedOverride)
        }
    }

    @Test("Unsaved settings changes are detected")
    func unsavedChanges() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            var state = ConductorSettings.State()
            #expect(!state.hasChanges)

            state.initialServerAddress = "draft-mac"
            #expect(state.hasChanges)

            state.initialServerAddress = state.storedServerAddress ?? ""
            state.displayName = "Office desktop"
            #expect(state.hasChanges)

            state.displayName = ""
            state.deviceIcon = .desktop
            #expect(state.hasChanges)

            state.deviceIcon = .laptop
            let conductorSettings = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .high,
                isFastModeEnabled: false
            )
            state.conductorModelSettings = conductorSettings
            state.draftModelSettings = conductorSettings
            state.initialModelSettings = conductorSettings
            #expect(!state.hasChanges)
            #expect(!state.hasDraftMobileModelSettingsOverride)

            state.draftModelSettings?.defaultModel = .fable5
            #expect(state.isDefaultModelOverridden)
            #expect(!state.isDefaultThinkingOverridden)

            state.draftModelSettings = conductorSettings
            state.draftModelSettings?.defaultReasoningEffort = .ultra
            #expect(!state.isDefaultModelOverridden)
            #expect(state.isDefaultThinkingOverridden)

            state.draftModelSettings = conductorSettings
            state.draftModelSettings?.isFastModeEnabled = true
            #expect(!state.isDefaultModelOverridden)
            #expect(!state.isDefaultThinkingOverridden)
            #expect(state.isFastModeOverridden)
            #expect(state.hasDraftMobileModelSettingsOverride)
            #expect(state.hasChanges)
        }
    }

    @Test("Saving trims and persists the desktop settings")
    func saveDesktopSettings() async {
        let isDismissed = LockIsolated(false)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { serverAddress in
                expectNoDifference(serverAddress, "my-mac")
            }
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "  my-mac  "))
            ) {
                $0.initialServerAddress = "  my-mac  "
            }
            await store.send(
                .binding(.set(\.displayName, "  Office desktop  "))
            ) {
                $0.displayName = "  Office desktop  "
            }
            await store.send(
                .binding(.set(\.deviceIcon, .desktop))
            ) {
                $0.deviceIcon = .desktop
            }
            await store.send(.saveButtonTapped) {
                $0.connectionTestSource = .saveButtonTapped
                $0.displayName = "Office desktop"
                $0.initialServerAddress = "my-mac"
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "my-mac"
                $0.$storedDisplayConfiguration.withLock {
                    $0 = DesktopClient.DisplayConfiguration(
                        name: "Office desktop",
                        icon: .desktop
                    )
                }
                $0.$storedServerAddress.withLock { $0 = "my-mac" }
            }
            await store.finish()
            #expect(isDismissed.value)

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                "my-mac"
            )
            expectNoDifference(
                ConductorSettings.State().storedDisplayConfiguration,
                Optional(
                    DesktopClient.DisplayConfiguration(
                        name: "Office desktop",
                        icon: .desktop
                    )
                )
            )
        }
    }

    @Test("A failed connection test keeps the saved desktop server address")
    func failedConnectionTest() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { _ in
                throw ConnectionError.unreachable
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "unreachable-mac"))
            ) {
                $0.initialServerAddress = "unreachable-mac"
            }
            await store.send(.saveButtonTapped) {
                $0.connectionTestSource = .saveButtonTapped
            }
            await store.receive(\.connectionTestResult) {
                $0.alert = .failedToConnect(
                    to: "unreachable-mac",
                    error: ConnectionError.unreachable
                )
                $0.connectionTestSource = nil
            }

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                ""
            )
        }
    }

    @Test("Testing checks the draft without saving it")
    func testServerAddress() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { serverAddress in
                expectNoDifference(serverAddress, "draft-mac")
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "  draft-mac  "))
            ) {
                $0.initialServerAddress = "  draft-mac  "
            }
            await store.send(.testButtonTapped) {
                $0.connectionTestSource = .testButtonTapped
                $0.initialServerAddress = "draft-mac"
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "draft-mac"
            }

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                ""
            )
        }
    }

    @Test("A connected address can be tested again")
    func retestConnectedServerAddress() async {
        let checkedServerAddresses = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { serverAddress in
                checkedServerAddresses.withValue { $0.append(serverAddress) }
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "my-mac"))
            ) {
                $0.initialServerAddress = "my-mac"
            }
            await store.send(.testButtonTapped) {
                $0.connectionTestSource = .testButtonTapped
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "my-mac"
            }

            await store.send(.testButtonTapped) {
                $0.connectionTestSource = .testButtonTapped
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
            }

            expectNoDifference(checkedServerAddresses.value, ["my-mac", "my-mac"])
        }
    }

    @Test("The last tested address saves without another check")
    func lastTestedServerAddress() async {
        let checkedServerAddresses = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { serverAddress in
                checkedServerAddresses.withValue { $0.append(serverAddress) }
            }
            $0.dismiss = DismissEffect { }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "first-mac"))
            ) {
                $0.initialServerAddress = "first-mac"
            }
            await store.send(.testButtonTapped) {
                $0.connectionTestSource = .testButtonTapped
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "first-mac"
            }
            #expect(store.state.isServerAddressConnected)

            await store.send(
                .binding(.set(\.initialServerAddress, "second-mac"))
            ) {
                $0.initialServerAddress = "second-mac"
            }
            #expect(!store.state.isServerAddressConnected)

            await store.send(
                .binding(.set(\.initialServerAddress, "  first-mac  "))
            ) {
                $0.initialServerAddress = "  first-mac  "
            }
            #expect(store.state.isServerAddressConnected)

            await store.send(.saveButtonTapped) {
                $0.initialServerAddress = "first-mac"
                $0.$storedServerAddress.withLock { $0 = "first-mac" }
            }
            await store.finish()

            expectNoDifference(checkedServerAddresses.value, ["first-mac"])
        }
    }

    @Test("An empty server address cannot be saved")
    func emptyServerAddress() async {
        let isDismissed = LockIsolated(false)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.desktopClient.checkConnection = { _ in
                Issue.record("Connection should not be tested without changes")
            }
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }
            #expect(store.state.displayName.isEmpty)
            expectNoDifference(store.state.deviceIcon, .laptop)

            #expect(store.state.isSaveButtonDisabled)
            #expect(store.state.isServerAddressMissing)
            await store.send(.saveButtonTapped)
            await store.finish()
            #expect(!isDismissed.value)
            expectNoDifference(
                ConductorSettings.State().storedDisplayConfiguration,
                nil
            )
        }
    }

    @Test("Saving an empty previously configured address clears local settings")
    func clearPreviouslySavedServerAddress() async {
        let isDismissed = LockIsolated(false)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
        } operation: {
            let persistedState = ConductorSettings.State()
            persistedState.$storedDisplayConfiguration.withLock {
                $0 = DesktopClient.DisplayConfiguration(
                    name: "Office desktop",
                    icon: .desktop
                )
            }
            persistedState.$storedServerAddress.withLock { $0 = "old-mac" }

            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }
            await store.send(
                .binding(.set(\.initialServerAddress, "   "))
            ) {
                $0.initialServerAddress = "   "
            }
            #expect(!store.state.isSaveButtonDisabled)
            await store.send(.saveButtonTapped) {
                $0.initialServerAddress = ""
                $0.$storedDisplayConfiguration.withLock { $0 = nil }
                $0.$storedServerAddress.withLock { $0 = nil }
            }
            await store.finish()

            #expect(isDismissed.value)
            #expect(store.state.storedServerAddress == nil)
            #expect(store.state.storedDisplayConfiguration == nil)
        }
    }

    @Test("Editing without saving leaves the persisted desktop settings unchanged")
    func discardDraft() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.initialServerAddress, "draft-mac"))
            ) {
                $0.initialServerAddress = "draft-mac"
            }
            await store.send(
                .binding(.set(\.displayName, "Draft server"))
            ) {
                $0.displayName = "Draft server"
            }
            await store.send(
                .binding(.set(\.deviceIcon, .server))
            ) {
                $0.deviceIcon = .server
            }
            let conductorSettings = DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .high,
                isFastModeEnabled: false
            )
            await store.send(.modelSettingsResponse(.success(conductorSettings))) {
                $0.conductorModelSettings = conductorSettings
                $0.draftModelSettings = conductorSettings
                $0.initialModelSettings = conductorSettings
            }
            await store.send(.fastModeToggled(true)) {
                $0.draftModelSettings?.isFastModeEnabled = true
            }

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                ""
            )
            expectNoDifference(
                ConductorSettings.State().storedDisplayConfiguration,
                nil
            )
            expectNoDifference(
                ConductorSettings.State().mobileModelSettingsOverride,
                nil
            )
        }
    }

    @Test("Cloud connection testing uses the draft key without saving it")
    func testCloudConnection() async {
        let testedKeys = LockIsolated<[String]>([])
        let savedKeys = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.validateIdentity = { apiKey in
                testedKeys.withValue { $0.append(apiKey) }
                return CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.cloudAPIKey, "  synthetic-cloud-key  "))
            ) {
                $0.cloudAPIKey = "  synthetic-cloud-key  "
            }
            await store.send(.testCloudConnectionButtonTapped) {
                $0.cloudAPIKey = "synthetic-cloud-key"
                $0.cloudOperation = .testing
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.cloudConnectionTestSuccessCount = 1
                $0.testedCloudAccountID = "synthetic-user::"
            }
            await store.send(.testCloudConnectionButtonTapped) {
                $0.cloudOperation = .testing
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.cloudConnectionTestSuccessCount = 2
            }

            expectNoDifference(
                testedKeys.value,
                ["synthetic-cloud-key", "synthetic-cloud-key"]
            )
            #expect(savedKeys.value.isEmpty)
            #expect(!store.state.isCloudCredentialConfigured)
        }
    }

    @Test("An invalid replacement key does not overwrite the saved credential marker")
    func invalidReplacementKey() async {
        let savedKeys = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.validateIdentity = { _ in
                throw CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
        } operation: {
            let state = ConductorSettings.State()
            state.$cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "saved-account")
            }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.cloudAPIKey, "replacement-key"))
            ) {
                $0.cloudAPIKey = "replacement-key"
            }
            await store.send(.saveButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.alert = .failedToConnectToCloud(
                    error: CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
                )
            }

            #expect(savedKeys.value.isEmpty)
            #expect(store.state.isCloudCredentialConfigured)
        }
    }

    @Test("A valid new API key is tested and saved to the credential boundary")
    func saveNewCloudCredential() async throws {
        let isDismissed = LockIsolated(false)
        let savedKeys = LockIsolated<[String]>([])
        let (savePermission, savePermissionContinuation) = AsyncStream<Void>.makeStream()
        let database = try appDatabase()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultDatabase = database
            $0.cloudAPIClient.validateIdentity = { _ in
                CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
                for await _ in savePermission {
                    break
                }
            }
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
            $0.uuid = .incrementing
        } operation: {
            let state = ConductorSettings.State()
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.binding(.set(\.cloudAPIKey, "new-key"))) {
                $0.cloudAPIKey = "new-key"
            }
            await store.send(.saveButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = .saving
                $0.cloudConnectionTestSuccessCount = 1
                $0.testedCloudAccountID = "synthetic-user::"
            }
            savePermissionContinuation.yield()
            savePermissionContinuation.finish()
            await store.receive(\.cloudSaveResult) {
                $0.$cloudConfiguration.withLock {
                    $0 = CloudConfiguration(
                        accountID: "synthetic-user::",
                        credentialGeneration: UUID(0)
                    )
                }
                $0.cloudAPIKey = ""
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
            }

            expectNoDifference(savedKeys.value, ["new-key"])
            #expect(ConductorSettings.State().isCloudCredentialConfigured)
            #expect(isDismissed.value)
        }
    }

    @Test("A same-account API key replacement is tested and persisted")
    func replaceCloudCredential() async throws {
        let isDismissed = LockIsolated(false)
        let testedKeys = LockIsolated<[String]>([])
        let savedKeys = LockIsolated<[String]>([])
        let database = try appDatabase()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultDatabase = database
            $0.cloudAPIClient.validateIdentity = { apiKey in
                testedKeys.withValue { $0.append(apiKey) }
                return CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
            $0.uuid = .incrementing
        } operation: {
            let state = ConductorSettings.State()
            state.$cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "synthetic-user::",
                    credentialGeneration: UUID(99)
                )
            }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.cloudAPIKey, "  replacement-key  "))
            ) {
                $0.cloudAPIKey = "  replacement-key  "
            }
            await store.send(.saveButtonTapped) {
                $0.cloudAPIKey = "replacement-key"
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudConnectionTestSuccessCount = 1
                $0.testedCloudAccountID = "synthetic-user::"
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudSaveResult) {
                $0.$cloudConfiguration.withLock {
                    $0 = CloudConfiguration(
                        accountID: "synthetic-user::",
                        credentialGeneration: UUID(0)
                    )
                }
                $0.cloudAPIKey = ""
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
            }

            expectNoDifference(testedKeys.value, ["replacement-key"])
            expectNoDifference(savedKeys.value, ["replacement-key"])
            #expect(store.state.isCloudCredentialConfigured)
            #expect(isDismissed.value)
        }
    }

    @Test("A tested API key saves without another validation request")
    func testedCloudCredentialIsNotRetested() async throws {
        let testedKeys = LockIsolated<[String]>([])
        let savedKeys = LockIsolated<[String]>([])
        let database = try appDatabase()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultDatabase = database
            $0.cloudAPIClient.validateIdentity = { apiKey in
                testedKeys.withValue { $0.append(apiKey) }
                return CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
            $0.dismiss = DismissEffect { }
            $0.uuid = .incrementing
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(.binding(.set(\.cloudAPIKey, "new-key"))) {
                $0.cloudAPIKey = "new-key"
            }
            await store.send(.testCloudConnectionButtonTapped) {
                $0.cloudOperation = .testing
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.cloudConnectionTestSuccessCount = 1
                $0.testedCloudAccountID = "synthetic-user::"
            }
            await store.send(.saveButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudSaveResult) {
                $0.$cloudConfiguration.withLock {
                    $0 = CloudConfiguration(
                        accountID: "synthetic-user::",
                        credentialGeneration: UUID(0)
                    )
                }
                $0.cloudAPIKey = ""
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
            }

            expectNoDifference(testedKeys.value, ["new-key"])
            expectNoDifference(savedKeys.value, ["new-key"])
        }
    }

    @Test("Deleting a cloud credential leaves local pairing configured")
    func deleteCloudCredential() async throws {
        let deleteCount = LockIsolated(0)
        let database = try appDatabase()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultDatabase = database
            $0.cloudCredentialClient.deleteAPIKey = {
                deleteCount.withValue { $0 += 1 }
            }
        } operation: {
            let state = ConductorSettings.State()
            state.$cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }
            state.$storedServerAddress.withLock { $0 = "paired-mac" }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.deleteCloudCredentialButtonTapped) {
                $0.cloudOperation = .deleting
            }
            await store.receive(\.cloudCredentialDeleteResult) {
                $0.$cloudConfiguration.withLock { $0 = nil }
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
            }

            #expect(deleteCount.value == 1)
            expectNoDifference(store.state.storedServerAddress, "paired-mac")
        }
    }

    @Test("A save cleanup failure retains the newly validated configuration")
    func saveCleanupFailureRetainsConfiguration() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudWorkspaceCacheClient.clear = { _ in
                throw CleanupError.failed
            }
            $0.uuid = .incrementing
        } operation: {
            var state = ConductorSettings.State()
            state.cloudOperation = .saving
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .cloudSaveResult(
                    accountID: "new-account",
                    didReplaceCredential: true,
                    result: .success(())
                )
            ) {
                $0.$cloudConfiguration.withLock {
                    $0 = CloudConfiguration(
                        accountID: "new-account",
                        credentialGeneration: UUID(0)
                    )
                }
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
                $0.alert = .failedToUpdateCloudCredential(
                    error: CleanupError.failed
                )
            }
            #expect(
                store.state.cloudConfiguration
                    == CloudConfiguration(
                        accountID: "new-account",
                        credentialGeneration: UUID(0)
                    )
            )
        }
    }

    @Test("A delete cleanup failure keeps the configuration cleared")
    func deleteCleanupFailureKeepsConfigurationCleared() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudWorkspaceCacheClient.clear = { _ in
                throw CleanupError.failed
            }
        } operation: {
            var state = ConductorSettings.State()
            state.cloudOperation = .deleting
            state.$cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "old-account")
            }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .cloudCredentialDeleteResult(.success(()))
            ) {
                $0.$cloudConfiguration.withLock { $0 = nil }
            }
            await store.receive(\.cloudCacheCleanupResult) {
                $0.cloudOperation = nil
                $0.alert = .failedToUpdateCloudCredential(
                    error: CleanupError.failed
                )
            }
            #expect(store.state.cloudConfiguration == nil)
        }
    }

    @Test("An invalid cloud draft prevents local settings from being saved")
    func invalidCloudDraftPreventsLocalSave() async {
        let cloudTestCount = LockIsolated(0)
        let desktopTestCount = LockIsolated(0)
        let isDismissed = LockIsolated(false)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.validateIdentity = { _ in
                cloudTestCount.withValue { $0 += 1 }
                throw CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
            }
            $0.desktopClient.checkConnection = { _ in
                desktopTestCount.withValue { $0 += 1 }
            }
            $0.dismiss = DismissEffect {
                isDismissed.setValue(true)
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(.binding(.set(\.initialServerAddress, "paired-mac"))) {
                $0.initialServerAddress = "paired-mac"
            }
            await store.send(.binding(.set(\.cloudAPIKey, "invalid-draft"))) {
                $0.cloudAPIKey = "invalid-draft"
            }
            await store.send(.saveButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.alert = .failedToConnectToCloud(
                    error: CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
                )
            }
            await store.finish()

            #expect(cloudTestCount.value == 1)
            #expect(desktopTestCount.value == 0)
            #expect(!isDismissed.value)
            #expect(!store.state.isCloudCredentialConfigured)
            #expect(store.state.storedServerAddress == nil)
        }
    }

    @Test("A failed local test does not persist a validated cloud draft")
    func invalidLocalDraftPreventsCloudSave() async {
        let savedKeys = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.validateIdentity = { _ in
                CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
            $0.desktopClient.checkConnection = { _ in
                throw ConnectionError.unreachable
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(.binding(.set(\.cloudAPIKey, "valid-key"))) {
                $0.cloudAPIKey = "valid-key"
            }
            await store.send(
                .binding(.set(\.initialServerAddress, "unreachable-mac"))
            ) {
                $0.initialServerAddress = "unreachable-mac"
            }
            await store.send(.saveButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = nil
                $0.connectionTestSource = .saveButtonTapped
                $0.cloudConnectionTestSuccessCount = 1
                $0.testedCloudAccountID = "synthetic-user::"
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.alert = .failedToConnect(
                    to: "unreachable-mac",
                    error: ConnectionError.unreachable
                )
            }

            #expect(savedKeys.value.isEmpty)
            #expect(!store.state.isCloudCredentialConfigured)
            #expect(store.state.storedServerAddress == nil)
        }
    }
}

private enum ConnectionError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        "The test desktop service is unreachable."
    }
}

private enum CleanupError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The synthetic cleanup failed."
    }
}
