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
    public var pullRequests: [Workspace.ID: PullRequestSnapshot]
    public var repositories: [Repository]
    public var workspaces: [WorkspaceSnapshot]

    public init(
        repositories: [Repository],
        workspaces: [WorkspaceSnapshot],
        pullRequests: [Workspace.ID: PullRequestSnapshot] = [:]
    ) {
        self.pullRequests = pullRequests
        self.repositories = repositories
        self.workspaces = workspaces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            repositories: try container.decode([Repository].self, forKey: .repositories),
            workspaces: try container.decode([WorkspaceSnapshot].self, forKey: .workspaces),
            pullRequests: try container.decodeIfPresent(
                [Workspace.ID: PullRequestSnapshot].self,
                forKey: .pullRequests
            ) ?? [:]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case pullRequests = "pull_requests"
        case repositories
        case workspaces
    }
}
