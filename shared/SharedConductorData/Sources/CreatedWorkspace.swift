//
//  CreatedWorkspace.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/17/26.
//

public struct CreatedWorkspace: Codable, Equatable, Sendable {
    public let workspace: Workspace
    public let session: Session

    public init(workspace: Workspace, session: Session) {
        self.workspace = workspace
        self.session = session
    }
}
