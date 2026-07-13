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
        struct WorkspaceSection: Equatable, Identifiable, Sendable {
            var id: String { groupByType.id }
            let groupByType: GroupByType
            var items: [WorkspaceWithRepository]

            enum GroupByType: Equatable, Sendable {
                case status(Workspace.Status)
                case project(
                    repositoryID: Repository.ID?,
                    repository: Repository?,
                    title: String
                )

                var id: String {
                    switch self {
                    case let .status(status): "status:\(status.rawValue)"
                    case let .project(repositoryID, _, _):
                        "project:\(repositoryID ?? "")"
                    }
                }
            }
        }

        @Presents public var alert: AlertState<Action.Alert>?

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
            switch grouping {
            case .status:
                let initialSections = Workspace.Status.displayOrder.map { status in
                    WorkspaceSection(
                        groupByType: .status(status),
                        items: []
                    )
                }

                return workspaces.reduce(into: initialSections) { sections, item in
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
                return workspaces.reduce(into: []) { sections, item in
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
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case groupingChanged(WorkspaceWithRepository.Grouping)
        case loadWorkspacesFailed(any Error)
        case repositoryFilterButtonTapped(String?)
        case setWorkspacePinnedFailed(any Error)
        case setWorkspaceStatusFailed(any Error)
        case setWorkspaceUnreadFailed(any Error)
        case sortButtonTapped(WorkspaceWithRepository.Sort)
        case task
        case workspacesChanged([WorkspaceWithRepository])
        case workspacePinnedButtonTapped(WorkspaceWithRepository)
        case workspaceStatusButtonTapped(WorkspaceWithRepository, Workspace.Status)
        case workspaceTapped(WorkspaceWithRepository)
        case workspaceUnreadButtonTapped(WorkspaceWithRepository)

        public enum Alert: Equatable {
        }
    }

    @Dependency(\.defaultDatabase) var database
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
                    observeWorkspaces()
                )

            case let .groupingChanged(grouping):
                state.sections = State.sections(
                    groupedBy: grouping,
                    workspaces: state.workspaces
                )
                return reloadWorkspaces(state)

            case let .loadWorkspacesFailed(error):
                state.alert = .failedToLoadWorkspaces(error: error)
                return .none

            case let .repositoryFilterButtonTapped(repositoryID):
                state.$selectedRepositoryID.withLock { $0 = repositoryID }
                return reloadWorkspaces(state)

            case let .sortButtonTapped(sort):
                state.$sort.withLock { $0 = sort }
                return reloadWorkspaces(state)

            case let .setWorkspacePinnedFailed(error):
                state.alert = .failedToUpdateWorkspacePin(error: error)
                return .none

            case let .setWorkspaceStatusFailed(error):
                state.alert = .failedToUpdateWorkspaceStatus(error: error)
                return .none

            case let .setWorkspaceUnreadFailed(error):
                state.alert = .failedToUpdateWorkspaceUnreadStatus(error: error)
                return .none

            case let .workspacesChanged(workspaces):
                state.sections = State.sections(
                    groupedBy: state.grouping,
                    workspaces: workspaces
                )
                return .none

            case let .workspacePinnedButtonTapped(item):
                let pinned = item.workspace.pinnedAt == nil
                let pinnedAt = pinned ? now.ISO8601Format() : nil

                return updateWorkspace(failure: Action.setWorkspacePinnedFailed) {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update {
                                $0.pinnedAt = pinnedAt
                            }
                            .execute(db)
                    }
                    try await desktopClient.setWorkspacePinned(
                        item.id,
                        pinned
                    )
                }

            case let .workspaceStatusButtonTapped(item, status):
                guard item.workspace.status != status else {
                    return .none
                }

                return updateWorkspace(failure: Action.setWorkspaceStatusFailed) {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update {
                                $0.manualStatus = #bind(status.rawValue)
                            }
                            .execute(db)
                    }
                    try await desktopClient.setWorkspaceStatus(item.id, status)
                }

            case let .workspaceUnreadButtonTapped(item):
                let hasUnread = (item.workspace.unread ?? 0) == 0

                return updateWorkspace(failure: Action.setWorkspaceUnreadFailed) {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update {
                                $0.unread = #bind(hasUnread ? 1 : 0)
                            }
                            .execute(db)
                    }
                    try await desktopClient.setWorkspaceUnread(
                        item.id,
                        hasUnread
                    )
                }

            case .alert, .workspaceTapped:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func updateWorkspace(
        failure: @escaping @Sendable (any Error) -> Action,
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Effect<Action> {
        .run { send in
            do {
                try await operation()
            } catch {
                Logger.workspace.error("Failed to update workspace: \(error)")
                await send(failure(error))
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

    private func observeWorkspaces() -> Effect<Action> {
        .run { send in
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
            } onFailure: { error in
                Logger.workspace.error("Failed to observe workspaces: \(error)")
                await send(.loadWorkspacesFailed(error))
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

    static func failedToUpdateWorkspacePin(error: any Error) -> Self {
        AlertState {
            TextState("Failed to update workspace pin")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToUpdateWorkspaceStatus(error: any Error) -> Self {
        AlertState {
            TextState("Failed to update workspace status")
        } message: {
            TextState(error.localizedDescription)
        }
    }

    static func failedToUpdateWorkspaceUnreadStatus(error: any Error) -> Self {
        AlertState {
            TextState("Failed to update workspace unread status")
        } message: {
            TextState(error.localizedDescription)
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
        .listStyle(.plain)
        .animation(.default, value: store.sections)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .overlay {
            if store.workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "rectangle.stack",
                    description: Text("Pair with Conductor on your Mac to see workspaces here.")
                )
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
            }
        }
        .themedNavigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                WorkspaceFilterMenu(store: store)
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .preferredColorScheme(.dark)
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
        let action: @MainActor (WorkspaceWithRepository, WorkspaceRowAction) -> Void

        var body: some View {
            ForEach(items) { item in
                WorkspaceRow(
                    item: item,
                    showsRepositoryIcon: showsRepositoryIcon
                ) { rowAction in
                    action(item, rowAction)
                }
                .padding(.leading, 12)
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
                Menu("Group by") {
                    Picker(
                        "Group by",
                        selection: Binding(store.$grouping).animation(.default)
                    ) {
                        ForEach(WorkspaceWithRepository.Grouping.allCases, id: \.self) { grouping in
                            Text(grouping.title)
                                .tag(grouping)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Menu("Repository") {
                    Picker(
                        "Repository",
                        selection: $store.selectedRepositoryID.sending(
                            \.repositoryFilterButtonTapped
                        )
                        .animation(.default)
                    ) {
                        Text("All Repositories")
                            .tag(String?.none)

                        ForEach(store.repositories) { repository in
                            Text(repository.displayName)
                                .tag(Optional(repository.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }

                Section("Sort by") {
                    ForEach(WorkspaceWithRepository.Sort.allCases, id: \.self) { sort in
                        Button {
                            store.send(.sortButtonTapped(sort))
                        } label: {
                            if store.sort == sort {
                                Label {
                                    Text(sort.title)
                                } icon: {
                                    ColoredMenuImage(
                                        Lucide.check,
                                        color: .theme(.textPrimary)
                                    )
                                }
                            } else {
                                Text(sort.title)
                            }
                        }
                    }
                }
            } label: {
                WorkspaceFilterMenuLabel(repositoryName: repositoryName)
            }
            .accessibilityLabel("Filter workspaces")
            .accessibilityValue(
                repositoryName.map { "Grouped by \($0)" } ?? "All repositories"
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
                        Text("Grouped by")
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

#Preview {
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
    }

    NavigationStack {
        WorkspacesView(
            store: Store(initialState: Workspaces.State()) {
                Workspaces()
            }
        )
    }
    .preferredColorScheme(.dark)
}
