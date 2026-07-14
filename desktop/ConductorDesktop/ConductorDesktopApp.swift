//
//  ConductorDesktopApp.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/12/26.
//

import AppKit
import ConductorFoundation
import ConductorMobileServer
import Logging
import SharedConductorDesign
import SwiftUI

@main
struct ConductorDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Conductor Mobile Proxy (unofficial)", id: "main") {
            SidecarProxyView()
                .background(WindowConfigurator())
        }
        .defaultSize(width: 800, height: 600)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var serverTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoggingSystem.bootstrap(LoggingOSLog.init)

        serverTask = Task {
            do {
                try await Server.run(databaseURL: Self.databaseURL)
            } catch is CancellationError {
            } catch {
                FileHandle.standardError.write(
                    Data("conductor-mobile-server: \(error)\n".utf8)
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverTask?.cancel()
    }

    private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.conductor.app/conductor.db")
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView()
    }

    func updateNSView(_ view: NSView, context: Context) { }
}

private final class WindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = window
        DispatchQueue.main.async {
            window?.styleMask.insert(.fullSizeContentView)
            window?.backgroundColor = NSColor(.theme(.background))
            window?.titlebarAppearsTransparent = true
            window?.titlebarSeparatorStyle = .none
            window?.titleVisibility = .visible
        }
    }
}
