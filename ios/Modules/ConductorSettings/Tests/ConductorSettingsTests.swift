//
//  ConductorSettingsTests.swift
//  ConductorSettingsTests
//
//  Created by Gannon Prudomme on 7/13/26.
//

import ComposableArchitecture
import ConductorMobileData
import CustomDump
import Dependencies
@testable import ConductorSettings
import Foundation
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
}

private enum ConnectionError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        "The test desktop service is unreachable."
    }
}
