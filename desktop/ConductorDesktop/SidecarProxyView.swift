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

    private let installer = BridgeInstallerClient()
    private let workspaceUIHookLoaderSource: String?
    @ObservationIgnored
    @Dependency(\.workspaceUIHook) private var workspaceUIHook

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
            errorMessage = "Could not update bridge installation: \(error.localizedDescription)"
        }
    }

    private func refreshBridgeStatus() async {
        do {
            status = try await installer.status()
        } catch is CancellationError {
        } catch {
            errorMessage = "Could not refresh bridge status: \(error.localizedDescription)"
        }
    }
}

struct SidecarProxyView: View {
    @State private var model = SidecarProxyModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Sidecar proxy")
                .font(.theme(.heading).weight(.regular))
                .foregroundStyle(.theme(.foreground))
                .frame(minHeight: 32, alignment: .leading)

            VStack(spacing: 16) {
                installationRow

                separator

                bridgeApplicationsInstallationRow

                separator

                bridgeApplicationSupportInstallationRow

                separator

                bridgeConnectionStatusRow

                if let errorMessage = model.errorMessage {
                    separator

                    MenuRow(title: Text("Error")) {
                        Text(errorMessage)
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.destructive))
                    }
                }
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
        .task { await model.monitorBridgeStatus() }
    }

    private var installationRow: some View {
        MenuRow(
            title: Text("Installation"),
            subtitle: Text("Install the conductor sidecar proxy to enable")
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
