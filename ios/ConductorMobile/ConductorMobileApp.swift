//
//  ConductorMobileApp.swift
//  ConductorMobile
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorDesign
import ConductorFoundation
import ConductorMain
import ConductorMobileData
import Dependencies
import Logging
import Sharing
import SwiftUI

@main
struct ConductorMobileApp: App {
    static let store = Store(initialState: Main.State()) {
        Main()
    }

    init() {
        LoggingSystem.bootstrap(LoggingOSLog.init)

        try! prepareDependencies {
            try $0.bootstrapDatabase()
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["CONDUCTOR_UI_TEST_FIXTURE"]
            == "cloud-connect-and-browse" {
            @Shared(.cloudCredentialConfigured)
            var isCloudCredentialConfigured
            @Shared(.cloudAccountID) var cloudAccountID
            $isCloudCredentialConfigured.withLock { $0 = true }
            $cloudAccountID.withLock { $0 = "fixture-account" }
            prepareCloudConnectAndBrowseUITestFixture()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MainView(store: Self.store)
        }
    }
}
