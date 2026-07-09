import ComposableArchitecture
import ConductorData
import ConductorDesign
import ConductorMain
import Dependencies
import SwiftUI

@main
struct ConductorMobileApp: App {
    static let store = Store(initialState: Main.State()) {
        Main()
    }

    init() {
        Font.registerThemeFonts()

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
