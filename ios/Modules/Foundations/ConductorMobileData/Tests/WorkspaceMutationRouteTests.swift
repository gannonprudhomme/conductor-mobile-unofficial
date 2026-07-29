//
//  WorkspaceMutationRouteTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData
@testable import ConductorMobileData
import Testing

struct WorkspaceMutationRouteTests {
    @Test("Desktop ownership takes mutation authority")
    func desktopAuthority() {
        let item = WorkspaceWithRepository(
            workspace: .preview(),
            repository: .preview(),
            mobileState: MobileWorkspaceState(
                workspaceID: "workspace",
                isWorking: false
            )
        )
        let route = item.mutationRoute(cloudConfiguration: nil as CloudConfiguration?)

        #expect(route == .desktop)
        #expect(route.capabilities.canManageQueue)
    }

    @Test("Cloud mutation authority requires current account ownership")
    func cloudAuthority() {
        let workspace = Workspace.preview(id: "canonical")
        let item = WorkspaceWithRepository(
            workspace: workspace,
            repository: .preview(),
            cloudMetadata: CloudWorkspaceMetadata(
                workspaceID: workspace.id,
                accountID: "account",
                remoteWorkspaceID: "remote",
                lastSeenGeneration: "generation"
            )
        )

        #expect(
            item.mutationRoute(
                cloudConfiguration: CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID()
                )
            )
                == .cloud(
                    accountID: "account",
                    remoteWorkspaceID: "remote"
                )
        )
        #expect(
            item.mutationRoute(
                cloudConfiguration: CloudConfiguration(
                    accountID: "other",
                    credentialGeneration: UUID()
                )
            ) == nil
        )
        let unavailableRoute = item.mutationRoute(
            cloudConfiguration: nil as CloudConfiguration?
        )
        #expect(!unavailableRoute.capabilities.canSend)
    }

    @Test("Cloud capabilities exclude Desktop-only operations")
    func cloudCapabilities() {
        let capabilities = WorkspaceMutationRoute.cloud(
            accountID: "account",
            remoteWorkspaceID: "workspace"
        )
        .capabilities

        #expect(capabilities.canSend)
        #expect(capabilities.canCancel)
        #expect(capabilities.canCreateSession)
        #expect(!capabilities.canManageQueue)
        #expect(!capabilities.canRestoreSession)
        #expect(!capabilities.canRenameBranch)
        #expect(!capabilities.canPin)
        #expect(!capabilities.canMarkUnread)
        #expect(!capabilities.canSetStatus)
        #expect(!capabilities.canConfigureMessages)
    }

    @Test("Creation catalog is Claude and Codex only")
    func creationCatalog() {
        let configurations = CloudCreationConfigurationCatalog.configurations

        #expect(configurations.allSatisfy { [.claude, .codex].contains($0.agent) })
        #expect(configurations.contains { $0.model == .opus5_1M })
        #expect(
            !configurations.contains {
                $0.efforts.contains(.ultracode)
            }
        )
        #expect(
            configurations.first { $0.model == .gpt_5_6_sol }?.efforts
                == [.none, .low, .medium, .high, .extraHigh, .max, .ultra]
        )
        #expect(
            configurations.first { $0.model == .gpt_5_6_terra }?.efforts
                == [.none, .low, .medium, .high, .extraHigh, .max, .ultra]
        )
        #expect(
            configurations.first { $0.model == .gpt5_5 }?.efforts
                == [.none, .low, .medium, .high, .extraHigh]
        )
        #expect(
            configurations.first { $0.model == .haiku4_5 }?.efforts
                == [.low, .medium, .high, .extraHigh, .max]
        )
        #expect(
            configurations.first { $0.model == .opus }?.supportsFastMode
                == true
        )
        #expect(
            configurations.first { $0.model == .sonnet_4_6 }?
                .supportsFastMode == false
        )
        #expect(
            configurations.first { $0.model == .gpt5_5 }?.supportsFastMode
                == true
        )
    }
}
