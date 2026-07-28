//
//  CloudSessionMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import SharedConductorData
import SQLiteData

@Table("cloud_session_metadata")
public struct CloudSessionMetadata: Equatable, Identifiable, Sendable {
    @Column("session_id", primaryKey: true)
    public let sessionID: Session.ID
    @Column("workspace_id")
    public var workspaceID: Workspace.ID
    @Column("account_id")
    public var accountID: String
    @Column("last_seen_generation")
    public var lastSeenGeneration: String

    public init(
        sessionID: Session.ID,
        workspaceID: Workspace.ID,
        accountID: String,
        lastSeenGeneration: String
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.lastSeenGeneration = lastSeenGeneration
    }

    public var id: Session.ID { sessionID }
}
