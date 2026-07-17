//
//  Workspaces.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Combine
import ComposableArchitecture
import SharedConductorData
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import Logging
import Sharing
import SQLiteData
import SwiftUI

@Reducer
public struct Workspaces: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        @Shared(.desktopConnectionStatus)
        public var connectionStatus

        @Shared(.desktopDisplayConfiguration)
        public var displayConfiguration

        @FetchAll(
            Repository.all
                .order { ($0.displayOrder, $0.name.lower(), $0.id) },
            animation: .default
        )
        public var repositories: [Repository] = []

        @Shared(.collapsedWorkspaceSectionIDs)
        var collapsedSectionIDs

        @Shared(.workspaceGrouping)
        public var grouping

        @Shared(.selectedRepositoryID)
        public var selectedRepositoryID

        @Shared(.workspaceSort)
        public var sort

        @FetchAll(
            WorkspaceWithRepository.all(),
            animation: .default
        )
        public var workspaces: [WorkspaceWithRepository] = []

        var isLoadingWorkspaces = true
        var sections: [WorkspaceSection] = []

        public init() {
            _workspaces = FetchAll(
                WorkspaceWithRepository.all(
                    repositoryID: selectedRepositoryID,
                    sortedBy: sort,
                    groupedBy: grouping
                ),
                animation: .default
            )
            sections = Self.sections(groupedBy: grouping, workspaces: workspaces)
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
                        item.workspace.status
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

    public enum Action {
        case alert(PresentationAction<Alert>)
        case groupingChanged(WorkspaceWithRepository.Grouping)
        case initialWorkspacesResponse
        case loadWorkspacesFailed(any Error)
        case repositoryFilterButtonTapped(String?)
        case sortButtonTapped(WorkspaceWithRepository.Sort)
        /// Note: `MainView` handles this action so we can keep this module decoupled from `ConductorSettings`
        case settingsButtonTapped
        case task
        case workspacesChanged([WorkspaceWithRepository])
        case workspaceMutationFailed(any Error)
        case workspaceMutationUsedSQLiteFallback
        case workspacePinnedButtonTapped(WorkspaceWithRepository)
        case workspaceStatusButtonTapped(WorkspaceWithRepository, Workspace.Status)
        case workspaceTapped(WorkspaceWithRepository)
        case workspaceUnreadButtonTapped(WorkspaceWithRepository)

        public enum Alert: Equatable {
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.desktopClient) var desktopClient

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let grouping = state.$grouping
                let workspaces = state.$workspaces
                // Shared publishers immediately replay their current values. `State.init`
                // already used those values to build sections, so observe only later changes.
                return .merge(
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
                    monitorConnection(),
                    observeWorkspaces(state)
                )

            case let .groupingChanged(grouping):
                state.sections = State.sections(
                    groupedBy: grouping,
                    workspaces: state.workspaces
                )
                return reloadWorkspaces(state)

            case .initialWorkspacesResponse:
                state.isLoadingWorkspaces = false
                return .none

            case let .loadWorkspacesFailed(error):
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.alert = .failedToLoadWorkspaces(error: error)
                return .none

            case let .repositoryFilterButtonTapped(repositoryID):
                state.$selectedRepositoryID.withLock { $0 = repositoryID }
                return reloadWorkspaces(state)

            case let .sortButtonTapped(sort):
                state.$sort.withLock { $0 = sort }
                return reloadWorkspaces(state)

            case let .workspacesChanged(workspaces):
                state.sections = State.sections(
                    groupedBy: state.grouping,
                    workspaces: workspaces
                )
                return .none

            case let .workspaceMutationFailed(error):
                state.alert = .failedToUpdateWorkspace(error: error)
                return .none

            case .workspaceMutationUsedSQLiteFallback:
                state.alert = .workspaceMutationUsedSQLiteFallback
                return .none

            case let .workspacePinnedButtonTapped(item):
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
                guard item.workspace.status != status else {
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

            case .alert, .settingsButtonTapped, .workspaceTapped:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func updateWorkspace(
        _ optimisticUpdate: @escaping @Sendable () async throws -> Void,
        rollback: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async throws -> WorkspaceMutationPath
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

    private func observeWorkspaces(_ state: State) -> Effect<Action> {
        .run { [initiallyIsLoadingWorkspaces = state.isLoadingWorkspaces] send in
            var isAwaitingInitialResponse = initiallyIsLoadingWorkspaces
            await WebSocketHelpers.observe {
                desktopClient.observeWorkspaces()
            } onValue: { snapshot in
                try await database.write { db in
                    try Repository
                        .upsert { snapshot.repositories }
                        .execute(db)
                    try Workspace
                        .upsert { snapshot.workspaces.map(\.workspace) }
                        .execute(db)

                    try MobileWorkspaceState.upsert {
                        snapshot.workspaces.map {
                            MobileWorkspaceState(
                                workspaceID: $0.workspace.id,
                                isWorking: $0.isWorking
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
                Logger.workspace.error("Failed to observe workspaces: \(error)")
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
    }
}

extension AlertState where Action == Workspaces.Action.Alert {
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

    public init(store: StoreOf<Workspaces>) {
        self.store = store
    }

    public var body: some View {
        List {
            if !store.workspaces.isEmpty {
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
        .listStyle(.plain)
        .animation(.default, value: store.sections)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .overlay {
            if store.isLoadingWorkspaces {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(.theme(.background))
            } else if store.workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "rectangle.stack",
                    description: Text("Pair with Conductor on your Mac to see workspaces here.")
                )
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
            }
        }
        .themedNavigationTitle("Conductor", alignment: .leading) {
            ConnectionStatusSubtitle(
                status: store.connectionStatus,
                displayConfiguration: store.displayConfiguration
            )
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
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .preferredColorScheme(.dark)
    }

    private struct ConnectionStatusSubtitle: View {
        let status: DesktopClient.ConnectionStatus
        let displayConfiguration: DesktopClient.DisplayConfiguration?

        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var indicatorFrameSize = 12

        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var indicatorSize = 8

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
                    indicator

                    LucideIcon(deviceIcon.lucideImage, style: .small)
                }
            }
            .labelStyle(.conductorExtraSmall)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayName)
            .accessibilityValue(accessibilityValue)
        }

        private var indicator: some View {
            Group {
                switch status {
                case .connected, .disconnected:
                    Circle()
                        .fill(.theme(status == .connected ? .gitGreen : .gitRed))
                        .frame(width: indicatorSize, height: indicatorSize)

                case .connecting:
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textSecondary))
                        .controlSize(.mini)
                }
            }
            .frame(width: indicatorFrameSize, height: indicatorFrameSize)
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
    }

    private func workspaceRowAction(
        _ action: WorkspaceRowAction,
        item: WorkspaceWithRepository
    ) {
        switch action {
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
                    showsRepositoryIcon: showsRepositoryIcon
                ) { rowAction in
                    action(item, rowAction)
                }
                .padding(.leading, isIndented ? 12 : 0)
                .listRowInsets(
                    EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
                    Picker(
                        "Repository",
                        selection: Binding(
                            get: { store.selectedRepositoryID },
                            set: { store.send(.repositoryFilterButtonTapped($0), animation: .default) }
                        )
                    ) {
                        Text("All Repositories")
                            .tag(String?.none)

                        ForEach(store.repositories) { repository in
                            Label {
                                Text(verbatim: repository.displayName)
                            } icon: {
                                RepositoryIcon(
                                    repository: repository,
                                    size: 16,
                                    relativeTo: .body
                                )
                            }
                            .tag(Optional(repository.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
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
                        Text("Filter by")
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
                    MobileWorkspaceState(workspaceID: "working", isWorking: true)
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
