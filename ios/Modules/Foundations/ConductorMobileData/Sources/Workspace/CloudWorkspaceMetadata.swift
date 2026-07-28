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
    @Column("last_seen_generation")
    public var lastSeenGeneration: String

    public init(
        workspaceID: Workspace.ID,
        accountID: String,
        lastSeenGeneration: String
    ) {
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.lastSeenGeneration = lastSeenGeneration
    }

    public var id: Workspace.ID { workspaceID }
}

extension CloudWorkspaceMetadata {
    public static func clearCachedRows(
        in database: Database,
        keepingAccountID: String? = nil
    ) throws {
        try CloudChatPersistence.clearCachedRows(
            in: database,
            keepingAccountID: keepingAccountID
        )
        let metadata = if let keepingAccountID {
            try Self
                .where { $0.accountID.neq(keepingAccountID) }
                .fetchAll(database)
        } else {
            try Self.all.fetchAll(database)
        }
        try removeCachedRows(metadata, from: database)
    }

    public static func removeCachedRows(
        _ metadata: [Self],
        from database: Database
    ) throws {
        for item in metadata {
            try CloudChatPersistence.removeCachedRows(
                workspaceID: item.workspaceID,
                accountID: item.accountID,
                in: database
            )
            try Self.find(item.id).delete().execute(database)

            let hasDesktopObservation = try MobileWorkspaceState
                .find(item.workspaceID)
                .fetchOne(database) != nil
            let hasSessions = try Session
                .where { $0.workspaceID.eq(item.workspaceID) }
                .fetchCount(database) > 0
            guard !hasDesktopObservation, !hasSessions else {
                let workspace = try Workspace
                    .find(item.workspaceID)
                    .fetchOne(database)
                if workspace?.hostingServerURL
                    == Workspace.conductorCloudHostingServerURL {
                    try Workspace
                        .find(item.workspaceID)
                        .update {
                            $0.hostingServerURL = #bind(nil as String?)
                        }
                        .execute(database)
                }
                continue
            }

            try Workspace.find(item.workspaceID).delete().execute(database)
        }
    }
}
