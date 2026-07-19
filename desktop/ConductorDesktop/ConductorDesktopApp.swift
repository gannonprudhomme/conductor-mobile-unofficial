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
        Window("Conductor Mobile Companion", id: "main") {
            CompanionView(
                startupErrorMessage: appDelegate.startupErrorMessage,
                workspaceUIHookLoaderSource: appDelegate.workspaceUIHookLoaderSource
            )
                .background(WindowConfigurator())
        }
        .defaultSize(width: 680, height: 250)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let startupErrorMessage: String?
    let workspaceUIHookLoaderSource: String?

    private let workspaceUIHookSource: String?
    private var serverTask: Task<Void, Never>?

    override init() {
        // Load the javascript files from the bundle
        do {
            let hookSource = try Self.resource(named: "browser-hook", extension: "mjs")
            let loaderSource = try Self.resource(named: "bootstrap-loader", extension: "js")
            self.workspaceUIHookLoaderSource = loaderSource
            self.workspaceUIHookSource = hookSource
            self.startupErrorMessage = nil
        } catch {
            self.workspaceUIHookLoaderSource = nil
            self.workspaceUIHookSource = nil
            self.startupErrorMessage = "Could not start the companion: \(error)"
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoggingSystem.bootstrap(LoggingOSLog.init)

        guard let workspaceUIHookSource else {
            if let startupErrorMessage {
                FileHandle.standardError.write(
                    Data("conductor-mobile-server: \(startupErrorMessage)\n".utf8)
                )
            }
            return
        }

        serverTask = Task {
            do {
                try await Server.run(
                    databaseURL: Self.databaseURL,
                    workspaceUIHookSource: workspaceUIHookSource
                )
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

    private static func resource(named name: String, extension fileExtension: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            throw StartupError(description: "The bundled \(name).\(fileExtension) resource is missing.")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard !source.isEmpty else {
            throw StartupError(description: "The bundled \(name).\(fileExtension) resource is empty.")
        }
        return source
    }

    private struct StartupError: Error, CustomStringConvertible {
        let description: String
    }
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
