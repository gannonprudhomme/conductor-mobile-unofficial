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
    @Test("Saving trims and persists the desktop server address")
    func saveServerAddress() async {
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
            await store.send(.saveButtonTapped) {
                $0.connectionTestSource = .saveButtonTapped
                $0.initialServerAddress = "my-mac"
            }
            await store.receive(\.connectionTestResult) {
                $0.connectionTestSource = nil
                $0.testedServerAddress = "my-mac"
                $0.$storedServerAddress.withLock { $0 = "my-mac" }
            }
            await store.finish()
            #expect(isDismissed.value)

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                "my-mac"
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
                DesktopClient.defaultServerAddress
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
                DesktopClient.defaultServerAddress
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

    @Test("Saving without changes dismisses without testing the connection")
    func saveWithoutChanges() async {
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

            await store.send(.saveButtonTapped)
            await store.finish()
            #expect(isDismissed.value)
        }
    }

    @Test("Editing without saving leaves the persisted desktop server address unchanged")
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

            expectNoDifference(
                ConductorSettings.State().initialServerAddress,
                DesktopClient.defaultServerAddress
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
