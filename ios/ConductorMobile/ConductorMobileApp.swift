//
//  ConductorMobileApp.swift
//  ConductorMobile
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorFoundation
import ConductorMain
import ConductorMobileData
import Dependencies
import Logging
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
    }

    var body: some Scene {
        WindowGroup {
            MainView(store: Self.store)
        }
    }
}
