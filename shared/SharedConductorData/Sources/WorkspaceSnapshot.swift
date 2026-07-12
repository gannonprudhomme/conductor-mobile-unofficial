//
//  WorkspaceSnapshot.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData

@Selection
public struct WorkspaceSnapshot: Equatable, Sendable {
    public var workspace: Workspace
    /// Computed, not actually on Conductor's workspace table
    public var isWorking: Bool

    public init(workspace: Workspace, isWorking: Bool) {
        self.workspace = workspace
        self.isWorking = isWorking
    }
}

extension WorkspaceSnapshot: Codable {
    public init(from decoder: any Decoder) throws {
        let workspace = try Workspace(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workspace: workspace,
            isWorking: try container.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try workspace.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isWorking, forKey: .isWorking)
    }

    private enum CodingKeys: String, CodingKey {
        case isWorking = "is_working"
    }
}
