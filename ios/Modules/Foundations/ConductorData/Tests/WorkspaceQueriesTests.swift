import ConductorData
import CustomDump
import Foundation
import SQLiteData
import Testing

struct WorkspaceQueriesTests {
    @Test("Workspace with repository uses the repository name for display")
    func repositoryDisplayName() {
        let named = WorkspaceWithRepository(
            workspace: .preview(repositoryID: "repo-1"),
            repository: .preview(id: "repo-1", name: "conductor-mobile")
        )
        let missingName = WorkspaceWithRepository(
            workspace: .preview(repositoryID: "repo-2"),
            repository: .preview(id: "repo-2", name: nil)
        )
        let missingRepository = WorkspaceWithRepository(
            workspace: .preview(repositoryID: nil),
            repository: nil
        )

        expectNoDifference(named.repositoryDisplayName, "conductor-mobile")
        expectNoDifference(missingName.repositoryDisplayName, "repo-2")
        expectNoDifference(missingRepository.repositoryDisplayName, "Unknown repository")
    }

    @Test("Workspace query filters, joins repositories, excludes archived rows, and sorts")
    func query() throws {
        let database = try appDatabase()
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)
        let third = Date(timeIntervalSince1970: 3)
        let fourth = Date(timeIntervalSince1970: 4)

        try database.write { db in
            try Repository.insert { Repository.preview(id: "repo-1", name: "TrialSongs") }.execute(db)
            try Repository.insert { Repository.preview(id: "repo-2", name: "conductor-mobile") }.execute(db)
            try Workspace
                .insert {
                    Workspace.preview(
                        id: "w1",
                        createdAt: first,
                        repositoryID: "repo-1",
                        updatedAt: third,
                        isWorking: true
                    )
                }
                .execute(db)
            try Workspace
                .insert {
                    Workspace.preview(
                        id: "w2",
                        createdAt: second,
                        repositoryID: "repo-1",
                        updatedAt: first
                    )
                }
                .execute(db)
            try Workspace
                .insert {
                    Workspace.preview(
                        id: "w3",
                        createdAt: third,
                        repositoryID: "repo-2",
                        updatedAt: second
                    )
                }
                .execute(db)
            try Workspace
                .insert {
                    Workspace.preview(
                        id: "w4",
                        createdAt: fourth,
                        repositoryID: "repo-1",
                        state: .archived,
                        updatedAt: fourth
                    )
                }
                .execute(db)
        }

        let filteredByRepository = try database.read { db in
            try WorkspaceWithRepository
                .all(repositoryID: "repo-1", sortedBy: .updated)
                .fetchAll(db)
        }
        let sortedByCreation = try database.read { db in
            try WorkspaceWithRepository.all(sortedBy: .created).fetchAll(db)
        }

        expectNoDifference(filteredByRepository.map(\.workspace.id), ["w1", "w2"])
        expectNoDifference(filteredByRepository.first?.workspace.isWorking, true)
        expectNoDifference(filteredByRepository.first?.repository?.name, "TrialSongs")
        expectNoDifference(sortedByCreation.map(\.workspace.id), ["w3", "w2", "w1"])
    }

    @Test("Workspace query orders section groups and rows in SQLite")
    func queryGroupingOrder() throws {
        let database = try appDatabase()
        let dates = (1...7).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        try database.write { db in
            try Repository
                .insert { Repository.preview(id: "repo-z", displayOrder: 1, name: "Zeta") }
                .execute(db)
            try Repository
                .insert { Repository.preview(id: "repo-a", displayOrder: 0, name: "Alpha") }
                .execute(db)

            let workspaces = [
                Workspace.preview(
                    id: "done",
                    derivedStatus: "done",
                    repositoryID: "repo-z",
                    updatedAt: dates[0]
                ),
                Workspace.preview(
                    id: "review",
                    derivedStatus: "in-review",
                    repositoryID: "repo-a",
                    updatedAt: dates[1]
                ),
                Workspace.preview(
                    id: "progress-old",
                    derivedStatus: "in-progress",
                    repositoryID: "repo-z",
                    updatedAt: dates[2]
                ),
                Workspace.preview(
                    id: "backlog",
                    derivedStatus: "backlog",
                    repositoryID: "repo-a",
                    updatedAt: dates[3]
                ),
                Workspace.preview(
                    id: "canceled",
                    derivedStatus: "canceled",
                    repositoryID: "repo-z",
                    updatedAt: dates[4]
                ),
                Workspace.preview(
                    id: "progress-new",
                    derivedStatus: "backlog",
                    manualStatus: "in-progress",
                    repositoryID: "repo-a",
                    updatedAt: dates[5]
                ),
                Workspace.preview(
                    id: "future",
                    derivedStatus: "waiting-on-user",
                    repositoryID: "missing-repo",
                    updatedAt: dates[6]
                ),
            ]
            for workspace in workspaces {
                try Workspace.insert { workspace }.execute(db)
            }
        }

        let groupedByStatus = try database.read { db in
            try WorkspaceWithRepository
                .all(sortedBy: .updated, groupedBy: .status)
                .fetchAll(db)
        }
        let groupedByProject = try database.read { db in
            try WorkspaceWithRepository
                .all(sortedBy: .updated, groupedBy: .project)
                .fetchAll(db)
        }

        expectNoDifference(
            groupedByStatus.map(\.workspace.id),
            [
                "done",
                "review",
                "progress-new",
                "progress-old",
                "backlog",
                "canceled",
                "future",
            ]
        )
        expectNoDifference(
            groupedByProject.map(\.workspace.id),
            [
                "progress-new",
                "backlog",
                "review",
                "canceled",
                "progress-old",
                "done",
                "future",
            ]
        )
    }
}
