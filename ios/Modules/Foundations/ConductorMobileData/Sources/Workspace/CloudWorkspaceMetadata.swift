//
//  CloudWorkspaceMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Foundation
import SharedConductorData
import SQLiteData

@Table("cloud_workspace_metadata")
public struct CloudWorkspaceMetadata: Equatable, Identifiable, Sendable {
    @Column("workspace_id", primaryKey: true)
    public let workspaceID: Workspace.ID
    @Column("account_id")
    public var accountID: String
    @Column("remote_workspace_id")
    public var remoteWorkspaceID: String
    @Column("last_seen_generation")
    public var lastSeenGeneration: String

    public init(
        workspaceID: Workspace.ID,
        accountID: String,
        remoteWorkspaceID: String? = nil,
        lastSeenGeneration: String
    ) {
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.remoteWorkspaceID = remoteWorkspaceID ?? workspaceID
        self.lastSeenGeneration = lastSeenGeneration
    }

    public var id: Workspace.ID { workspaceID }
}

extension CloudWorkspaceMetadata {
    public static func clearCachedRows(
        in database: Database,
        keepingAccountID: String? = nil
    ) throws {
        let metadata = if let keepingAccountID {
            try Self
                .where { $0.accountID.neq(keepingAccountID) }
                .fetchAll(database)
        } else {
            try Self.all.fetchAll(database)
        }
        let accountIDs = Set(metadata.map(\.accountID))
        for accountID in accountIDs {
            try CloudOwnershipCleanup.perform(
                scope: .account(accountID),
                reason: .credentialRemoval,
                in: database
            )
        }
    }

    public static func removeCachedRows(
        _ metadata: [Self],
        from database: Database
    ) throws {
        try CloudOwnershipCleanup.perform(
            scope: .workspaces(Set(metadata.map(\.workspaceID))),
            reason: .authoritativeSnapshot,
            in: database
        )
    }
}
