//
//  Workspaces.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Combine
import ComposableArchitecture
import ConductorCloud
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import Logging
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI

@Reducer
public struct Workspaces: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?

        @Shared(.cloudConfiguration)
        public var cloudConfiguration

        @Shared(.desktopConnectionStatus)
        public var connectionStatus

        @Shared(.desktopDisplayConfiguration)
        public var displayConfiguration

        @Shared(.desktopServerAddress)
        public var desktopServerAddress

        @FetchAll(
            Repository.all
                .order { ($0.displayOrder, $0.name.lower(), $0.id) },
            animation: .default
        )
        public var repositories: [Repository] = []

        @FetchAll(
            Repository.availableForLocalWorkspaceCreation,
            animation: .default
        )
        public var repositoriesAvailableForWorkspaceCreation: [Repository] = []

        @Shared(.collapsedWorkspaceSectionIDs)
        var collapsedSectionIDs

        @Shared(.workspaceGrouping)
        public var grouping

        @Shared(.selectedRepositoryID)
        public var selectedRepositoryID

        @Shared(.workspaceSort)
        public var sort

        var deferredWorkspaces: [WorkspaceWithRepository]?
        var pendingWorkspaceCreation: WorkspaceCreationResult?

        @FetchAll(
            WorkspaceWithRepository.all(),
            animation: .default
        )
        public var workspaces: [WorkspaceWithRepository] = []

        public var cloudObservationStatus: CloudObservationStatus
        var hasPresentedCloudFailureAlert = false
        var isLoadingWorkspaces: Bool
        var sections: [WorkspaceSection] = []

        public var isCloudCredentialConfigured: Bool {
            cloudConfiguration != nil
        }

        var hasLocalConfiguration: Bool {
            desktopServerAddress != nil
        }

        var hasVisibleWorkspaces: Bool {
            sections.contains { !$0.items.isEmpty }
        }

        public init() {
            @Shared(.cloudConfiguration) var cloudConfiguration
            @Shared(.desktopServerAddress) var desktopServerAddress
            self.cloudObservationStatus = cloudConfiguration != nil
                ? .loading
                : .disconnected
            self.isLoadingWorkspaces = desktopServerAddress != nil
            _workspaces = FetchAll(
                WorkspaceWithRepository.all(
                    repositoryID: selectedRepositoryID,
                    sortedBy: sort,
                    groupedBy: grouping
                ),
                animation: .default
            )
            updateSections(from: workspaces)
        }

        mutating func updateSections(
            from workspaces: [WorkspaceWithRepository],
            groupedBy grouping: WorkspaceWithRepository.Grouping? = nil
        ) {
            sections = Self.sections(
                groupedBy: grouping ?? self.grouping,
                workspaces: workspaces
            )
        }

        static func sections(
            groupedBy grouping: WorkspaceWithRepository.Grouping,
            workspaces: [WorkspaceWithRepository]
        ) -> [WorkspaceSection] {
            // Pinned workspaces leave the grouped sections and collect into a single leading
            // section, so group only the ones that stay behind.
            let pinnedItems = workspaces.filter { $0.workspace.pinnedAt != nil }
            let unpinnedItems = workspaces.filter { $0.workspace.pinnedAt == nil }

            let groupedSections: [WorkspaceSection]
            switch grouping {
            case .status:
                let initialSections = Workspace.Status.displayOrder.map { status in
                    WorkspaceSection(
                        groupByType: .status(status),
                        items: []
                    )
                }

                groupedSections = unpinnedItems.reduce(into: initialSections) { sections, item in
                    let groupByType = WorkspaceSection.GroupByType.status(
                        item.status
                    )
                    if let index = sections.firstIndex(where: { $0.id == groupByType.id }) {
                        sections[index].items.append(item)
                    } else {
                        sections.append(
                            WorkspaceSection(
                                groupByType: groupByType,
                                items: [item]
                            )
                        )
                    }
                }

            case .project:
                groupedSections = unpinnedItems.reduce(into: []) { sections, item in
                    let groupByType = WorkspaceSection.GroupByType.project(
                        repositoryID: item.workspace.repositoryID,
                        repository: item.repository,
                        title: item.repositoryDisplayName
                    )
                    if let index = sections.firstIndex(where: { $0.id == groupByType.id }) {
                        sections[index].items.append(item)
                    } else {
                        sections.append(
                            WorkspaceSection(
                                groupByType: groupByType,
                                items: [item]
                            )
                        )
                    }
                }
            }

            guard !pinnedItems.isEmpty else {
                return groupedSections
            }

            return [WorkspaceSection(groupByType: .pinned, items: pinnedItems)]
                + groupedSections
        }

        struct WorkspaceSection: Equatable, Identifiable, Sendable {
            var id: String { groupByType.id }
            let groupByType: GroupByType
            var items: [WorkspaceWithRepository]

            /// Pinned always leads the list and never collapses, so the view renders it apart
            /// from the grouped status/project sections.
            var isPinned: Bool {
                if case .pinned = groupByType { return true }
                return false
            }

            enum GroupByType: Equatable, Sendable {
                case pinned
                case status(Workspace.Status)
                case project(
                    repositoryID: Repository.ID?,
                    repository: Repository?,
                    title: String
                )

                var id: String {
                    switch self {
                    case .pinned: "pinned"
                    case let .status(status): "status:\(status.rawValue)"
                    case let .project(repositoryID, _, _):
                        "project:\(repositoryID ?? "")"
                    }
                }
            }
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)
        case createWorkspace(CreateWorkspace)

        public enum Alert: Equatable {
            case openSettings
            case retryCloud
        }
    }

    public enum CloudObservationStatus: Equatable, Sendable {
        case connected
        case disconnected
        case failed
        case loading
    }

    public enum CloudFailure: Equatable, Sendable {
        case authentication(String)
        case offline(String)
        case other(String)

        public var message: String {
            switch self {
            case let .authentication(message),
                 let .offline(message),
                 let .other(message):
                message
            }
        }

        public var title: String {
            switch self {
            case .authentication:
                "Cloud authentication failed"

            case .offline, .other:
                "Unable to reach Cloud"
            }
        }

        static func from(_ error: any Error) -> Self {
            if let apiError = error as? CloudAPIClientError,
               apiError.isAuthenticationFailure {
                return .authentication(apiError.localizedDescription)
            }
            if error is URLError {
                return .offline(error.localizedDescription)
            }
            return .other(error.localizedDescription)
        }
    }

    public enum Action {
        case cloudConfigurationChanged(CloudConfiguration?)
        case cloudObservationFailed(CloudFailure)
        case cloudSnapshotReceived
        case createButtonTapped
        case createWorkspaceSheetDismissed
        case desktopConfigurationChanged(String?)
        case destination(PresentationAction<Destination.Action>)
        case groupingChanged(WorkspaceWithRepository.Grouping)
        case initialWorkspacesResponse
        case loadWorkspacesFailed(any Error)
        case repositoryFilterButtonTapped(String?)
        case sortButtonTapped(WorkspaceWithRepository.Sort)
        /// Note: `MainView` handles this action so we can keep this module decoupled from `ConductorSettings`
        case settingsButtonTapped
        case task
        case workspacesChanged([WorkspaceWithRepository])
        case workspaceArchiveButtonTapped(WorkspaceWithRepository)
        case workspaceArchiveFailed(any Error)
        case workspaceCreated(WorkspaceCreationResult)
        case workspaceMutationFailed(any Error)
        case workspaceMutationUsedSQLiteFallback
        case workspacePinnedButtonTapped(WorkspaceWithRepository)
        case workspaceStatusButtonTapped(WorkspaceWithRepository, Workspace.Status)
        case workspaceTapped(WorkspaceWithRepository)
        case workspaceUnreadButtonTapped(WorkspaceWithRepository)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.continuousClock) var clock
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.date.now) var now
    @Dependency(\.desktopClient) var desktopClient

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let cloudConfiguration = state.$cloudConfiguration
                let desktopServerAddress = state.$desktopServerAddress
                let grouping = state.$grouping
                let workspaces = state.$workspaces
                // Shared publishers immediately replay their current values. `State.init`
                // already used those values to build sections, so observe only later changes.
                return .merge(
                    .publisher {
                        cloudConfiguration.publisher
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.cloudConfigurationChanged)
                    },
                    .publisher {
                        desktopServerAddress.publisher
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.desktopConfigurationChanged)
                    },
                    .publisher {
                        grouping.publisher
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.groupingChanged)
                    },
                    .publisher {
                        workspaces.publisher
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.workspacesChanged)
                    },
                    state.isCloudCredentialConfigured
                        ? observeCloudWorkspaces()
                        : clearCachedCloudWorkspaces(),
                    state.hasLocalConfiguration
                        ? .merge(
                            monitorConnection(),
                            observeLocalWorkspaces(state)
                        )
                        : clearDesktopObservation()
                )

            case let .cloudConfigurationChanged(configuration):
                state.hasPresentedCloudFailureAlert = false
                guard configuration != nil else {
                    state.cloudObservationStatus = .disconnected
                    return .merge(
                        .cancel(id: CancelID.cloudObservation),
                        clearCachedCloudWorkspaces()
                    )
                }
                state.cloudObservationStatus = .loading
                return observeCloudWorkspaces()

            case let .cloudObservationFailed(failure):
                state.cloudObservationStatus = .failed
                guard !state.hasPresentedCloudFailureAlert,
                      state.destination == nil else {
                    return .none
                }
                state.hasPresentedCloudFailureAlert = true
                state.destination = .alert(.cloudObservationFailed(failure))
                return .none

            case .cloudSnapshotReceived:
                state.cloudObservationStatus = .connected
                state.hasPresentedCloudFailureAlert = false
                return .none

            case let .desktopConfigurationChanged(serverAddress):
                state.isLoadingWorkspaces = serverAddress != nil
                guard serverAddress != nil else {
                    return .merge(
                        .cancel(id: CancelID.desktopObservation),
                        .cancel(id: CancelID.connectionMonitor),
                        clearDesktopObservation()
                    )
                }
                return .merge(
                    monitorConnection(),
                    observeLocalWorkspaces(state, clearsPreviousObservation: true)
                )

            case let .groupingChanged(grouping):
                state.updateSections(from: state.workspaces, groupedBy: grouping)
                return reloadWorkspaces(state)

            case .createButtonTapped:
                let repositories = state.repositoriesAvailableForWorkspaceCreation
                guard !repositories.isEmpty else {
                    return .none
                }

                state.destination = .createWorkspace(
                    CreateWorkspace.State(
                        repositories: repositories,
                        selectedRepositoryIDFilter: state.selectedRepositoryID
                    )
                )
                return .none

            case .createWorkspaceSheetDismissed:
                state.updateSections(from: state.deferredWorkspaces ?? state.workspaces)
                state.deferredWorkspaces = nil
                guard let creation = state.pendingWorkspaceCreation else {
                    return .none
                }
                state.pendingWorkspaceCreation = nil
                return .run { [creation] send in
                    try await clock.sleep(for: .milliseconds(250))
                    await send(.workspaceCreated(creation))
                }

            case let .destination(
                .presented(.createWorkspace(.delegate(.workspaceCreated(creation))))
            ):
                state.destination = nil
                state.pendingWorkspaceCreation = creation
                return .none

            case .destination(.presented(.alert(.openSettings))):
                return .send(.settingsButtonTapped)

            case .destination(.presented(.alert(.retryCloud))):
                state.cloudObservationStatus = .loading
                return observeCloudWorkspaces()

            case .initialWorkspacesResponse:
                state.isLoadingWorkspaces = false
                return .none

            case let .loadWorkspacesFailed(error):
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                guard state.destination?.createWorkspace == nil else {
                    return .none
                }

                state.destination = .alert(.failedToLoadWorkspaces(error: error))
                return .none

            case let .repositoryFilterButtonTapped(repositoryID):
                state.$selectedRepositoryID.withLock { $0 = repositoryID }
                return reloadWorkspaces(state)

            case let .sortButtonTapped(sort):
                state.$sort.withLock { $0 = sort }
                return reloadWorkspaces(state)

            case let .workspacesChanged(workspaces):
                guard state.destination?.createWorkspace == nil,
                      state.pendingWorkspaceCreation == nil else {
                    state.deferredWorkspaces = workspaces
                    return .none
                }
                state.updateSections(from: workspaces)
                return .none

            case let .workspaceArchiveButtonTapped(item):
                guard !item.workspace.isCloudHosted else {
                    return .none
                }
                return .run { send in
                    do {
                        try await desktopClient.archiveWorkspace(workspaceID: item.id)
                    } catch {
                        Logger.workspace.error("Failed to archive workspace: \(error)")
                        await send(.workspaceArchiveFailed(error))
                    }
                }

            case let .workspaceArchiveFailed(error):
                state.destination = .alert(.failedToArchiveWorkspace(error: error))
                return .none

            case let .workspaceMutationFailed(error):
                state.destination = .alert(.failedToUpdateWorkspace(error: error))
                return .none

            case .workspaceMutationUsedSQLiteFallback:
                state.destination = .alert(.workspaceMutationUsedSQLiteFallback)
                return .none

            case let .workspacePinnedButtonTapped(item):
                guard !item.workspace.isCloudHosted else {
                    return .none
                }
                let isPinned = item.workspace.pinnedAt == nil
                let previousPinnedAt = item.workspace.pinnedAt
                let pinnedAt = isPinned ? now.ISO8601Format() : nil

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.pinnedAt = #bind(pinnedAt) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.pinnedAt == pinnedAt
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.pinnedAt = #bind(previousPinnedAt) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspacePinned(
                        workspaceID: item.id,
                        isPinned: isPinned
                    )
                }

            case let .workspaceStatusButtonTapped(item, status):
                guard !item.workspace.isCloudHosted,
                      item.workspace.status != status else {
                    return .none
                }
                let previousManualStatus = item.workspace.manualStatus

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.manualStatus = #bind(status.rawValue) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.manualStatus == status.rawValue
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.manualStatus = #bind(previousManualStatus) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspaceStatus(
                        workspaceID: item.id,
                        status: status
                    )
                }

            case let .workspaceUnreadButtonTapped(item):
                guard !item.workspace.isCloudHosted else {
                    return .none
                }
                let isUnread = (item.workspace.unread ?? 0) == 0
                let previousUnread = item.workspace.unread
                let unread = isUnread ? 1 : 0

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.unread = #bind(unread) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.unread == unread
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.unread = #bind(previousUnread) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspaceUnread(
                        workspaceID: item.id,
                        isUnread: isUnread
                    )
                }

            case .destination,
                 .settingsButtonTapped,
                 .workspaceCreated,
                 .workspaceTapped:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func updateWorkspace(
        _ optimisticUpdate: @escaping @Sendable () async throws -> Void,
        rollback: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async throws -> UIHookMutationPath
    ) -> Effect<Action> {
        .run { send in
            do {
                try await optimisticUpdate()
            } catch {
                Logger.workspace.error("Failed to optimistically update workspace: \(error)")
                await send(.workspaceMutationFailed(error))
                return
            }

            do {
                if try await operation() == .sqliteFallback {
                    await send(.workspaceMutationUsedSQLiteFallback)
                }
            } catch let mutationError {
                do {
                    try await rollback()
                } catch {
                    Logger.workspace.error("Failed to roll back workspace update: \(error)")
                }

                Logger.workspace.error("Failed to update workspace: \(mutationError)")
                await send(.workspaceMutationFailed(mutationError))
            }
        }
    }

    private func reloadWorkspaces(_ state: State) -> Effect<Action> {
        .run { [
            grouping = state.grouping,
            selectedRepositoryID = state.selectedRepositoryID,
            sort = state.sort,
            workspaces = state.$workspaces,
        ] send in
            do {
                let query = WorkspaceWithRepository.all(
                    repositoryID: selectedRepositoryID,
                    sortedBy: sort,
                    groupedBy: grouping
                )
                try await workspaces.load(query, animation: .default)
            } catch {
                Logger.workspace.error("Failed to reload workspaces: \(error)")
                await send(.loadWorkspacesFailed(error))
            }
        }
    }

    private func observeLocalWorkspaces(
        _ state: State,
        clearsPreviousObservation: Bool = false
    ) -> Effect<Action> {
        .run { [initiallyIsLoadingWorkspaces = state.isLoadingWorkspaces] send in
            var isAwaitingInitialResponse = initiallyIsLoadingWorkspaces
            if clearsPreviousObservation {
                try await database.write { db in
                    try MobileWorkspaceState.delete().execute(db)
                }
            }

            await StreamObservation.observe {
                desktopClient.observeWorkspaces()
            } onValue: { snapshot in
                try await database.write { db in
                    try Repository
                        .upsert { snapshot.repositories }
                        .execute(db)
                    try Workspace
                        .upsert { snapshot.workspaces.map(\.workspace) }
                        .execute(db)

                    // The desktop snapshot is authoritative for this source-specific table.
                    try MobileWorkspaceState.delete().execute(db)
                    try MobileWorkspaceState.upsert {
                        snapshot.workspaces.map {
                            MobileWorkspaceState(
                                workspaceID: $0.workspace.id,
                                isWorking: $0.isWorking,
                                pullRequest: snapshot.pullRequests[$0.workspace.id]
                            )
                        }
                    }
                    .execute(db)
                }

                if isAwaitingInitialResponse {
                    isAwaitingInitialResponse = false
                    await send(.initialWorkspacesResponse)
                }
            } onFailure: { error in
                Logger.workspace.error(
                    "Failed to observe local workspaces: \(error)"
                )
                await send(.loadWorkspacesFailed(error))
            }
        }
        .cancellable(id: CancelID.desktopObservation, cancelInFlight: true)
    }

    private func observeCloudWorkspaces() -> Effect<Action> {
        .run { send in
            await StreamObservation.observe(
                retrying: {
                    cloudAPIClient.observeWorkspaces()
                },
                retryDelays: [
                    .seconds(1),
                    .seconds(2),
                    .seconds(4),
                    .seconds(8),
                    .seconds(16),
                    .seconds(30),
                ],
                shouldRetry: { error in
                    if CloudAPIClientError.isRequestCancellation(error) {
                        return true
                    }
                    return CloudAPIClientError.shouldRetryObservation(
                        after: error
                    )
                }
            ) { snapshot in
                try await database.write { db in
                    try CloudWorkspacePersistence.persist(snapshot, in: db)
                }
                await send(.cloudSnapshotReceived)
            } onFailure: { error in
                guard !CloudAPIClientError.isRequestCancellation(error) else {
                    return
                }
                Logger.workspace.error(
                    "Failed to observe Cloud workspaces: \(error)"
                )
                await send(.cloudObservationFailed(.from(error)))
            }
        }
        .cancellable(id: CancelID.cloudObservation, cancelInFlight: true)
    }

    private func clearCachedCloudWorkspaces() -> Effect<Action> {
        .run { send in
            do {
                try await database.write { db in
                    try CloudWorkspaceMetadata.clearCachedRows(in: db)
                }
            } catch {
                Logger.workspace.error("Failed to clear Cloud workspaces: \(error)")
                await send(.loadWorkspacesFailed(error))
            }
        }
    }

    private func clearDesktopObservation() -> Effect<Action> {
        .run { send in
            do {
                try await database.write { db in
                    try MobileWorkspaceState.delete().execute(db)
                }
            } catch {
                Logger.workspace.error("Failed to clear local observation: \(error)")
                await send(.loadWorkspacesFailed(error))
            }
        }
    }

    private func monitorConnection() -> Effect<Action> {
        .run { _ in
            while !Task.isCancelled {
                try? await desktopClient.ping()
                try await clock.sleep(for: .seconds(3))
            }
        }
        .cancellable(id: CancelID.connectionMonitor, cancelInFlight: true)
    }

    private enum CancelID: Hashable {
        case cloudObservation
        case connectionMonitor
        case desktopObservation
    }
}

extension Workspaces.Destination.State: Equatable {}

extension AlertState where Action == Workspaces.Destination.Alert {
    static func cloudObservationFailed(_ failure: Workspaces.CloudFailure) -> Self {
        switch failure {
        case .authentication:
            AlertState {
                TextState(failure.title)
            } actions: {
                ButtonState(action: .openSettings) {
                    TextState("Open Settings")
                }

                ButtonState(role: .cancel) {
                    TextState("Dismiss")
                }
            } message: {
                TextState(failure.message)
            }

        case .offline, .other:
            AlertState {
                TextState(failure.title)
            } actions: {
                ButtonState(action: .retryCloud) {
                    TextState("Retry")
                }

                ButtonState(role: .cancel) {
                    TextState("Dismiss")
                }
            } message: {
                TextState(failure.message)
            }
        }
    }

    static func failedToLoadWorkspaces(error: any Error) -> Self {
        AlertState {
            TextState("Failed to load workspaces")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToUpdateWorkspace(error: any Error) -> Self {
        AlertState {
            TextState("Failed to update workspace")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToArchiveWorkspace(error: any Error) -> Self {
        AlertState {
            TextState("Failed to archive workspace")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static var workspaceMutationUsedSQLiteFallback: Self {
        AlertState {
            TextState("Workspace change saved")
        } message: {
            TextState(
                "The change was saved to Conductor's database, but the open Conductor window "
                    + "may remain stale until Conductor reloads. Reconnect the Workspace UI hook "
                    + "for live updates."
            )
        }
    }
}

public struct WorkspacesView: View {
    @Bindable var store: StoreOf<Workspaces>

    @Shared(.collapsedWorkspaceSectionIDs)
    private var collapsedSectionIDs

    @Namespace private var namespace

    public init(store: StoreOf<Workspaces>) {
        self.store = store
    }

    public var body: some View {
        List {
            if store.hasVisibleWorkspaces {
                ForEach(store.sections) { section in
                    if section.isPinned {
                        PinnedSectionView(section: section) { item, action in
                            workspaceRowAction(action, item: item)
                        }
                    } else {
                        WorkspaceSectionView(
                            section: section,
                            showsRepositoryIcon: store.grouping == .status
                                && store.selectedRepositoryID == nil,
                            isExpanded: Binding($collapsedSectionIDs)[isExpanded: section.id]
                                .animation(.default)
                        ) { item, action in
                            workspaceRowAction(action, item: item)
                        }
                    }
                }
            }

        }
        .contentMargins(.top, 0)
        .listStyle(.plain)
        .animation(.default, value: store.sections)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .overlay {
            if store.isLoadingWorkspaces
                && store.hasLocalConfiguration
                && !store.isCloudCredentialConfigured {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(.theme(.background))
            } else if !store.hasVisibleWorkspaces
                && store.cloudObservationStatus != .loading {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "rectangle.stack",
                    description: Text(emptyDescription)
                )
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
            }
        }
        .themedNavigationTitle("Conductor", alignment: .leading) {
            if store.isCloudCredentialConfigured || store.hasLocalConfiguration {
                ConnectionStatusSubtitle(
                    cloudStatus: store.isCloudCredentialConfigured
                        ? store.cloudObservationStatus
                        : nil,
                    localStatus: store.hasLocalConfiguration
                        ? store.connectionStatus
                        : nil,
                    localDisplayConfiguration: store.displayConfiguration
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    store.send(.settingsButtonTapped)
                } label: {
                    Label {
                        Text("Settings")
                    } icon: {
                        LucideIcon(Lucide.settings, size: 20, relativeTo: .title)
                    }
                    .foregroundStyle(.theme(.textPrimary))
                }
            }

            ToolbarItem(placement: .bottomBar) {
                WorkspaceFilterMenu(store: store)
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button {
                    store.send(.createButtonTapped)
                } label: {
                    HStack(spacing: 6) {
                        LucideIcon(Lucide.plus, style: .body)

                        Text("Create")
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .tint(.theme(.foreground))
                .foregroundStyle(.theme(.background))
                .disabled(store.repositoriesAvailableForWorkspaceCreation.isEmpty)
                .accessibilityHint("Creates a new Conductor workspace")
                .sheet(
                    item: $store.scope(
                        state: \.destination?.createWorkspace,
                        action: \.destination.createWorkspace
                    ),
                    onDismiss: {
                        store.send(.createWorkspaceSheetDismissed)
                    }
                ) { createWorkspaceStore in
                    CreateWorkspaceView(store: createWorkspaceStore)
                        .presentationBackground(.theme(.background))
                        .navigationTransition(.zoom(sourceID: "new-workspace", in: namespace))
                }
            }
            .matchedTransitionSource(id: "new-workspace", in: namespace)
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .preferredColorScheme(.dark)
    }

    private var emptyDescription: String {
        switch (store.hasLocalConfiguration, store.isCloudCredentialConfigured) {
        case (true, true):
            "No workspaces are available from your Mac or Conductor Cloud."

        case (true, false):
            "Pair with Conductor on your Mac to see workspaces here."

        case (false, true):
            "No Conductor Cloud workspaces are available."

        case (false, false):
            "Configure a Mac connection or Conductor Cloud in Settings."
        }
    }

    private struct ConnectionStatusSubtitle: View {
        let cloudStatus: Workspaces.CloudObservationStatus?
        let localStatus: DesktopClient.ConnectionStatus?
        let localDisplayConfiguration: DesktopClient.DisplayConfiguration?

        var body: some View {
            HStack(spacing: 8) {
                if let cloudStatus {
                    CloudStatusLabel(status: cloudStatus)
                }

                if cloudStatus != nil && localStatus != nil {
                    Rectangle()
                        .fill(.theme(.border))
                        .frame(width: 1, height: 12)
                        .accessibilityHidden(true)
                }

                if let localStatus {
                    LocalStatusLabel(
                        status: localStatus,
                        displayConfiguration: localDisplayConfiguration
                    )
                }
            }
        }

        private struct CloudStatusLabel: View {
            let status: Workspaces.CloudObservationStatus

            var body: some View {
                Label {
                    Text("Cloud")
                        .foregroundStyle(.theme(.textSecondary))
                        .font(.theme(.small))
                        .lineLimit(1)
                } icon: {
                    HStack(spacing: 4) {
                        StatusIndicator(state: indicatorState)

                        CloudWorkspaceIcon(
                            size: 14,
                            relativeTo: ThemeFontStyle.small.textStyle
                        )
                    }
                }
                .labelStyle(.conductorExtraSmall)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityLabel("Cloud")
                .accessibilityValue(accessibilityValue)
            }

            private var accessibilityIdentifier: String {
                switch status {
                case .connected:
                    "cloud-status.connected"

                case .disconnected:
                    "cloud-status.disconnected"

                case .failed:
                    "cloud-status.failed"

                case .loading:
                    "cloud-status.loading"
                }
            }

            private var accessibilityValue: String {
                switch status {
                case .connected:
                    "Connected"

                case .disconnected:
                    "Disconnected"

                case .failed:
                    "Unavailable"

                case .loading:
                    "Loading workspaces"
                }
            }

            private var indicatorState: StatusIndicator.State {
                switch status {
                case .connected:
                    .connected

                case .disconnected, .failed:
                    .disconnected

                case .loading:
                    .loading
                }
            }
        }

        private struct LocalStatusLabel: View {
            let status: DesktopClient.ConnectionStatus
            let displayConfiguration: DesktopClient.DisplayConfiguration?

            private var displayName: String {
                displayConfiguration?.name ?? "MacBook Pro"
            }

            private var deviceIcon: DesktopClient.DeviceIcon {
                displayConfiguration?.icon ?? .laptop
            }

            var body: some View {
                Label {
                    Text(displayName)
                        .foregroundStyle(.theme(.textSecondary))
                        .font(.theme(.small))
                        .lineLimit(1)
                } icon: {
                    HStack(spacing: 4) {
                        StatusIndicator(state: indicatorState)

                        LucideIcon(deviceIcon.lucideImage, style: .small)
                    }
                }
                .labelStyle(.conductorExtraSmall)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayName)
                .accessibilityValue(accessibilityValue)
            }

            private var accessibilityValue: String {
                switch status {
                case .connected:
                    "Connected"

                case .connecting:
                    "Connecting"

                case .disconnected:
                    "Disconnected"
                }
            }

            private var indicatorState: StatusIndicator.State {
                switch status {
                case .connected:
                    .connected

                case .connecting:
                    .loading

                case .disconnected:
                    .disconnected
                }
            }
        }

        private struct StatusIndicator: View {
            let state: State

            @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
            private var frameSize = 12

            @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
            private var size = 8

            var body: some View {
                Group {
                    switch state {
                    case .connected, .disconnected:
                        Circle()
                            .fill(
                                .theme(state == .connected ? .gitGreen : .gitRed)
                            )
                            .frame(width: size, height: size)

                    case .loading:
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.textSecondary))
                            .controlSize(.mini)
                    }
                }
                .frame(width: frameSize, height: frameSize)
            }

            enum State: Equatable {
                case connected
                case disconnected
                case loading
            }
        }
    }

    private func workspaceRowAction(
        _ action: WorkspaceRowAction,
        item: WorkspaceWithRepository
    ) {
        switch action {
        case .archive:
            store.send(.workspaceArchiveButtonTapped(item))

        case .open:
            store.send(.workspaceTapped(item))

        case let .setStatus(status):
            store.send(.workspaceStatusButtonTapped(item, status))

        case .togglePinned:
            store.send(.workspacePinnedButtonTapped(item))

        case .toggleUnread:
            store.send(.workspaceUnreadButtonTapped(item))
        }
    }

    private struct PinnedSectionView: View {
        let section: Workspaces.State.WorkspaceSection
        let action: @MainActor (WorkspaceWithRepository, WorkspaceRowAction) -> Void
        @ScaledMetric(relativeTo: .body) private var iconSize = 13.2

        var body: some View {
            Section {
                WorkspaceRows(
                    items: section.items,
                    // Pinned mixes repositories, so always show the icon and keep rows flush left.
                    showsRepositoryIcon: true,
                    isIndented: false,
                    action: action
                )
            } header: {
                Text("Pinned")
                    .font(.theme(.body))
                    .fontWeight(.semibold)
                    .foregroundStyle(.theme(.textPrimary))
                    .textCase(nil)
            }
            .listSectionSpacing(16)
        }
    }

    private struct WorkspaceSectionView: View {
        let section: Workspaces.State.WorkspaceSection
        let showsRepositoryIcon: Bool

        @Binding var isExpanded: Bool

        let action: @MainActor (WorkspaceWithRepository, WorkspaceRowAction) -> Void

        var body: some View {
            Section(isExpanded: $isExpanded) {
                WorkspaceRows(
                    items: section.items,
                    showsRepositoryIcon: showsRepositoryIcon,
                    action: action
                )
            } header: {
                Button {
                    isExpanded.toggle()
                } label: {
                    WorkspaceSectionHeader(
                        groupByType: section.groupByType,
                        count: section.items.count,
                        isExpanded: isExpanded
                    )
                }
                .buttonStyle(.plain)
            }
            .sensoryFeedback(.selection, trigger: isExpanded)
        }
    }

    private struct WorkspaceSectionHeader: View {
        let groupByType: Workspaces.State.WorkspaceSection.GroupByType
        let count: Int
        let isExpanded: Bool

        var body: some View {
            LabeledContent {
                if !isExpanded {
                    Text(count, format: .number)
                        .font(.theme(.extraExtraSmall))
                        .foregroundStyle(.theme(.textSecondary))
                        .contentTransition(.numericText(value: Double(count)))
                }

                LucideIcon(Lucide.chevronDown, style: .body)
                    .foregroundStyle(.theme(.sidebarMutedForeground))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            } label: {
                switch groupByType {
                case .pinned:
                    /// Pinned renders through `PinnedSectionView`, never this collapsible header.
                    /// This is definitely a smell but w/e
                    EmptyView()

                case let .status(status):
                    StatusSectionHeader(status: status)

                case let .project(_, repository, title):
                    ProjectSectionHeader(
                        repository: repository,
                        title: title
                    )
                }
            }
            .labeledContentStyle(.conductorStandard)
            .contentShape(.rect)
        }
    }

    private struct WorkspaceRows: View {
        let items: [WorkspaceWithRepository]
        let showsRepositoryIcon: Bool
        var isIndented = true
        let action: @MainActor (WorkspaceWithRepository, WorkspaceRowAction) -> Void

        var body: some View {
            ForEach(items) { item in
                WorkspaceRow(
                    item: item,
                    showsRepositoryIcon: showsRepositoryIcon,
                    action: rowAction(for: item)
                )
                .padding(.leading, isIndented ? 12 : 0)
                .listRowInsets(
                    EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }

        private func rowAction(
            for item: WorkspaceWithRepository
        ) -> (@MainActor (WorkspaceRowAction) -> Void)? {
            { workspaceRowAction in
                action(item, workspaceRowAction)
            }
        }
    }

    private struct StatusSectionHeader: View {
        let status: Workspace.Status
        @ScaledMetric(relativeTo: .body) private var iconSize = 13.2

        var body: some View {
            Label {
                Text(status.title)
                    .font(.theme(.body))
                    .fontWeight(.semibold)
                    .foregroundStyle(.theme(.textPrimary))
            } icon: {
                // Lucide has no exact match for Conductor's status glyphs, so use
                // normalized SVGs to keep every status icon the same visual size.
                LinearStatusIcon(status: status, size: iconSize)
            }
            .labelStyle(.conductorStandard)
            .textCase(nil)
        }
    }

    private struct ProjectSectionHeader: View {
        let repository: Repository?
        let title: String

        var body: some View {
            Label {
                Text(title)
                    .font(.theme(.body))
            } icon: {
                RepositoryIcon(repository: repository, size: 20, relativeTo: .body)
            }
            .labelStyle(.conductorStandard)
            .foregroundStyle(.theme(.textSecondary))
            .textCase(nil)
        }
    }

    private struct WorkspaceFilterMenu: View {
        @Bindable var store: StoreOf<Workspaces>

        private var selectedRepositoryName: String? {
            guard let selectedRepositoryID = store.selectedRepositoryID else {
                return nil
            }
            return store.repositories.first { $0.id == selectedRepositoryID }?.displayName
                ?? selectedRepositoryID
        }

        var body: some View {
            let repositoryName = selectedRepositoryName

            Menu {
                Menu {
                    RepositoryPicker(
                        store.repositories,
                        selection: Binding(
                            get: { store.selectedRepositoryID },
                            set: { store.send(.repositoryFilterButtonTapped($0), animation: .default) }
                        )
                    )
                } label: {
                    Text("Repository")
                    if let repositoryName {
                        Text(verbatim: repositoryName)
                    } else {
                        Text("All Repositories")
                    }
                }

                Section("Group by") {
                    ConductorMenuPicker(
                        WorkspaceWithRepository.Grouping.allCases,
                        selection: Binding(store.$grouping).animation(.default)
                    ) { grouping in
                        Text(grouping.title)
                    }
                }

                Section("Sort by") {
                    ConductorMenuPicker(
                        WorkspaceWithRepository.Sort.allCases,
                        selection: Binding(
                            get: { store.sort },
                            set: { store.send(.sortButtonTapped($0)) }
                        )
                    ) { sort in
                        Text(sort.title)
                    }
                }
            } label: {
                WorkspaceFilterMenuLabel(repositoryName: repositoryName)
            }
            .accessibilityLabel("Filter workspaces")
            .accessibilityValue(
                repositoryName.map { "Filtered by \($0)" } ?? "All repositories"
            )
        }
    }

    private struct WorkspaceFilterMenuLabel: View {
        let repositoryName: String?
        @ScaledMetric(relativeTo: .body) private var activeIconPadding = 10
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            let isRepositoryFilterActive = repositoryName != nil
            // Mail's active filter capsule reaches farther into the toolbar's leading inset.
            // Widen its drawing bounds, then report the normal width to keep the glyph centered.
            let iconBoundsWidth = isRepositoryFilterActive
                ? iconSize + activeIconPadding / 2
                : iconSize
            let iconLayoutWidth = isRepositoryFilterActive
                ? iconSize + activeIconPadding * 2
                : iconSize

            HStack(spacing: 8) {
                LucideIcon(Lucide.listFilter, size: 20, relativeTo: .body)
                    .frame(width: iconBoundsWidth)
                    .foregroundStyle(
                        Color.theme(
                            isRepositoryFilterActive ? .background : .textPrimary
                        )
                    )
                    .padding(isRepositoryFilterActive ? activeIconPadding : 0)
                    .background(
                        Color.theme(.accent)
                            .opacity(isRepositoryFilterActive ? 1 : 0),
                        in: .capsule
                    )
                    .frame(
                        width: iconLayoutWidth,
                        alignment: .trailing
                    )

                if let repositoryName {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Filtered by")
                            .foregroundStyle(.theme(.textPrimary))
                        Text(repositoryName)
                            .fontWeight(.semibold)
                            .foregroundStyle(.theme(.accent))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.theme(.small))
                    .frame(maxWidth: 160, alignment: .leading)
                }
            }
        }
    }
}

fileprivate extension Set where Element == String {
    /// Adapts persisted collapsed section IDs to `Section`'s positive expansion binding.
    /// Missing IDs remain expanded so new status and project sections open by default.
    subscript(isExpanded id: Element) -> Bool {
        get { !contains(id) }
        set {
            if newValue {
                remove(id)
            } else {
                insert(id)
            }
        }
    }
}

private extension DesktopClient.DeviceIcon {
    var lucideImage: UIImage {
        switch self {
        case .desktop:
            Lucide.monitor

        case .laptop:
            Lucide.laptop

        case .server:
            Lucide.server
        }
    }
}

#if DEBUG
#Preview("Online") {
    WorkspacesPreview(status: .connected)
}

#Preview("Connecting") {
    WorkspacesPreview(status: .connecting)
}

#Preview("Offline") {
    WorkspacesPreview(status: .disconnected)
}

#Preview("Loop") {
    WorkspacesPreview(status: .connected, shouldCycleStatus: true)
}

@MainActor
private struct WorkspacesPreview: View {
    let connectionStatus: Shared<DesktopClient.ConnectionStatus>
    let shouldCycleStatus: Bool
    let store: StoreOf<Workspaces>

    init(
        status: DesktopClient.ConnectionStatus,
        shouldCycleStatus: Bool = false
    ) {
        let _ = try! prepareDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                let conductorMobile = Repository.preview(
                    id: "conductor-mobile",
                    name: "conductor-mobile"
                )
                let conductor = Repository.preview(
                    id: "conductor",
                    displayOrder: 1,
                    name: "Conductor"
                )
                try Repository.upsert { [conductorMobile, conductor] }
                    .execute(db)

                let workspaces = [
                    Workspace.preview(
                        id: "pinned-chat",
                        branch: "Add pinned chats",
                        derivedStatus: Workspace.Status.inProgress.rawValue,
                        pinnedAt: "2026-07-16T09:00:00Z",
                        repositoryID: conductorMobile.id
                    ),
                    Workspace.preview(
                        id: "pinned-settings",
                        branch: "Refine desktop settings",
                        derivedStatus: Workspace.Status.done.rawValue,
                        pinnedAt: "2026-07-16T08:00:00Z",
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "working",
                        branch: "Stream agent responses",
                        derivedStatus: Workspace.Status.inProgress.rawValue,
                        repositoryID: conductorMobile.id
                    ),
                    Workspace.preview(
                        id: "working-desktop",
                        branch: "Relay desktop messages",
                        derivedStatus: Workspace.Status.inProgress.rawValue,
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "in-review-unread",
                        branch: "Polish workspace filters",
                        derivedStatus: Workspace.Status.inReview.rawValue,
                        repositoryID: conductorMobile.id,
                        unread: 1
                    ),
                    Workspace.preview(
                        id: "in-review-desktop",
                        branch: "Review pairing flow",
                        derivedStatus: Workspace.Status.inReview.rawValue,
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "backlog",
                        branch: "Pair another Mac",
                        derivedStatus: Workspace.Status.backlog.rawValue,
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "backlog-mobile",
                        branch: "Add workspace search",
                        derivedStatus: Workspace.Status.backlog.rawValue,
                        repositoryID: conductorMobile.id
                    ),
                    Workspace.preview(
                        id: "done",
                        branch: "Improve connection status",
                        derivedStatus: Workspace.Status.done.rawValue,
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "done-mobile",
                        branch: "Cache repository icons",
                        derivedStatus: Workspace.Status.done.rawValue,
                        repositoryID: conductorMobile.id
                    ),
                    Workspace.preview(
                        id: "canceled",
                        branch: "Try alternate navigation",
                        derivedStatus: Workspace.Status.canceled.rawValue,
                        repositoryID: conductor.id
                    ),
                    Workspace.preview(
                        id: "canceled-mobile",
                        branch: "Prototype compact rows",
                        derivedStatus: Workspace.Status.canceled.rawValue,
                        repositoryID: conductorMobile.id
                    ),
                ]
                try Workspace.upsert { workspaces }
                    .execute(db)
                try MobileWorkspaceState.upsert {
                    [
                        MobileWorkspaceState(
                            workspaceID: "pinned-chat",
                            isWorking: false,
                            pullRequest: PullRequestSnapshot(
                                url: "https://github.com/conductor-preview/mock-repository/pull/101",
                                isDraft: true,
                                isMerged: false
                            )
                        ),
                        MobileWorkspaceState(
                            workspaceID: "working",
                            isWorking: true
                        ),
                        MobileWorkspaceState(
                            workspaceID: "in-review-unread",
                            isWorking: false,
                            pullRequest: PullRequestSnapshot(
                                url: "https://github.com/conductor-preview/mock-repository/pull/102",
                                isDraft: false,
                                isMerged: false,
                                mergeStateStatus: .blocked,
                                checksStatus: .failing
                            )
                        ),
                        MobileWorkspaceState(
                            workspaceID: "in-review-desktop",
                            isWorking: false,
                            pullRequest: PullRequestSnapshot(
                                url: "https://github.com/conductor-preview/mock-repository/pull/103",
                                isDraft: false,
                                isMerged: false,
                                mergeStateStatus: .clean,
                                checksStatus: .passing
                            )
                        ),
                        MobileWorkspaceState(
                            workspaceID: "backlog",
                            isWorking: false,
                            pullRequest: PullRequestSnapshot(
                                url: "https://github.com/conductor-preview/mock-repository/pull/104",
                                isDraft: false,
                                isMerged: false,
                                mergeStateStatus: .dirty
                            )
                        ),
                        MobileWorkspaceState(
                            workspaceID: "done",
                            isWorking: false,
                            pullRequest: PullRequestSnapshot(
                                url: "https://github.com/conductor-preview/mock-repository/pull/105",
                                isDraft: false,
                                isMerged: true
                            )
                        ),
                    ]
                }
                .execute(db)
            }
        }
        let (connectionStatus, store) = withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = status }
            var state = Workspaces.State()
            state.isLoadingWorkspaces = false
            return (
                $connectionStatus,
                Store(initialState: state) {
                    Workspaces()
                }
            )
        }
        self.connectionStatus = connectionStatus
        self.shouldCycleStatus = shouldCycleStatus
        self.store = store
    }

    var body: some View {
        NavigationStack {
            WorkspacesView(store: store)
        }
        .preferredColorScheme(.dark)
        .task {
            await cycleStatus()
        }
    }

    private func cycleStatus() async {
        guard shouldCycleStatus else {
            return
        }

        let statuses = DesktopClient.ConnectionStatus.allPreviewStatuses
        var index = statuses.firstIndex(of: connectionStatus.wrappedValue) ?? 0
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: .seconds(3))
            } catch {
                return
            }

            index = (index + 1) % statuses.count
            connectionStatus.withLock { $0 = statuses[index] }
        }
    }
}

private extension DesktopClient.ConnectionStatus {
    static let allPreviewStatuses: [Self] = [
        .connected,
        .connecting,
        .disconnected,
    ]
}

#endif
