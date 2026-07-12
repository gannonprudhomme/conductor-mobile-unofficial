//
//  WorkspaceWithRepository.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorFoundation
import SQLiteData

@Selection
public struct WorkspaceWithRepository: Identifiable, Equatable, Sendable {
    public enum Grouping: String, CaseIterable, Codable, Equatable, Sendable {
        case status
        case project
    }

    public enum Sort: String, CaseIterable, Codable, Equatable, Sendable {
        case updated
        case created
    }

    public var workspace: Workspace
    public var mobileState: MobileWorkspaceState?
    public var repository: Repository?

    public init(
        workspace: Workspace,
        repository: Repository?,
        mobileState: MobileWorkspaceState? = nil
    ) {
        self.workspace = workspace
        self.mobileState = mobileState
        self.repository = repository
    }

    public var id: Workspace.ID { workspace.id }
    public var isWorking: Bool { mobileState?.isWorking ?? false }

    public var repositoryDisplayName: String {
        repository?.name?.nilIfEmpty
            ?? workspace.repositoryID?.nilIfEmpty
            ?? "Unknown repository"
    }
}

extension WorkspaceWithRepository {
    public static func all(
        workspaceID: Workspace.ID? = nil,
        repositoryID: Repository.ID? = nil,
        sortedBy sort: Sort = .updated,
        groupedBy grouping: Grouping = .status
    ) -> some SelectStatement<
        Self,
        Workspace,
        (MobileWorkspaceState?, Repository?)
    > {
        var query = Workspace
            .where { $0.state.neq(Workspace.State.archived) }

        if let repositoryID {
            query = query.where { $0.repositoryID.eq(repositoryID) }
        }

        if let workspaceID {
            query = query.where { $0.id.eq(workspaceID) }
        }

        return query
            .leftJoin(MobileWorkspaceState.all) { workspace, mobileState in
                workspace.id.eq(mobileState.workspaceID)
            }
            .leftJoin(Repository.all) { workspace, _, repository in
                workspace.repositoryID.eq(repository.id)
            }
            // Keep every workspace row while ordering equal group keys contiguously. A SQL
            // GROUP BY would collapse the rows that each SwiftUI section needs to render.
            .order { workspaces, _, repositories in
                switch grouping {
                case .status:
                    // Match Workspace.status: treat empty values as missing, prefer Conductor's
                    // manual override, then use its derived status, and finally fall back to the
                    // same in-progress default used by the model.
                    let status = #sql(
                        """
                        coalesce(
                          nullif(\(workspaces.manualStatus), ''),
                          nullif(\(workspaces.derivedStatus), ''),
                          'in-progress'
                        )
                        """,
                        as: String.self
                    )
                    // Translate known statuses into Conductor's display order. Unknown future
                    // statuses follow the known ones alphabetically instead of being discarded.
                    let statusOrder = Case(status)
                        .when(Workspace.Status.done.rawValue, then: 0)
                        .when(Workspace.Status.inReview.rawValue, then: 1)
                        .when(Workspace.Status.inProgress.rawValue, then: 2)
                        .when(Workspace.Status.backlog.rawValue, then: 3)
                        .when(Workspace.Status.canceled.rawValue, then: 4)
                        .else(5)

                    // The status keys keep each section contiguous; the selected timestamp then
                    // orders the workspace rows inside each section.
                    switch sort {
                    case .created:
                        (statusOrder, status.lower(), workspaces.createdAt.desc())

                    case .updated:
                        (statusOrder, status.lower(), workspaces.updatedAt.desc())
                    }

                case .project:
                    // Repository display order, name, and ID keep each project contiguous and put
                    // missing repositories last. The selected timestamp orders rows within them.
                    switch sort {
                    case .created:
                        (
                            repositories.displayOrder.asc(nulls: .last),
                            repositories.name.lower().asc(nulls: .last),
                            workspaces.repositoryID.asc(nulls: .last),
                            workspaces.createdAt.desc()
                        )

                    case .updated:
                        (
                            repositories.displayOrder.asc(nulls: .last),
                            repositories.name.lower().asc(nulls: .last),
                            workspaces.repositoryID.asc(nulls: .last),
                            workspaces.updatedAt.desc()
                        )
                    }
                }
            }
            .select { workspace, mobileState, repository in
                Columns(
                    workspace: workspace,
                    mobileState: mobileState,
                    repository: repository
                )
            }
    }
}
