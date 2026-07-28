//
//  CompanionView.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Accessibility
import AppKit
import ConductorMobileServer
import Dependencies
import Observation
import SharedConductorDesign
import SwiftUI

@MainActor
@Observable
private final class CompanionModel {
    var errorMessage: String?
    var isShowingError = false
    var isWorkspaceUIHookConnected = false

    private let workspaceUIHookLoaderSource: String?
    @ObservationIgnored
    @Dependency(\.workspaceUIHook) private var workspaceUIHook

    init(
        startupErrorMessage: String?,
        workspaceUIHookLoaderSource: String?
    ) {
        self.workspaceUIHookLoaderSource = workspaceUIHookLoaderSource
        if let startupErrorMessage {
            errorMessage = startupErrorMessage
            isShowingError = true
        }
    }

    func monitorWorkspaceUIHook() async {
        while !Task.isCancelled {
            isWorkspaceUIHookConnected = await workspaceUIHook.isConnected()
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    func copyLoaderButtonTapped(onSuccess: () -> Void) {
        guard let workspaceUIHookLoaderSource else {
            presentError("The Workspace UI Hook loader is unavailable.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(workspaceUIHookLoaderSource, forType: .string) else {
            presentError("Could not copy the Workspace UI Hook loader.")
            return
        }
        onSuccess()
    }

    func errorDismissed() {
        isShowingError = false
        errorMessage = nil
    }

    private func presentError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}

struct CompanionView: View {
    @State private var isShowingLoaderCopied = false
    @State private var model: CompanionModel
    private let shouldMonitorWorkspaceUIHook: Bool

    init(
        startupErrorMessage: String?,
        workspaceUIHookLoaderSource: String?,
        shouldMonitorWorkspaceUIHook: Bool = true
    ) {
        self.shouldMonitorWorkspaceUIHook = shouldMonitorWorkspaceUIHook
        _model = State(
            initialValue: CompanionModel(
                startupErrorMessage: startupErrorMessage,
                workspaceUIHookLoaderSource: workspaceUIHookLoaderSource
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Conductor Mobile Companion")
                .font(.theme(.heading).weight(.regular))
                .foregroundStyle(.theme(.foreground))
                .frame(minHeight: 32, alignment: .leading)

            workspaceUIHookRow
        }
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: 32, leading: 40, bottom: 32, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Color.theme(.background)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .task {
            guard shouldMonitorWorkspaceUIHook else {
                return
            }
            await model.monitorWorkspaceUIHook()
        }
        .alert(
            "Conductor Mobile Companion",
            isPresented: $model.isShowingError,
            presenting: model.errorMessage
        ) { _ in
            Button("OK") { model.errorDismissed() }
        } message: { errorMessage in
            Text(errorMessage)
        }
    }

    private var workspaceUIHookRow: some View {
        MenuRow(
            title: Text("UI Hook"),
            subtitle: Text("Performs changes inside Conductor so mobile actions update its UI. Only required for local, not Conductor Cloud.")
        ) {
            HStack(spacing: 8) {
                StatusTag(
                    title: model.isWorkspaceUIHookConnected
                        ? "Connected"
                        : "Not Connected",
                    isEnabled: model.isWorkspaceUIHookConnected
                )

                ChipButton(
                    title: "Copy Loader",
                    icon: Lucide.copy,
                    isConfirmed: isShowingLoaderCopied
                ) {
                    copyLoaderButtonTapped()
                }
                .disabled(isShowingLoaderCopied)
                .task(id: isShowingLoaderCopied) {
                    guard isShowingLoaderCopied else {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else {
                        return
                    }
                    isShowingLoaderCopied = false
                }
            }
        }
    }

    private func copyLoaderButtonTapped() {
        model.copyLoaderButtonTapped {
            isShowingLoaderCopied = true
            AccessibilityNotification.Announcement("Copied").post()
        }
    }
}

#Preview("Companion") {
    CompanionView(
        startupErrorMessage: nil,
        workspaceUIHookLoaderSource: "preview loader",
        shouldMonitorWorkspaceUIHook: false
    )
    .frame(width: 680, height: 250)
}
