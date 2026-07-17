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
import Sharing
import SQLiteData
@testable import ConductorWorkspaces
import Testing

@MainActor
struct WorkspacesTests {
    @Test("Connection display follows the shared desktop settings")
    func connectionDisplay() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            @Shared(.desktopDisplayConfiguration) var displayConfiguration
            let state = Workspaces.State()

            expectNoDifference(state.displayConfiguration, nil)

            $connectionStatus.withLock { $0 = .connected }
            expectNoDifference(state.connectionStatus, .connected)

            $connectionStatus.withLock { $0 = .disconnected }
            expectNoDifference(state.connectionStatus, .disconnected)

            $displayConfiguration.withLock {
                $0 = DesktopClient.DisplayConfiguration(
                    name: "Office desktop",
                    icon: .desktop
                )
            }
            expectNoDifference(
                state.displayConfiguration,
                Optional(
                    DesktopClient.DisplayConfiguration(
                        name: "Office desktop",
                        icon: .desktop
                    )
                )
            )
        }
    }

    @Test("Workspace display options persist between state instances")
    func displayOptionsPersist() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let initialState = Workspaces.State()
            initialState.$grouping.withLock { $0 = .project }
            initialState.$selectedRepositoryID.withLock { $0 = "repo-1" }
            let store = TestStore(initialState: initialState) {
                Workspaces()
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
            let (stream, _) = AsyncThrowingStream<
                WorkspaceListSnapshot,
                any Error
            >.makeStream()
            let initialState = Workspaces.State()
            let grouping = initialState.$grouping
            let projectSections = Workspaces.State.sections(
                groupedBy: .project,
                workspaces: initialState.workspaces
            )
            let store = TestStore(initialState: initialState) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = TestClock()
                $0.desktopClient.observeWorkspaces = { stream }
            }

            let task = await store.send(.task)
            grouping.withLock { $0 = .project }

            await store.receive(\.groupingChanged, .project) {
                $0.sections = projectSections
            }

            await task.cancel()
        }
    }

    @Test("Repository filter shows only workspaces with the selected repository ID")
    func repositoryFilterShowsMatchingWorkspaces() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let firstRepository = Repository.preview(id: "repo-1", name: "First")
            let secondRepository = Repository.preview(id: "repo-2", name: "Second")
            let firstWorkspace = Workspace.preview(
                id: "workspace-1",
                derivedStatus: Workspace.Status.inProgress.rawValue,
                repositoryID: firstRepository.id,
                updatedAt: Date(timeIntervalSince1970: 2)
            )
            let secondWorkspace = Workspace.preview(
                id: "workspace-2",
                derivedStatus: Workspace.Status.inProgress.rawValue,
                repositoryID: secondRepository.id,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
            try await database.write { db in
                try Repository
                    .insert { [firstRepository, secondRepository] }
                    .execute(db)
                try Workspace
                    .insert { [firstWorkspace, secondWorkspace] }
                    .execute(db)
            }

            let (stream, _) = AsyncThrowingStream<
                WorkspaceListSnapshot,
                any Error
            >.makeStream()
            let initialState = Workspaces.State()
            let store = TestStore(initialState: initialState) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = TestClock()
                $0.desktopClient.observeWorkspaces = { stream }
                $0.desktopClient.ping = {}
            }

            let task = await store.send(.task)
            let firstItem = WorkspaceWithRepository(
                workspace: firstWorkspace,
                repository: firstRepository
            )
            let secondItem = WorkspaceWithRepository(
                workspace: secondWorkspace,
                repository: secondRepository
            )

            await store.send(.repositoryFilterButtonTapped(firstRepository.id)) {
                $0.$selectedRepositoryID.withLock { $0 = firstRepository.id }
            }
            await store.receive(\.workspacesChanged) {
                $0.sections = Workspaces.State.sections(
                    groupedBy: .status,
                    workspaces: [firstItem]
                )
            }
            expectNoDifference(store.state.workspaces.map(\.id), [firstWorkspace.id])

            await store.send(.repositoryFilterButtonTapped(nil)) {
                $0.$selectedRepositoryID.withLock { $0 = nil }
            }
            await store.receive(\.workspacesChanged) {
                $0.sections = Workspaces.State.sections(
                    groupedBy: .status,
                    workspaces: [firstItem, secondItem]
                )
            }
            expectNoDifference(
                store.state.workspaces.map(\.id),
                [firstWorkspace.id, secondWorkspace.id]
            )

            await task.cancel()
        }
    }

    @Test("Workspace snapshots reconnect after failures and cancel")
    func workspaceSnapshotsStreamReconnectAndCancel() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let repository = Repository.preview(id: "repository", name: "Conductor")
            let workspace = Workspace.preview(
                id: "workspace",
                derivedStatus: Workspace.Status.inProgress.rawValue,
                repositoryID: repository.id
            )
            var updatedWorkspace = workspace
            updatedWorkspace.derivedStatus = Workspace.Status.done.rawValue
            let firstSnapshot = WorkspaceListSnapshot(
                repositories: [repository],
                workspaces: [WorkspaceSnapshot(workspace: workspace, isWorking: false)]
            )
            let secondSnapshot = WorkspaceListSnapshot(
                repositories: [repository],
                workspaces: [WorkspaceSnapshot(workspace: updatedWorkspace, isWorking: true)]
            )
            let firstExpectedWorkspace = WorkspaceWithRepository(
                workspace: workspace,
                repository: repository,
                mobileState: MobileWorkspaceState(workspaceID: workspace.id, isWorking: false)
            )
            let secondExpectedWorkspace = WorkspaceWithRepository(
                workspace: updatedWorkspace,
                repository: repository,
                mobileState: MobileWorkspaceState(workspaceID: workspace.id, isWorking: true)
            )
            let (firstStream, firstContinuation) = AsyncThrowingStream<
                WorkspaceListSnapshot,
                any Error
            >.makeStream()
            let (secondStream, secondContinuation) = AsyncThrowingStream<
                WorkspaceListSnapshot,
                any Error
            >.makeStream()
            let connectionCount = LockIsolated(0)
            let secondConnectionCancelled = LockIsolated(false)
            secondContinuation.onTermination = { termination in
                guard case .cancelled = termination else {
                    return
                }

                secondConnectionCancelled.setValue(true)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.observeWorkspaces = {
                    let count = connectionCount.withValue {
                        $0 += 1
                        return $0
                    }
                    return count == 1 ? firstStream : secondStream
                }
            }

            let task = await store.send(.task)

            firstContinuation.yield(firstSnapshot)
            await store.receive(\.workspacesChanged) {
                $0.sections = Workspaces.State.sections(
                    groupedBy: .status,
                    workspaces: [firstExpectedWorkspace]
                )
            }
            await store.receive(\.initialWorkspacesResponse) {
                $0.isLoadingWorkspaces = false
            }
            #expect(connectionCount.value == 1)

            firstContinuation.finish(throwing: URLError(.networkConnectionLost))
            await store.receive(\.loadWorkspacesFailed)
            #expect(connectionCount.value == 1)

            await clock.advance(by: .seconds(1))
            secondContinuation.yield(secondSnapshot)
            await store.receive(\.workspacesChanged) {
                $0.sections = Workspaces.State.sections(
                    groupedBy: .status,
                    workspaces: [secondExpectedWorkspace]
                )
            }
            #expect(connectionCount.value == 2)

            await task.cancel()
            #expect(secondConnectionCancelled.value)
        }
    }

    @Test("Task pings the desktop immediately and every three seconds")
    func connectionHeartbeat() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let clock = TestClock()
            let pingCount = LockIsolated(0)
            let (stream, continuation) = AsyncThrowingStream<
                WorkspaceListSnapshot,
                any Error
            >.makeStream()
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = clock
                $0.desktopClient.observeWorkspaces = { stream }
                $0.desktopClient.ping = {
                    pingCount.withValue { $0 += 1 }
                }
            }

            let task = await store.send(.task)
            await clock.advance()
            #expect(pingCount.value == 1)

            await clock.advance(by: .seconds(2))
            #expect(pingCount.value == 1)

            await clock.advance(by: .seconds(1))
            #expect(pingCount.value == 2)

            await task.cancel()
            continuation.finish()
            await clock.advance(by: .seconds(3))
            #expect(pingCount.value == 2)
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
                $0.desktopClient.setWorkspacePinned = { workspaceID, isPinned in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.pinnedAt == now.ISO8601Format())
                    requests.withValue { $0.append("pinned:\(workspaceID):\(isPinned)") }
                    return .hook
                }
                $0.desktopClient.setWorkspaceStatus = { workspaceID, status in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.manualStatus == status.rawValue)
                    requests.withValue {
                        $0.append("status:\(workspaceID):\(status.rawValue)")
                    }
                    return .hook
                }
                $0.desktopClient.setWorkspaceUnread = { workspaceID, isUnread in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.unread == 1)
                    requests.withValue { $0.append("unread:\(workspaceID):\(isUnread)") }
                    return .hook
                }
                $0.date.now = now
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

    @Test("A failed pin update restores the previous value")
    func failedPinUpdateRollsBack() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let item = workspace(id: "workspace")
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
                $0.desktopClient.setWorkspacePinned = { workspaceID, _ in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.pinnedAt == now.ISO8601Format())
                    throw TestError()
                }
            }

            await store.send(.workspacePinnedButtonTapped(item))

            await store.receive(\.workspaceMutationFailed) {
                $0.alert = .failedToUpdateWorkspace(
                    error: TestError()
                )
            }

            let workspace = try await database.read { db in
                try Workspace.find(item.id).fetchOne(db)
            }
            #expect(workspace?.pinnedAt == nil)
        }
    }

    @Test("A failed status update restores the previous value")
    func failedStatusUpdateRollsBack() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let item = workspace(id: "workspace", status: .inProgress)
            try await database.write { db in
                try Workspace
                    .insert { item.workspace }
                    .execute(db)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.desktopClient.setWorkspaceStatus = { workspaceID, status in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.manualStatus == status.rawValue)
                    throw TestError()
                }
            }

            await store.send(.workspaceStatusButtonTapped(item, .done))

            await store.receive(\.workspaceMutationFailed) {
                $0.alert = .failedToUpdateWorkspace(
                    error: TestError()
                )
            }

            let workspace = try await database.read { db in
                try Workspace.find(item.id).fetchOne(db)
            }
            #expect(workspace?.manualStatus == nil)
        }
    }

    @Test("A failed unread update restores the previous value")
    func failedUnreadUpdateRollsBack() async throws {
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
                $0.desktopClient.setWorkspaceUnread = { workspaceID, _ in
                    let workspace = try await database.read { db in
                        try Workspace.find(workspaceID).fetchOne(db)
                    }
                    #expect(workspace?.unread == 1)
                    throw TestError()
                }
            }

            await store.send(.workspaceUnreadButtonTapped(item))

            await store.receive(\.workspaceMutationFailed) {
                $0.alert = .failedToUpdateWorkspace(
                    error: TestError()
                )
            }

            let workspace = try await database.read { db in
                try Workspace.find(item.id).fetchOne(db)
            }
            #expect(workspace?.unread == nil)
        }
    }

    @Test("SQLite fallback presents a warning")
    func workspaceFallbackWarning() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database

            let item = workspace(id: "workspace")
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
                $0.desktopClient.setWorkspacePinned = { _, _ in .sqliteFallback }
            }

            await store.send(.workspacePinnedButtonTapped(item))
            await store.receive(\.workspaceMutationUsedSQLiteFallback) {
                $0.alert = .workspaceMutationUsedSQLiteFallback
            }

            let workspace = try await database.read { db in
                try Workspace.find(item.id).fetchOne(db)
            }
            #expect(workspace?.pinnedAt == now.ISO8601Format())
        }
    }

    @Test("Explicit workspace connection failures present an alert")
    func workspaceConnectionFailure() async throws {
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
                    throw URLError(.networkConnectionLost)
                }
            }

            await store.send(.workspacePinnedButtonTapped(item))

            await store.receive(\.workspaceMutationFailed) {
                $0.alert = .failedToUpdateWorkspace(
                    error: URLError(.networkConnectionLost)
                )
            }
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
