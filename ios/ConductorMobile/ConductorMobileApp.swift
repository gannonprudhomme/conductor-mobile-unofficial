//
//  ConductorMobileApp.swift
//  ConductorMobile
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorDesign
import ConductorMain
import ConductorMobileData
import Dependencies
import SwiftUI

@main
struct ConductorMobileApp: App {
    static let store = Store(initialState: Main.State()) {
        Main()
    }

    init() {
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
