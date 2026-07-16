//
//  SidecarProxyView.swift
//  ConductorDesktop
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Accessibility
import AppKit
import ConductorBridge
import ConductorMobileServer
import Dependencies
import Observation
import SharedConductorDesign
import SwiftUI

@MainActor
@Observable
private final class SidecarProxyModel {
    var status = BridgeStatus()
    var errorMessage: String?
    var isBridgeMutationInFlight = false
    var isShowingError = false
    var isWorkspaceUIHookConnected = false

    private let installer = BridgeInstallerClient()
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

    func monitorBridgeStatus() async {
        while !Task.isCancelled {
            await refreshBridgeStatus()

            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    func installButtonTapped() async {
        guard !isBridgeMutationInFlight else {
            return
        }

        isBridgeMutationInFlight = true
        defer { isBridgeMutationInFlight = false }

        do {
            if status.isInstalledInApplications {
                try await installer.uninstall()
            } else {
                try await installer.install()
            }

            await refreshBridgeStatus()
        } catch {
            presentError("Could not update bridge installation: \(error)")
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

    private func refreshBridgeStatus() async {
        // Sample hook state alongside existing bridge polling instead of maintaining a subscriber.
        isWorkspaceUIHookConnected = await workspaceUIHook.isConnected()

        do {
            status = try await installer.status()
        } catch is CancellationError {
        } catch {
            presentError("Could not refresh bridge status: \(error)")
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}

struct SidecarProxyView: View {
    @State private var isShowingLoaderCopied = false
    @State private var isShowingWorkspaceUIHookInstructions = false
    @State private var model: SidecarProxyModel
    private let shouldMonitorBridgeStatus: Bool

    init(
        startupErrorMessage: String?,
        workspaceUIHookLoaderSource: String?,
        shouldMonitorBridgeStatus: Bool = true
    ) {
        self.shouldMonitorBridgeStatus = shouldMonitorBridgeStatus
        _model = State(
            initialValue: SidecarProxyModel(
                startupErrorMessage: startupErrorMessage,
                workspaceUIHookLoaderSource: workspaceUIHookLoaderSource
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Conductor Mobile companion")
                .font(.theme(.heading).weight(.regular))
                .foregroundStyle(.theme(.foreground))
                .frame(minHeight: 32, alignment: .leading)

            VStack(spacing: 16) {
                workspaceUIHookRow

                separator

                installationRow

                separator

                bridgeApplicationsInstallationRow

                separator

                bridgeApplicationSupportInstallationRow

                separator

                bridgeConnectionStatusRow
            }
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
            guard shouldMonitorBridgeStatus else {
                return
            }
            await model.monitorBridgeStatus()
        }
        .sheet(isPresented: $isShowingWorkspaceUIHookInstructions) {
            WorkspaceUIHookInstructionsView()
        }
        .alert(
            "Conductor Mobile Proxy",
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
            title: Text("Workspace UI Hook"),
            subtitle: Text("Runs workspace changes through Conductor’s loaded frontend services.")
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
                    // Keep success visible long enough to read without delaying the pasteboard write.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else {
                        return
                    }
                    isShowingLoaderCopied = false
                }

                Button {
                    isShowingWorkspaceUIHookInstructions = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.theme(.textSecondary))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Workspace UI Hook setup instructions")
                .accessibilityLabel("Workspace UI Hook setup instructions")
            }
        }
    }

    private var installationRow: some View {
        MenuRow(
            title: Text("Installation"),
            subtitle: Text("Optional runtime proxy; independent of the Workspace UI Hook.")
        ) {
            ChipButton(
                title: model.status.isInstalledInApplications
                    ? "Uninstall proxy"
                    : "Install proxy",
                icon: model.status.isInstalledInApplications
                    ? Lucide.x
                    : Lucide.download
            ) {
                Task { await model.installButtonTapped() }
            }
            .disabled(model.isBridgeMutationInFlight)
        }
    }

    private func copyLoaderButtonTapped() {
        model.copyLoaderButtonTapped {
            isShowingLoaderCopied = true
            AccessibilityNotification.Announcement("Copied").post()
        }
    }

    private var bridgeApplicationsInstallationRow: some View {
        let applicationsPath = Text("/Applications/...").font(.theme(.codeBody))
        let applicationSupportSubtitlePath = Text("~/Library/Applications Support/...")
            .font(.theme(.codeSmall).weight(.light))

        return MenuRow(
            title: Text("Bridge installed in \(applicationsPath)"),
            subtitle: Text(
                "Conductor copies the binary at this location into its \(applicationSupportSubtitlePath) directory at launch."
            )
        ) {
            StatusTag(
                title: model.status.isInstalledInApplications
                    ? "Installed"
                    : "Not installed",
                isEnabled: model.status.isInstalledInApplications
            )
        }
    }

    private var bridgeApplicationSupportInstallationRow: some View {
        let applicationSupportPath = Text("~/Library/Applications Support/...")
            .font(.theme(.codeBody))

        return MenuRow(
            title: Text("Bridge installed in \(applicationSupportPath)"),
            subtitle: Text("The location of the binary that Conductor actually uses at runtime.")
        ) {
            StatusTag(
                title: model.status.isInstalledInApplicationSupport
                    ? "Installed"
                    : "Not installed",
                isEnabled: model.status.isInstalledInApplicationSupport
            )
        }
    }

    private var bridgeConnectionStatusRow: some View {
        MenuRow(title: Text("Bridge running")) {
            StatusTag(
                title: model.status.isReachable ? "Running" : "Not running",
                isEnabled: model.status.isReachable
            )
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.theme(.border))
            .frame(height: 1)
    }
}

#Preview("Sidecar proxy") {
    SidecarProxyView(
        startupErrorMessage: nil,
        workspaceUIHookLoaderSource: "preview loader",
        shouldMonitorBridgeStatus: false
    )
    .frame(width: 800, height: 600)
}
