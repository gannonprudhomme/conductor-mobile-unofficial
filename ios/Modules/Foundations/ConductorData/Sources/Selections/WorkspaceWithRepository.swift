import ConductorFoundation
import SQLiteData
import SwiftUI

@Selection
public struct WorkspaceWithRepository: Identifiable, Equatable, Sendable {
    public enum Sort: String, CaseIterable, Codable, Equatable, Sendable {
        case updated
        case created

        public var title: LocalizedStringKey {
            switch self {
            case .updated:
                "Updated"

            case .created:
                "Created"
            }
        }
    }

    public var workspace: Workspace
    public var repository: Repository?

    public init(workspace: Workspace, repository: Repository?) {
        self.workspace = workspace
        self.repository = repository
    }

    public var id: Workspace.ID { workspace.id }

    public var repositoryDisplayName: String {
        repository?.name?.nilIfEmpty
            ?? workspace.repositoryID?.nilIfEmpty
            ?? "Unknown repository"
    }

    public static func all(
        repositoryID: Repository.ID? = nil,
        sortedBy sort: Sort = .updated
    ) -> some SelectStatement<Self, Workspace, Repository?> {
        var query = Workspace
            .where { $0.state.neq(Workspace.State.archived) }

        if let repositoryID {
            query = query.where { $0.repositoryID.eq(repositoryID) }
        }

        return query
            .order { workspaces in
                switch sort {
                case .created:
                    workspaces.createdAt.desc()

                case .updated:
                    workspaces.updatedAt.desc()
                }
            }
            .leftJoin(Repository.all) { $0.repositoryID.eq($1.id) }
            .select { Columns(workspace: $0, repository: $1) }
    }
}
