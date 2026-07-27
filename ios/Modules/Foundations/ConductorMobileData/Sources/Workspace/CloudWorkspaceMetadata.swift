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
    @Column("cloud_project_id")
    public var cloudProjectID: String
    @Column("deep_link")
    public var deepLink: String
    @Column("lifecycle_step")
    public var lifecycleStep: String?
    @Column("lifecycle_error")
    public var lifecycleError: String?
    @Column(
        "lifecycle_updated_at",
        as: Date.ConductorDatabaseRepresentation?.self
    )
    public var lifecycleUpdatedAt: Date?
    @Column("last_seen_generation")
    public var lastSeenGeneration: String

    public init(
        workspaceID: Workspace.ID,
        accountID: String,
        cloudProjectID: String,
        deepLink: String,
        lifecycleStep: String? = nil,
        lifecycleError: String? = nil,
        lifecycleUpdatedAt: Date? = nil,
        lastSeenGeneration: String
    ) {
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.cloudProjectID = cloudProjectID
        self.deepLink = deepLink
        self.lifecycleStep = lifecycleStep
        self.lifecycleError = lifecycleError
        self.lifecycleUpdatedAt = lifecycleUpdatedAt
        self.lastSeenGeneration = lastSeenGeneration
    }

    public var id: Workspace.ID { workspaceID }
}
