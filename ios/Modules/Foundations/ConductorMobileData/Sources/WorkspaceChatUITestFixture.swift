//
//  WorkspaceChatUITestFixture.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/24/26.
//

#if DEBUG
import Dependencies
import SharedConductorData
import Sharing
import SQLiteData

extension DependencyValues {
    public mutating func prepareWorkspaceChatUITest() throws {
        let repository = Repository.preview(
            id: "ui-test-repository",
            name: "conductor-mobile"
        )
        let session = Session.preview(
            id: "ui-test-session",
            workspaceID: "ui-test-workspace",
            title: "Context menu"
        )
        let workspace = Workspace.preview(
            id: session.workspaceID,
            activeSessionID: session.id,
            branch: "Context menu",
            repositoryID: repository.id
        )
        let workspaceSnapshot = WorkspaceListSnapshot(
            repositories: [repository],
            workspaces: [
                WorkspaceSnapshot(workspace: workspace, isWorking: false),
            ]
        )

        try defaultDatabase.write { database in
            try Message.delete().execute(database)
            try Session.delete().execute(database)
            try MobileWorkspaceState.delete().execute(database)
            try Workspace.delete().execute(database)
            try Repository.delete().execute(database)
        }

        @Shared(.desktopServerAddress) var serverAddress
        $serverAddress.withLock { $0 = "ui-test" }

        @Shared(.desktopConnectionStatus) var connectionStatus
        $connectionStatus.withLock { $0 = .connected }

        var client = desktopClient
        client.observeMessages = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.snapshot([]))
            }
        }
        client.observeSessions = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield([session])
            }
        }
        client.observeWorkspaces = {
            AsyncThrowingStream { continuation in
                continuation.yield(workspaceSnapshot)
            }
        }
        client.ping = { }
        desktopClient = client
    }
}
#endif
