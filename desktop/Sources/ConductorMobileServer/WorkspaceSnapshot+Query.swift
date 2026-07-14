//
//  WorkspaceSnapshot+Query.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import SQLiteData

extension WorkspaceSnapshot {
    static var mostRecentlyUpdated: some SelectStatement<Self, Workspace, ()> {
        Workspace
            .order { $0.updatedAt.desc() }
            .limit(200)
            .select { workspace in
                // These correlated EXISTS expressions remain part of this single workspace query. The
                // sessions workspace index makes each lookup direct, and EXISTS stops at its first match.
                let hasUnread =
                    Session
                    .where { session in
                        session.workspaceID.eq(workspace.id)
                            && session.unreadCount.gt(0)
                            && !session.isHidden
                    }
                    // EXISTS only needs to know whether a row exists, so SELECT 1 avoids selecting a session.
                    .select { _ in 1 }
                    .exists()
                    // Conductor stores `unread` as a nullable integer rather than a SQLite boolean.
                    .cast(as: Int?.self)
                let isWorking =
                    Session
                    .where { session in
                        session.workspaceID.eq(workspace.id)
                            && session.status.eq(Session.Status.working)
                    }
                    .select { _ in 1 }
                    .exists()

                return Columns(
                    workspace: Workspace.Selection(
                        id: workspace.id,
                        activeSessionID: workspace.activeSessionID,
                        archiveCommit: workspace.archiveCommit,
                        assigneeUserID: workspace.assigneeUserID,
                        bigTerminalMode: workspace.bigTerminalMode,
                        branch: workspace.branch,
                        createdAt: workspace.createdAt,
                        creatorClientID: workspace.creatorClientID,
                        creatorUserID: workspace.creatorUserID,
                        derivedStatus: workspace.derivedStatus,
                        directoryName: workspace.directoryName,
                        hostingServerURL: workspace.hostingServerURL,
                        initializationFilesCopied: workspace.initializationFilesCopied,
                        initializationLogPath: workspace.initializationLogPath,
                        initializationParentBranch: workspace.initializationParentBranch,
                        intendedTargetBranch: workspace.intendedTargetBranch,
                        linkedDirectoryPaths: workspace.linkedDirectoryPaths,
                        linkedWorkspaceIDs: workspace.linkedWorkspaceIDs,
                        manualStatus: workspace.manualStatus,
                        notes: workspace.notes,
                        organizationID: workspace.organizationID,
                        permissionLevel: workspace.permissionLevel,
                        pinnedAt: workspace.pinnedAt,
                        placeholderBranchName: workspace.placeholderBranchName,
                        prDescription: workspace.prDescription,
                        prTitle: workspace.prTitle,
                        remoteFileSyncEnabled: workspace.remoteFileSyncEnabled,
                        repositoryID: workspace.repositoryID,
                        sandboxProvider: workspace.sandboxProvider,
                        secondaryDirectoryName: workspace.secondaryDirectoryName,
                        setupLogPath: workspace.setupLogPath,
                        state: workspace.state,
                        unread: hasUnread,
                        updatedAt: workspace.updatedAt,
                        userSetBranchName: workspace.userSetBranchName,
                        userSetWorkspaceName: workspace.userSetWorkspaceName,
                        watcherUserIDs: workspace.watcherUserIDs,
                        workspaceName: workspace.workspaceName,
                        workspacePath: workspace.workspacePath
                    ),
                    isWorking: isWorking
                )
            }
    }
}
