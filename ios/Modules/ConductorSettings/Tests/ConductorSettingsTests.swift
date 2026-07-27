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
import Testing

@Suite(.serialized)
@MainActor
struct ConductorSettingsTests {
    @Test("A fresh launch does not access Keychain before Cloud is configured")
    func freshLaunchDoesNotLoadCloudCredential() async {
        let loadCount = LockIsolated(0)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudCredentialClient.loadAPIKey = {
                loadCount.withValue { $0 += 1 }
                Issue.record("A fresh launch should not access Keychain")
                return nil
            }
        } operation: {
            let store = TestStore(initialState: ConductorSettings.State()) {
                ConductorSettings()
            }

            await store.send(.task)

            #expect(loadCount.value == 0)
            #expect(store.state.alert == nil)
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

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                ""
            )
            expectNoDifference(
                ConductorSettings.State().storedDisplayConfiguration,
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
            $0.cloudAPIClient.getIdentity = { apiKey in
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
                $0.isCloudConnectionTested = true
                $0.testedCloudAccountID = "synthetic-user::"
            }

            expectNoDifference(testedKeys.value, ["synthetic-cloud-key"])
            #expect(savedKeys.value.isEmpty)
            #expect(!store.state.isCloudCredentialConfigured)
        }
    }

    @Test("An invalid replacement key does not overwrite the saved credential marker")
    func invalidReplacementKey() async {
        let savedKeys = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.getIdentity = { _ in
                throw CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
        } operation: {
            let state = ConductorSettings.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.cloudAPIKey, "replacement-key"))
            ) {
                $0.cloudAPIKey = "replacement-key"
            }
            await store.send(.connectCloudButtonTapped) {
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
    func saveNewCloudCredential() async {
        let savedKeys = LockIsolated<[String]>([])
        let (savePermission, savePermissionContinuation) = AsyncStream<Void>.makeStream()

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.getIdentity = { _ in
                CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
                for await _ in savePermission {
                    break
                }
            }
            $0.cloudWorkspacePersistenceClient.switchAccount = { _ in }
        } operation: {
            let state = ConductorSettings.State()
            state.$isCloudCredentialConfigured.withLock { $0 = false }
            state.$cloudAccountID.withLock { $0 = nil }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.binding(.set(\.cloudAPIKey, "new-key"))) {
                $0.cloudAPIKey = "new-key"
            }
            await store.send(.connectCloudButtonTapped) {
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.cloudOperation = .saving
                $0.isCloudConnectionTested = true
                $0.testedCloudAccountID = "synthetic-user::"
            }
            savePermissionContinuation.yield()
            savePermissionContinuation.finish()
            await store.receive(\.cloudSaveResult) {
                $0.cloudOperation = nil
                $0.$isCloudCredentialConfigured.withLock { $0 = true }
                $0.$cloudAccountID.withLock { $0 = "synthetic-user::" }
                $0.cloudAPIKey = ""
            }

            expectNoDifference(savedKeys.value, ["new-key"])
            #expect(ConductorSettings.State().isCloudCredentialConfigured)
        }
    }

    @Test("A valid API key is tested before it replaces the Keychain value")
    func replaceCloudCredential() async {
        let testedKeys = LockIsolated<[String]>([])
        let savedKeys = LockIsolated<[String]>([])

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.getIdentity = { apiKey in
                testedKeys.withValue { $0.append(apiKey) }
                return CloudIdentity(userID: "synthetic-user", authMethod: .apiKey)
            }
            $0.cloudCredentialClient.saveAPIKey = { apiKey in
                savedKeys.withValue { $0.append(apiKey) }
            }
            $0.cloudWorkspacePersistenceClient.switchAccount = { _ in }
        } operation: {
            let state = ConductorSettings.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.$cloudAccountID.withLock { $0 = "synthetic-user::" }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(
                .binding(.set(\.cloudAPIKey, "  replacement-key  "))
            ) {
                $0.cloudAPIKey = "  replacement-key  "
            }
            await store.send(.connectCloudButtonTapped) {
                $0.cloudAPIKey = "replacement-key"
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudConnectionTestResult) {
                $0.isCloudConnectionTested = true
                $0.testedCloudAccountID = "synthetic-user::"
                $0.cloudOperation = .saving
            }
            await store.receive(\.cloudSaveResult) {
                $0.cloudOperation = nil
                $0.$cloudAccountID.withLock { $0 = "synthetic-user::" }
                $0.cloudAPIKey = ""
            }

            expectNoDifference(testedKeys.value, ["replacement-key"])
            expectNoDifference(savedKeys.value, ["replacement-key"])
            #expect(store.state.isCloudCredentialConfigured)
        }
    }

    @Test("A missing Keychain item clears a stale configured marker")
    func missingCloudCredential() async {
        let cacheClearCount = LockIsolated(0)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudCredentialClient.loadAPIKey = {
                nil
            }
            $0.cloudWorkspacePersistenceClient.clearCachedCatalog = {
                cacheClearCount.withValue { $0 += 1 }
            }
        } operation: {
            let state = ConductorSettings.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.$cloudAccountID.withLock { $0 = "stale-account" }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.task)
            await store.receive(\.cloudCredentialAvailabilityLoaded) {
                $0.$isCloudCredentialConfigured.withLock { $0 = false }
                $0.$cloudAccountID.withLock { $0 = nil }
            }
            #expect(cacheClearCount.value == 1)
        }
    }

    @Test("Deleting a cloud credential leaves local pairing configured")
    func deleteCloudCredential() async {
        let deleteCount = LockIsolated(0)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudCredentialClient.deleteAPIKey = {
                deleteCount.withValue { $0 += 1 }
            }
            $0.cloudWorkspacePersistenceClient.clearCachedCatalog = {}
        } operation: {
            let state = ConductorSettings.State()
            state.$isCloudCredentialConfigured.withLock { $0 = true }
            state.$storedServerAddress.withLock { $0 = "paired-mac" }
            let store = TestStore(initialState: state) {
                ConductorSettings()
            }

            await store.send(.deleteCloudCredentialButtonTapped) {
                $0.cloudOperation = .deleting
            }
            await store.receive(\.cloudCredentialDeleteResult) {
                $0.cloudOperation = nil
                $0.$isCloudCredentialConfigured.withLock { $0 = false }
                $0.$cloudAccountID.withLock { $0 = nil }
            }

            #expect(deleteCount.value == 1)
            expectNoDifference(store.state.storedServerAddress, "paired-mac")
        }
    }

    @Test("Local pairing saves without validating an unsaved cloud draft")
    func localPairingIsIndependent() async {
        let cloudTestCount = LockIsolated(0)
        let isDismissed = LockIsolated(false)

        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.cloudAPIClient.getIdentity = { _ in
                cloudTestCount.withValue { $0 += 1 }
                throw CloudAPIClientError.requestFailed(statusCode: 401, error: nil)
            }
            $0.desktopClient.checkConnection = { _ in }
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
                $0.connectionTestSource = .saveButtonTapped
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "paired-mac"
                $0.$storedServerAddress.withLock { $0 = "paired-mac" }
            }
            await store.finish()

            #expect(cloudTestCount.value == 0)
            #expect(isDismissed.value)
            #expect(!store.state.isCloudCredentialConfigured)
        }
    }
}

private enum ConnectionError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        "The test desktop service is unreachable."
    }
}
