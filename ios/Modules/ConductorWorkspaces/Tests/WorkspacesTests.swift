//
//  WorkspacesTests.swift
//  ConductorWorkspacesTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorMobileData
import CustomDump
import Dependencies
import Foundation
import SharedConductorData
import Sharing
import SQLiteData
@testable import ConductorWorkspaces
import Testing

@Suite(.serialized)
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

    @Test("Local-only starts only desktop observation")
    func localOnlyObservation() async throws {
        try await assertObservationSources(local: true, cloud: false)
    }

    @Test("Cloud-only starts only Cloud observation")
    func cloudOnlyObservation() async throws {
        try await assertObservationSources(local: false, cloud: true)
    }

    @Test("Combined configuration starts both observations")
    func combinedObservation() async throws {
        try await assertObservationSources(local: true, cloud: true)
    }

    @Test("Missing configuration starts neither observation")
    func missingConfigurationObservation() async throws {
        try await assertObservationSources(local: false, cloud: false)
    }

    @Test("A same-account credential revision restarts Cloud observation")
    func credentialRevisionRestartsCloudObservation() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID(1)
                )
            }
            let connectionCount = LockIsolated(0)
            let (stream, continuation) = AsyncThrowingStream<
                CloudWorkspaceSnapshot,
                any Error
            >.makeStream()
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = TestClock()
                $0.cloudAPIClient.observeWorkspaces = {
                    connectionCount.withValue { $0 += 1 }
                    return stream
                }
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let task = await store.send(.task)
            for _ in 0..<1_000 where connectionCount.value < 1 {
                await Task.yield()
            }
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID(2)
                )
            }
            await store.receive(\.cloudConfigurationChanged)
            for _ in 0..<1_000 where connectionCount.value < 2 {
                await Task.yield()
            }
            #expect(connectionCount.value == 2)

            await task.cancel()
            continuation.finish()
        }
    }

    @Test("Workspace display options persist between state instances")
    func displayOptionsPersist() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Repository
                    .insert { Repository.preview(id: "repo-1") }
                    .execute(database)
            }
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

    @Test("Canonical cloud rows retain desktop activity and pull request enrichment")
    func canonicalCloudRowsRetainDesktopEnrichment() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let repository = Repository.preview(
                id: "repository",
                name: "Conductor",
                remoteURL: "https://github.com/example/conductor.git"
            )
            let workspace = Workspace.preview(
                id: "cloud-workspace",
                derivedStatus: Workspace.Status.inProgress.rawValue,
                hostingServerURL: "https://api.conductor.build",
                repositoryID: repository.id
            )
            let mobileState = MobileWorkspaceState(
                workspaceID: workspace.id,
                isWorking: true,
                pullRequest: PullRequestSnapshot(
                    url: "https://github.com/example/conductor/pull/1",
                    isDraft: true,
                    isMerged: false
                )
            )
            let metadata = CloudWorkspaceMetadata(
                workspaceID: workspace.id,
                accountID: "account",
                lastSeenGeneration: "generation"
            )
            try await database.write { db in
                try Repository.insert { repository }.execute(db)
                try Workspace.insert { workspace }.execute(db)
                try MobileWorkspaceState.insert { mobileState }.execute(db)
                try CloudWorkspaceMetadata.insert { metadata }.execute(db)
            }
            let state = Workspaces.State()
            let item = try #require(state.sections.flatMap(\.items).first)
            #expect(state.sections.flatMap(\.items).count == 1)
            #expect(item.cloudMetadata == metadata)
            #expect(item.isWorking)
            #expect(item.pullRequestStatus == .draft)
            #expect(!item.isCloudOnly)
        }
    }

    @Test("Cached cloud-only rows remain visible during an offline refresh")
    func cachedCloudOnlyRowsRemainVisibleOffline() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let workspace = Workspace.preview(
                id: "cloud-only",
                hostingServerURL: "https://api.conductor.build",
                state: nil
            )
            let metadata = CloudWorkspaceMetadata(
                workspaceID: workspace.id,
                accountID: "account",
                lastSeenGeneration: "generation"
            )
            try await database.write { db in
                try Workspace.insert { workspace }.execute(db)
                try CloudWorkspaceMetadata.insert { metadata }.execute(db)
            }
            var state = Workspaces.State()
            state.$cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }
            state.cloudObservationStatus = .connected
            let store = TestStore(initialState: state) {
                Workspaces()
            }

            let offlineError = URLError(.notConnectedToInternet)
            let failure = Workspaces.CloudFailure.offline(
                offlineError.localizedDescription
            )
            await store.send(.cloudObservationFailed(failure)) {
                $0.cloudObservationStatus = .failed
                $0.hasPresentedCloudFailureAlert = true
                $0.presentedCloudFailure = failure
                $0.destination = .alert(.cloudObservationFailed(failure))
            }
            let item = try #require(store.state.sections.flatMap(\.items).first)
            #expect(item.id == workspace.id)
            #expect(item.isCloudOnly)
            #expect(item.workspace.state == nil)
        }
    }

    @Test("Cloud reachability failures use concise alert copy")
    func cloudReachabilityAlertCopy() {
        let offlineFailure = Workspaces.CloudFailure.offline(
            "The Internet connection appears to be offline."
        )
        let serverFailure = Workspaces.CloudFailure.other(
            "The server returned an invalid response."
        )

        #expect(offlineFailure.title == "Unable to reach Cloud")
        #expect(
            offlineFailure.message
                == "The Internet connection appears to be offline."
        )
        #expect(serverFailure.title == "Unable to reach Cloud")
        #expect(
            serverFailure.message
                == "The server returned an invalid response."
        )
    }

    @Test("Cancelled Cloud observations reconnect without presenting an alert")
    func cancelledCloudObservationReconnectsSilently() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }

            let clock = TestClock()
            let (firstStream, firstContinuation) = AsyncThrowingStream<
                CloudWorkspaceSnapshot,
                any Error
            >.makeStream()
            let (secondStream, secondContinuation) = AsyncThrowingStream<
                CloudWorkspaceSnapshot,
                any Error
            >.makeStream()
            let connectionCount = LockIsolated(0)
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.cloudAPIClient.observeWorkspaces = {
                    let count = connectionCount.withValue {
                        $0 += 1
                        return $0
                    }
                    return count == 1 ? firstStream : secondStream
                }
                $0.continuousClock = clock
            }

            let task = await store.send(.task)
            for _ in 0..<1_000 {
                guard connectionCount.value == 0 else {
                    break
                }
                await Task.yield()
            }
            #expect(connectionCount.value == 1)

            firstContinuation.finish(
                throwing: URLError(.cancelled)
            )
            await clock.advance(by: .seconds(1))
            for _ in 0..<1_000 {
                guard connectionCount.value == 1 else {
                    break
                }
                await Task.yield()
            }
            #expect(connectionCount.value == 2)
            #expect(store.state.destination == nil)

            secondContinuation.yield(
                CloudWorkspaceSnapshot(
                    accountID: "account",
                    projects: [],
                    statuses: [:],
                    workspaces: []
                )
            )
            await store.receive(\.cloudSnapshotReceived) {
                $0.cloudObservationStatus = .connected
            }
            #expect(!store.state.hasPresentedCloudFailureAlert)

            await task.cancel()
        }
    }

    @Test("Foreground reconnection suppresses immediate offline failures")
    func foregroundReconnectionSuppressesTransientFailures() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }

            let now = Date(timeIntervalSinceReferenceDate: 1_000)
            let clock = TestClock()
            let (stream, continuation) = AsyncThrowingStream<
                CloudWorkspaceSnapshot,
                any Error
            >.makeStream()
            var state = Workspaces.State()
            state.cloudObservationStatus = .connected
            let store = TestStore(initialState: state) {
                Workspaces()
            } withDependencies: {
                $0.cloudAPIClient.observeWorkspaces = { stream }
                $0.continuousClock = clock
                $0.date.now = now
            }
            let failure = Workspaces.CloudFailure.offline(
                "The network connection was lost."
            )

            await store.send(.appEnteredBackground) {
                $0.cloudFailureSuppressionDeadline = .distantFuture
                $0.cloudObservationStatus = .loading
            }
            let foregroundTask = await store.send(.appBecameActive) {
                $0.cloudFailureSuppressionDeadline = now
                    .addingTimeInterval(5)
            }
            await store.send(.cloudObservationFailed(failure))

            #expect(store.state.destination == nil)

            continuation.yield(
                CloudWorkspaceSnapshot(
                    accountID: "account",
                    projects: [],
                    statuses: [:],
                    workspaces: []
                )
            )
            await store.receive(\.cloudSnapshotReceived) {
                $0.cloudFailureSuppressionDeadline = nil
                $0.cloudObservationStatus = .connected
            }

            continuation.finish()
            await foregroundTask.cancel()
        }
    }

    @Test("Backgrounding preserves an unrelated alert")
    func backgroundingPreservesUnrelatedAlert() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }

            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            }
            let cloudFailure = Workspaces.CloudFailure.offline(
                "The network is offline."
            )

            await store.send(.cloudObservationFailed(cloudFailure)) {
                $0.cloudObservationStatus = .failed
                $0.hasPresentedCloudFailureAlert = true
                $0.presentedCloudFailure = cloudFailure
                $0.destination = .alert(
                    .cloudObservationFailed(cloudFailure)
                )
            }
            await store.send(.loadWorkspacesFailed(TestError())) {
                $0.destination = .alert(
                    .failedToLoadWorkspaces(error: TestError())
                )
            }
            await store.send(.appEnteredBackground) {
                $0.cloudFailureSuppressionDeadline = .distantFuture
                $0.cloudObservationStatus = .loading
                $0.presentedCloudFailure = nil
            }

            #expect(
                store.state.destination
                    == .alert(.failedToLoadWorkspaces(error: TestError()))
            )
        }
    }

    @Test("Only the first failure in a Cloud outage presents an alert")
    func cloudFailurePresentsOneAlert() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            }
            let firstFailure = Workspaces.CloudFailure.offline(
                "The network is offline."
            )
            let laterFailure = Workspaces.CloudFailure.other(
                "The server is unavailable."
            )

            await store.send(.cloudObservationFailed(firstFailure)) {
                $0.cloudObservationStatus = .failed
                $0.hasPresentedCloudFailureAlert = true
                $0.presentedCloudFailure = firstFailure
                $0.destination = .alert(
                    .cloudObservationFailed(firstFailure)
                )
            }
            await store.send(.cloudObservationFailed(laterFailure))
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
            await store.send(.cloudObservationFailed(laterFailure))
            #expect(store.state.destination == nil)
        }
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
            let initialState = locallyConfiguredState()
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
            let initialState = locallyConfiguredState()
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

    @Test("A removed duplicate repository cannot strand the persisted filter")
    func removedRepositoryClearsPersistedFilter() throws {
        try withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.selectedRepositoryID) var selectedRepositoryID
            $selectedRepositoryID.withLock {
                $0 = "removed-duplicate-repository"
            }

            let state = Workspaces.State()

            #expect(state.selectedRepositoryID == nil)
        }
    }

    @Test("Repository consolidation clears an active duplicate filter")
    func repositoryConsolidationClearsActiveFilter() async throws {
        let repository = Repository.preview(id: "duplicate-repository")
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { database in
                try Repository.insert { repository }.execute(database)
            }
        } operation: {
            let state = Workspaces.State()
            state.$selectedRepositoryID.withLock { $0 = repository.id }
            let store = TestStore(initialState: state) {
                Workspaces()
            }

            await store.send(.repositoriesChanged([])) {
                $0.$selectedRepositoryID.withLock { $0 = nil }
            }
            await store.finish()
        }
    }

    @Test("Create button presents a sheet with the available repositories")
    func createButtonPresentsSheet() async throws {
        let repository = Repository.preview()
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Repository.insert { repository }.execute(db)
            }
        } operation: {
            let state = Workspaces.State()
            state.$selectedRepositoryID.withLock { $0 = repository.id }
            let store = TestStore(initialState: state) {
                Workspaces()
            }

            await store.send(.createButtonTapped) {
                $0.destination = .createWorkspace(
                    CreateWorkspace.State(
                        repositories: [repository],
                        selectedRepositoryIDFilter: repository.id
                    )
                )
            }
        }
    }

    @Test("Create button does nothing without repositories")
    func createButtonWithoutRepositories() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            }

            await store.send(.createButtonTapped)
        }
    }

    @Test("Cloud-only repositories cannot create a local workspace")
    func createButtonExcludesCloudOnlyRepositories() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let repository = Repository.preview(id: "cloud-repository")
            let workspace = Workspace.preview(
                id: "cloud-workspace",
                repositoryID: repository.id
            )
            try await database.write { db in
                try Repository.insert { repository }.execute(db)
                try Workspace.insert { workspace }.execute(db)
                try CloudWorkspaceMetadata
                    .insert {
                        CloudWorkspaceMetadata(
                            workspaceID: workspace.id,
                            accountID: "account",
                            lastSeenGeneration: "generation"
                        )
                    }
                    .execute(db)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            }

            await store.send(.createButtonTapped)
            #expect(store.state.destination == nil)
        }
    }

    @Test("Creating a workspace waits after the sheet dismisses")
    func workspaceCreationWaitsForSheetDismissal() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let clock = TestClock()
            let repository = Repository.preview()
            let workspace = Workspace.preview(
                derivedStatus: Workspace.Status.inProgress.rawValue,
                repositoryID: repository.id
            )
            let item = WorkspaceWithRepository(
                workspace: workspace,
                repository: repository
            )
            let requestLease = DesktopRequestLease(
                baseURL: try #require(URL(string: "http://test:3768")),
                endpointEpoch: 0
            )
            let creation = WorkspaceCreationResult(
                selectedModel: .gpt_5_6_terra,
                requestLease: requestLease,
                workspace: item
            )
            var state = Workspaces.State()
            state.destination = .createWorkspace(
                CreateWorkspace.State(repositories: [repository])
            )
            let store = TestStore(initialState: state) {
                Workspaces()
            } withDependencies: {
                $0.continuousClock = clock
            }

            await store.send(
                .destination(
                    .presented(.createWorkspace(.delegate(.workspaceCreated(creation))))
                )
            ) {
                $0.destination = nil
                $0.pendingWorkspaceCreation = creation
            }
            await store.send(.workspacesChanged([item])) {
                $0.deferredWorkspaces = [item]
            }
            #expect(store.state.hasVisibleWorkspaces == false)
            await store.send(.createWorkspaceSheetDismissed) {
                $0.sections = Workspaces.State.sections(
                    groupedBy: $0.grouping,
                    workspaces: [item]
                )
                $0.deferredWorkspaces = nil
                $0.pendingWorkspaceCreation = nil
            }
            #expect(store.state.hasVisibleWorkspaces)
            await clock.advance(by: .milliseconds(249))
            await clock.advance(by: .milliseconds(1))
            await store.receive(\.workspaceCreated, creation)
        }
    }

    @Test("Observation failures preserve the create sheet")
    func observationFailurePreservesCreateSheet() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            let repository = Repository.preview()
            let createWorkspace = CreateWorkspace.State(repositories: [repository])
            var state = Workspaces.State()
            state.destination = .createWorkspace(createWorkspace)
            let store = TestStore(initialState: state) {
                Workspaces()
            }

            await store.send(.loadWorkspacesFailed(TestError()))
        }
    }

    @Test("Workspace snapshots reconnect after failures and cancel")
    func workspaceSnapshotsStreamReconnectAndCancel() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let clock = TestClock()
            let repository = Repository.preview(id: "repository", name: "Conductor")
            let workspace = Workspace.preview(
                id: "workspace",
                derivedStatus: Workspace.Status.inProgress.rawValue,
                repositoryID: repository.id
            )
            var updatedWorkspace = workspace
            updatedWorkspace.derivedStatus = Workspace.Status.done.rawValue
            let pullRequest = PullRequestSnapshot(
                url: "https://github.com/example/repository/pull/42",
                isDraft: false,
                isMerged: false,
                mergeStateStatus: .clean,
                checksStatus: .passing
            )
            let firstSnapshot = WorkspaceListSnapshot(
                repositories: [repository],
                workspaces: [WorkspaceSnapshot(workspace: workspace, isWorking: false)]
            )
            let secondSnapshot = WorkspaceListSnapshot(
                repositories: [repository],
                workspaces: [WorkspaceSnapshot(workspace: updatedWorkspace, isWorking: true)],
                pullRequests: [workspace.id: pullRequest]
            )
            let firstExpectedWorkspace = WorkspaceWithRepository(
                workspace: workspace,
                repository: repository,
                mobileState: MobileWorkspaceState(workspaceID: workspace.id, isWorking: false)
            )
            let secondExpectedWorkspace = WorkspaceWithRepository(
                workspace: updatedWorkspace,
                repository: repository,
                mobileState: MobileWorkspaceState(
                    workspaceID: workspace.id,
                    isWorking: true,
                    pullRequest: pullRequest
                )
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
            let initialState = locallyConfiguredState()
            let store = TestStore(initialState: initialState) {
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
            store.exhaustivity = .off(showSkippedAssertions: false)

            let task = await store.send(.task)

            firstContinuation.yield(firstSnapshot)
            try await waitForWorkspacesCondition("the first snapshot") {
                try await database.read { db in
                    try WorkspaceWithRepository
                        .all(workspaceID: workspace.id)
                        .fetchOne(db) == firstExpectedWorkspace
                }
            }
            #expect(connectionCount.value == 1)

            firstContinuation.finish(throwing: URLError(.networkConnectionLost))
            for _ in 0..<10 where connectionCount.value < 2 {
                await clock.advance(by: .seconds(1))
                await Task.yield()
            }
            #expect(connectionCount.value == 2)
            secondContinuation.yield(secondSnapshot)
            try await waitForWorkspacesCondition("the reconnected snapshot") {
                try await database.read { db in
                    try WorkspaceWithRepository
                        .all(workspaceID: workspace.id)
                        .fetchOne(db) == secondExpectedWorkspace
                }
            }
            let persistedWorkspace = try await database.read { db in
                try WorkspaceWithRepository
                    .all(workspaceID: workspace.id)
                    .fetchOne(db)
            }
            expectNoDifference(persistedWorkspace, secondExpectedWorkspace)

            await task.cancel()
            #expect(secondConnectionCancelled.value)
        }
    }

    @Test("A workspace becomes Cloud-only when desktop observation stops owning it")
    func desktopObservationReconcilesProvenance() async throws {
        let database = try appDatabase()
        let repository = Repository.preview(id: "repository", name: "Conductor")
        let workspace = Workspace.preview(
            id: "workspace",
            derivedStatus: Workspace.Status.inProgress.rawValue,
            repositoryID: repository.id
        )
        let cloudMetadata = CloudWorkspaceMetadata(
            workspaceID: workspace.id,
            accountID: "account",
            lastSeenGeneration: "generation"
        )
        try await database.write { db in
            try Repository.insert { repository }.execute(db)
            try Workspace.insert { workspace }.execute(db)
            try MobileWorkspaceState
                .insert {
                    MobileWorkspaceState(workspaceID: workspace.id, isWorking: true)
                }
                .execute(db)
            try CloudWorkspaceMetadata.insert { cloudMetadata }.execute(db)
        }

        let (stream, continuation) = AsyncThrowingStream<
            WorkspaceListSnapshot,
            any Error
        >.makeStream()
        let (cloudStream, cloudContinuation) = AsyncThrowingStream<
            CloudWorkspaceSnapshot,
            any Error
        >.makeStream()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(accountID: "account")
            }
            let initialState = locallyConfiguredState()
            let store = TestStore(initialState: initialState) {
                Workspaces()
            } withDependencies: {
                $0.cloudAPIClient.observeWorkspaces = { cloudStream }
                $0.continuousClock = TestClock()
                $0.desktopClient.observeWorkspaces = { stream }
                $0.desktopClient.ping = {}
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            let task = await store.send(.task)
            continuation.yield(
                WorkspaceListSnapshot(repositories: [], workspaces: [])
            )
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while try await database.read({
                try MobileWorkspaceState.find(workspace.id).fetchOne($0) != nil
            }), clock.now < deadline {
                await Task.yield()
            }
            let item = try await database.read {
                try WorkspaceWithRepository
                    .all(workspaceID: workspace.id)
                    .fetchOne($0)
            }

            let unwrappedItem = try #require(item)
            #expect(unwrappedItem.isCloudOnly)
            #expect(!unwrappedItem.isWorking)
            await task.cancel()
            cloudContinuation.finish()
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
            let initialState = locallyConfiguredState()
            let store = TestStore(initialState: initialState) {
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
                $0.desktopClient.archiveWorkspace = { workspaceID in
                    requests.withValue { $0.append("archive:\(workspaceID)") }
                }
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

            await store.send(.workspaceArchiveButtonTapped(item))
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
                    "archive:workspace",
                ]
            )
        }
    }

    @Test("Cloud-only workspace actions explain the public API limitation")
    func cloudOnlyWorkspaceActionsRequireDesktop() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .disconnected }
            let item = cloudWorkspace()
            let requestCount = LockIsolated(0)
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.desktopClient.setWorkspacePinned = { _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .hook
                }
                $0.desktopClient.setWorkspaceStatus = { _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .hook
                }
                $0.desktopClient.setWorkspaceUnread = { _, _ in
                    requestCount.withValue { $0 += 1 }
                    return .hook
                }
            }

            await store.send(.workspacePinnedButtonTapped(item)) {
                $0.destination = .alert(.cloudWorkspaceActionRequiresDesktop)
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
            await store.send(.workspaceStatusButtonTapped(item, .done)) {
                $0.destination = .alert(.cloudWorkspaceActionRequiresDesktop)
            }
            await store.send(.destination(.dismiss)) {
                $0.destination = nil
            }
            await store.send(.workspaceUnreadButtonTapped(item)) {
                $0.destination = .alert(.cloudWorkspaceActionRequiresDesktop)
            }

            #expect(requestCount.value == 0)
        }
    }

    @Test("Cloud workspace rename is prefilled, trimmed, and submitted")
    func cloudWorkspaceRename() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Shared(.cloudConfiguration) var cloudConfiguration
            $cloudConfiguration.withLock {
                $0 = CloudConfiguration(
                    accountID: "account",
                    credentialGeneration: UUID(71)
                )
            }
            let item = cloudWorkspace()
            let requests = LockIsolated<[String]>([])
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.workspaceMutationClient.renameWorkspace = {
                    route,
                    workspace,
                    name,
                    owningFeature in
                    #expect(
                        route == .cloud(
                            accountID: "account",
                            remoteWorkspaceID: "remote-workspace"
                        )
                    )
                    #expect(workspace.id == item.id)
                    #expect(owningFeature == .workspaces)
                    requests.withValue { $0.append(name) }
                }
            }

            await store.send(.workspaceRenameButtonTapped(item)) {
                $0.renamingWorkspace = item
                $0.workspaceNameDraft = "Cloud workspace"
                $0.destination = .renameWorkspace
            }
            await store.send(
                .binding(
                    .set(\.workspaceNameDraft, "  Renamed workspace  ")
                )
            ) {
                $0.workspaceNameDraft = "  Renamed workspace  "
            }
            await store.send(.workspaceRenameSubmitted) {
                $0.renamingWorkspace = nil
                $0.workspaceNameDraft = "Renamed workspace"
                $0.destination = nil
                $0.isRenamingWorkspace = true
            }
            await store.receive(\.workspaceRenameResponse.success) {
                $0.isRenamingWorkspace = false
            }

            #expect(requests.value == ["Renamed workspace"])
        }
    }

    @Test("Connected Cloud workspace actions use the desktop workspace ID")
    func connectedCloudWorkspaceActionsUseDesktop() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            try $0.bootstrapDatabase()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .connected }
            let item = cloudWorkspace()
            let now = Date(timeIntervalSince1970: 1_783_555_200)
            let requests = LockIsolated<[String]>([])
            try await database.write { db in
                try Workspace.insert { item.workspace }.execute(db)
            }
            let store = TestStore(initialState: Workspaces.State()) {
                Workspaces()
            } withDependencies: {
                $0.date.now = now
                $0.desktopClient.setWorkspacePinned = { workspaceID, isPinned in
                    requests.withValue { $0.append("pinned:\(workspaceID):\(isPinned)") }
                    return .hook
                }
                $0.desktopClient.setWorkspaceStatus = { workspaceID, status in
                    requests.withValue {
                        $0.append("status:\(workspaceID):\(status.rawValue)")
                    }
                    return .hook
                }
                $0.desktopClient.setWorkspaceUnread = { workspaceID, isUnread in
                    requests.withValue { $0.append("unread:\(workspaceID):\(isUnread)") }
                    return .hook
                }
            }

            await store.send(.workspacePinnedButtonTapped(item))
            await store.finish()
            await store.send(.workspaceStatusButtonTapped(item, .done))
            await store.finish()
            await store.send(.workspaceUnreadButtonTapped(item))
            await store.finish()

            let updatedWorkspace = try await database.read { db in
                try Workspace.find(item.id).fetchOne(db)
            }
            #expect(updatedWorkspace?.pinnedAt == now.ISO8601Format())
            #expect(updatedWorkspace?.manualStatus == Workspace.Status.done.rawValue)
            #expect(updatedWorkspace?.unread == 1)
            #expect(
                requests.value == [
                    "pinned:remote-workspace:true",
                    "status:remote-workspace:done",
                    "unread:remote-workspace:true",
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
                $0.destination = .alert(
                    .failedToUpdateWorkspace(error: TestError())
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
                $0.destination = .alert(
                    .failedToUpdateWorkspace(error: TestError())
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
                $0.destination = .alert(
                    .failedToUpdateWorkspace(error: TestError())
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
                $0.destination = .alert(.workspaceMutationUsedSQLiteFallback)
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
                $0.destination = .alert(
                    .failedToUpdateWorkspace(error: URLError(.networkConnectionLost))
                )
            }
        }
    }
}

@MainActor
private func waitForWorkspacesCondition(
    _ description: String,
    _ condition: @escaping () async throws -> Bool
) async rethrows {
    for _ in 0..<10_000 {
        guard !(try await condition()) else {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for \(description).")
}

@MainActor
private func assertObservationSources(
    local: Bool,
    cloud: Bool
) async throws {
    try await withDependencies {
        $0.defaultFileStorage = .inMemory
        try $0.bootstrapDatabase()
    } operation: {
        @Shared(.cloudConfiguration) var cloudConfiguration
        @Shared(.desktopServerAddress) var desktopServerAddress
        $cloudConfiguration.withLock {
            $0 = cloud ? CloudConfiguration(accountID: "account") : nil
        }
        $desktopServerAddress.withLock {
            $0 = local ? "paired-desktop" : nil
        }

        let localObservationCount = LockIsolated(0)
        let cloudObservationCount = LockIsolated(0)
        let (localStream, localContinuation) = AsyncThrowingStream<
            WorkspaceListSnapshot,
            any Error
        >.makeStream()
        let (cloudStream, cloudContinuation) = AsyncThrowingStream<
            CloudWorkspaceSnapshot,
            any Error
        >.makeStream()
        let clock = TestClock()
        let state = Workspaces.State()
        #expect(state.hasLocalConfiguration == local)
        #expect(state.isLoadingWorkspaces == local)
        #expect(
            state.cloudObservationStatus
                == (cloud ? .loading : .disconnected)
        )

        let store = TestStore(initialState: state) {
            Workspaces()
        } withDependencies: {
            $0.cloudAPIClient.observeWorkspaces = {
                cloudObservationCount.withValue { $0 += 1 }
                return cloudStream
            }
            $0.continuousClock = clock
            $0.desktopClient.observeWorkspaces = {
                localObservationCount.withValue { $0 += 1 }
                return localStream
            }
            $0.desktopClient.ping = {}
        }

        let task = await store.send(.task)
        for _ in 0..<1_000 {
            guard localObservationCount.value != (local ? 1 : 0)
                    || cloudObservationCount.value != (cloud ? 1 : 0)
            else {
                break
            }
            await Task.yield()
        }
        #expect(localObservationCount.value == (local ? 1 : 0))
        #expect(cloudObservationCount.value == (cloud ? 1 : 0))

        await task.cancel()
        localContinuation.finish()
        cloudContinuation.finish()
    }
}

@MainActor
private func locallyConfiguredState() -> Workspaces.State {
    @Shared(.desktopServerAddress) var desktopServerAddress
    $desktopServerAddress.withLock { $0 = "paired-desktop" }
    return Workspaces.State()
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

private func cloudWorkspace() -> WorkspaceWithRepository {
    let workspace = Workspace.preview(
        id: "canonical-workspace",
        derivedStatus: Workspace.Status.inProgress.rawValue,
        hostingServerURL: Workspace.conductorCloudHostingServerURL,
        workspaceName: "Cloud workspace"
    )
    return WorkspaceWithRepository(
        workspace: workspace,
        repository: nil,
        cloudMetadata: CloudWorkspaceMetadata(
            workspaceID: workspace.id,
            accountID: "account",
            remoteWorkspaceID: "remote-workspace",
            lastSeenGeneration: "generation"
        )
    )
}

private struct TestError: LocalizedError {
    var errorDescription: String? {
        "Something went wrong."
    }
}
