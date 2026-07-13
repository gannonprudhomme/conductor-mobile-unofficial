//
//  WorkspacesTests.swift
//  ConductorWorkspacesTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import SharedConductorData
import ConductorMobileData
import CustomDump
import Dependencies
import Foundation
import SQLiteData
@testable import ConductorWorkspaces
import Testing

@MainActor
struct WorkspacesTests {
    @Test("Workspace display options persist between state instances")
    func displayOptionsPersist() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let initialState = Workspaces.State()
            initialState.$grouping.withLock { $0 = .project }
            let store = TestStore(initialState: initialState) {
                Workspaces()
            }

            await store.send(.repositoryFilterButtonTapped("repo-1")) {
                $0.$selectedRepositoryID.withLock { $0 = "repo-1" }
            }
            await store.send(.sortButtonTapped(.created)) {
                $0.$sort.withLock { $0 = .created }
            }
            await store.finish()

            let collapsedSectionIDs: Set<String> = [
                "status:in-progress",
                "project:repo-1",
            ]
            let collapsedState = Workspaces.State()
            collapsedState.$collapsedSectionIDs.withLock { $0 = collapsedSectionIDs }

            let restoredState = Workspaces.State()
            expectNoDifference(restoredState.collapsedSectionIDs, collapsedSectionIDs)
            expectNoDifference(restoredState.grouping, .project)
            expectNoDifference(restoredState.selectedRepositoryID, "repo-1")
            expectNoDifference(restoredState.sort, .created)
        }
    }

    @Test("Status sections retain Linear's known order and include empty sections")
    func statusSections() {
        let waiting = Workspace.Status(rawValue: "waiting-on-user")
        let sections = Workspaces.State.sections(
            groupedBy: .status,
            workspaces: [
                workspace(id: "done", status: .done),
                workspace(id: "progress", status: .inProgress),
                workspace(id: "backlog", status: .backlog),
                workspace(id: "waiting", status: waiting),
            ]
        )

        expectNoDifference(
            sections.map(\.id),
            Workspace.Status.displayOrder.map { "status:\($0.rawValue)" }
                + ["status:\(waiting.rawValue)"]
        )
        expectNoDifference(
            sections.map { $0.items.map(\.id) },
            [["done"], [], ["progress"], ["backlog"], [], ["waiting"]]
        )
    }

    @Test("Project sections coalesce noncontiguous workspace rows")
    func projectSections() {
        let firstRepository = Repository.preview(id: "repo-1", name: "First")
        let secondRepository = Repository.preview(id: "repo-2", name: "Second")
        let sections = Workspaces.State.sections(
            groupedBy: .project,
            workspaces: [
                workspace(id: "first-1", repository: firstRepository),
                workspace(id: "second", repository: secondRepository),
                workspace(id: "first-2", repository: firstRepository),
                workspace(id: "unknown", repositoryID: "missing-repo"),
            ]
        )

        expectNoDifference(
            sections.map(\.id),
            ["project:repo-1", "project:repo-2", "project:missing-repo"]
        )
        expectNoDifference(
            sections.map { $0.items.map(\.id) },
            [["first-1", "first-2"], ["second"], ["unknown"]]
        )
        expectNoDifference(
            sections.map { section in
                guard case let .project(_, _, title) = section.groupByType else {
                    return ""
                }
                return title
            },
            ["First", "Second", "missing-repo"]
        )
    }

    @Test("Grouping changes update sections through the reducer")
    func groupingChangesUpdateSections() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Repository
                    .insert { Repository.preview(id: "repo", name: "Conductor") }
                    .execute(db)
                let workspace = Workspace.preview(
                    id: "workspace",
                    derivedStatus: Workspace.Status.inProgress.rawValue,
                    repositoryID: "repo"
                )
                try Workspace
                    .insert { workspace }
                    .execute(db)
                try MobileWorkspaceState
                    .insert {
                        MobileWorkspaceState(workspaceID: workspace.id, isWorking: false)
                    }
                    .execute(db)
            }
        } operation: {
            let clock = TestClock()
            let initialState = Workspaces.State()
            let grouping = initialState.$grouping
            let projectSections = Workspaces.State.sections(
                groupedBy: .project,
                workspaces: initialState.workspaces
            )
            let store = TestStore(initialState: initialState) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.fetchRepositories = { [] }
                $0.desktopClient.fetchWorkspaces = { [] }
            }

            let task = await store.send(.task)
            grouping.withLock { $0 = .project }

            await store.receive(\.groupingChanged, .project) {
                $0.sections = projectSections
            }

            await task.cancel()
        }
    }

    @Test("When refresh fails to load workspaces, an alert is presented")
    func refreshFailsToLoadWorkspaces() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.desktopClient.fetchWorkspaces = {
                    throw TestError()
                }
                $0.desktopClient.fetchRepositories = { [] }
            }

            await store.send(.refresh)

            await store.receive(\.loadWorkspacesFailed) {
                $0.alert = .failedToLoadWorkspaces(error: TestError())
            }
        }
    }

    @Test("Workspaces poll every second")
    func workspacesPollEverySecond() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.fetchWorkspaces = {
                    throw TestError()
                }
                $0.desktopClient.fetchRepositories = { [] }
            }

            let task = await store.send(.task)

            await store.receive(\.loadWorkspacesFailed) {
                $0.alert = .failedToLoadWorkspaces(error: TestError())
            }

            await clock.advance(by: .seconds(1))
            await store.receive(\.loadWorkspacesFailed)

            await task.cancel()
        }
    }

    @Test("Workspace context menu actions call the desktop service")
    func workspaceContextMenuActions() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let requests = LockIsolated<[String]>([])
            let item = workspace(id: "workspace", status: .inProgress)
            let now = Date(timeIntervalSince1970: 1_783_555_200)
            try await database.write { db in
                try Workspace
                    .insert { item.workspace }
                    .execute(db)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.date.now = now
                $0.desktopClient.fetchRepositories = { [] }
                $0.desktopClient.fetchWorkspaces = { [] }
                $0.desktopClient.setWorkspacePinned = { workspaceID, pinned in
                    requests.withValue { $0.append("pinned:\(workspaceID):\(pinned)") }
                }
                $0.desktopClient.setWorkspaceStatus = { workspaceID, status in
                    requests.withValue {
                        $0.append("status:\(workspaceID):\(status.rawValue)")
                    }
                }
                $0.desktopClient.setWorkspaceUnread = { workspaceID, unread in
                    requests.withValue { $0.append("unread:\(workspaceID):\(unread)") }
                }
            }

            await store.send(.workspacePinnedButtonTapped(item))
            await store.finish()

            await store.send(.workspaceStatusButtonTapped(item, .done))
            await store.finish()

            await store.send(.workspaceUnreadButtonTapped(item))
            await store.finish()

            let fetchedWorkspace = try await database.read { db in
                try Workspace
                    .find(item.id)
                    .fetchOne(db)
            }
            let updatedWorkspace = try #require(fetchedWorkspace)
            expectNoDifference(updatedWorkspace.pinnedAt, now.ISO8601Format())
            expectNoDifference(updatedWorkspace.manualStatus, Workspace.Status.done.rawValue)
            expectNoDifference(updatedWorkspace.unread, 1)
            expectNoDifference(
                requests.value,
                [
                    "pinned:workspace:true",
                    "status:workspace:done",
                    "unread:workspace:true",
                ]
            )
        }
    }

    @Test("Workspace update failures present an alert")
    func workspaceUpdateFailure() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let item = workspace(id: "workspace")
            try await database.write { db in
                try Workspace
                    .insert { item.workspace }
                    .execute(db)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.date.now = Date(timeIntervalSince1970: 1_783_555_200)
                $0.desktopClient.setWorkspacePinned = { _, _ in
                    throw TestError()
                }
            }

            await store.send(.workspacePinnedButtonTapped(item))

            await store.receive(\.setWorkspacePinnedFailed) {
                $0.alert = .failedToUpdateWorkspacePin(
                    error: TestError()
                )
            }

            let fetchedWorkspace = try await database.read { db in
                try Workspace
                    .find(item.id)
                    .fetchOne(db)
            }
            let updatedWorkspace = try #require(fetchedWorkspace)
            #expect(updatedWorkspace.pinnedAt != nil)
        }
    }
}

private func workspace(
    id: String,
    status: Workspace.Status = .inProgress,
    repository: Repository? = nil,
    repositoryID: Repository.ID? = nil
) -> WorkspaceWithRepository {
    WorkspaceWithRepository(
        workspace: .preview(
            id: id,
            derivedStatus: status.rawValue,
            repositoryID: repository?.id ?? repositoryID
        ),
        repository: repository
    )
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
