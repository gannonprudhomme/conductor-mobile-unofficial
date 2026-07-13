//
//  WorkspaceListSnapshot.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/13/26.
//

/// API response for `ws://workspaces`.
///
/// Used to populate `Workspaces.swift` on iOS (aka the workspace list)
public struct WorkspaceListSnapshot: Codable, Equatable, Sendable {
    public var repositories: [Repository]
    public var workspaces: [WorkspaceSnapshot]

    public init(
        repositories: [Repository],
        workspaces: [WorkspaceSnapshot]
    ) {
        self.repositories = repositories
        self.workspaces = workspaces
    }
}
