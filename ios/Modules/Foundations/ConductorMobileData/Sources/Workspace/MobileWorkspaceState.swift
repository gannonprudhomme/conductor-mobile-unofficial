//
//  MobileWorkspaceState.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import SQLiteData

/// Mobile-only state associated with a row in Conductor's `workspaces` table.
@Table("mobile_workspace_state")
public struct MobileWorkspaceState: Equatable, Identifiable, Sendable {
    /// The corresponding workspace ID. It remains stored in an `id` column so it is the table's
    /// primary key while making its relationship to `Workspace.id` explicit in Swift.
    @Column("id", primaryKey: true)
    public let workspaceID: Workspace.ID
    @Column("is_working")
    public var isWorking: Bool

    public init(workspaceID: Workspace.ID, isWorking: Bool) {
        self.workspaceID = workspaceID
        self.isWorking = isWorking
    }

    public var id: Workspace.ID { workspaceID }
}
