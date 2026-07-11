import Combine
import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import LucideIcons
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
        case loadWorkspacesFailed(String)
        case repositoryFilterButtonTapped(String?)
        case refresh
        case sortButtonTapped(WorkspaceWithRepository.Sort)
        case task
        case workspacesChanged([WorkspaceWithRepository])
        case workspaceTapped(WorkspaceWithRepository)

        public enum Alert: Equatable {
        }
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
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
                    .run { send in
                        await refreshWorkspaces(send: send)
                        for await _ in clock.timer(interval: .seconds(1)) {
                            await refreshWorkspaces(send: send)
                        }
                    }
                )

            case let .groupingChanged(grouping):
                state.sections = State.sections(
                    groupedBy: grouping,
                    workspaces: state.workspaces
                )
                return reloadWorkspaces(state)

            case .alert, .workspaceTapped:
                return .none

            case let .loadWorkspacesFailed(message):
                state.alert = .failedToLoadWorkspaces(message: message)
                return .none

            case let .repositoryFilterButtonTapped(repositoryID):
                state.$selectedRepositoryID.withLock { $0 = repositoryID }
                return reloadWorkspaces(state)

            case .refresh:
                return .run { send in
                    await refreshWorkspaces(send: send)
                }

            case let .sortButtonTapped(sort):
                state.$sort.withLock { $0 = sort }
                return reloadWorkspaces(state)

            case let .workspacesChanged(workspaces):
                state.sections = State.sections(
                    groupedBy: state.grouping,
                    workspaces: workspaces
                )
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
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
                await send(.loadWorkspacesFailed(error.localizedDescription))
            }
        }
    }

    private func refreshWorkspaces(send: Send<Action>) async {
        do {
            try await loadWorkspaces()
        } catch is CancellationError {
            return
        } catch {
            await send(.loadWorkspacesFailed(error.localizedDescription))
        }
    }

    private func loadWorkspaces() async throws {
        async let fetchedWorkspaces = desktopClient.fetchWorkspaces()
        async let fetchedRepositories = desktopClient.fetchRepositories()
        let (workspaces, repositories) = try await (fetchedWorkspaces, fetchedRepositories)

        try await database.write { db in
            for repository in repositories {
                try Repository.upsert { repository }
                    .execute(db)
            }
            for workspace in workspaces {
                try Workspace.upsert { workspace }
                    .execute(db)
            }
        }
    }
}

extension AlertState where Action == Workspaces.Action.Alert {
    static func failedToLoadWorkspaces(message: String) -> Self {
        AlertState {
            TextState("Failed to load workspaces")
        } message: {
            TextState(message)
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
            ForEach(store.sections) { section in
                WorkspaceSectionView(
                    section: section,
                    showsRepositoryIcon: store.grouping == .status
                        && store.selectedRepositoryID == nil,
                    isExpanded: Binding($collapsedSectionIDs)[isExpanded: section.id]
                        .animation(.default)
                ) {
                    store.send(.workspaceTapped($0))
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
            ToolbarItem(placement: .topBarTrailing) {
                WorkspaceFilterMenu(store: store)
            }
        }
        .refreshable {
            await store.send(.refresh).finish()
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .task {
            await store.send(.task).finish()
        }
        .preferredColorScheme(.dark)
    }

    private struct WorkspaceSectionView: View {
        let section: Workspaces.State.WorkspaceSection
        let showsRepositoryIcon: Bool

        @Binding var isExpanded: Bool

        let action: (WorkspaceWithRepository) -> Void

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
        }
    }

    private struct WorkspaceSectionHeader: View {
        let groupByType: Workspaces.State.WorkspaceSection.GroupByType
        let count: Int
        let isExpanded: Bool
        @ScaledMetric(relativeTo: .body) private var disclosureIconSize = 12

        var body: some View {
            HStack(spacing: 8) {
                switch groupByType {
                case let .status(status):
                    StatusSectionHeader(
                        status: status,
                        count: count
                    )

                case let .project(_, repository, title):
                    ProjectSectionHeader(
                        repository: repository,
                        title: title,
                        count: count
                    )
                }

                Image(uiImage: Lucide.chevronDown)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: disclosureIconSize, height: disclosureIconSize)
                    .foregroundStyle(.theme(.sidebarMutedForeground))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
    }

    private struct WorkspaceRows: View {
        let items: [WorkspaceWithRepository]
        let showsRepositoryIcon: Bool
        let action: (WorkspaceWithRepository) -> Void

        var body: some View {
            ForEach(items) { item in
                WorkspaceRow(
                    item: item,
                    showsRepositoryIcon: showsRepositoryIcon
                ) {
                    action(item)
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
        let count: Int
        @ScaledMetric(relativeTo: .body) private var iconSize = 13.2

        var body: some View {
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 12) { // optically the number's alignment looks weird w/o this
                    Text(status.title)
                        .font(.theme(.body))
                        .fontWeight(.semibold)
                        .foregroundStyle(.theme(.textPrimary))

                    Text(count, format: .number)
                        .font(.theme(.extraSmall))
                        .foregroundStyle(.theme(.textSecondary))
                        .contentTransition(.numericText(value: Double(count)))
                }
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
        let count: Int
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.theme(.body))

                    Text(count, format: .number)
                        .font(.theme(.extraSmall))
                        .contentTransition(.numericText(value: Double(count)))
                }
            } icon: {
                RepositoryIcon(repository: repository, size: iconSize)
            }
            .labelStyle(.conductorStandard)
            .foregroundStyle(.theme(.textSecondary))
            .textCase(nil)
        }
    }

    private struct WorkspaceRow: View {
        let item: WorkspaceWithRepository
        let showsRepositoryIcon: Bool
        let action: () -> Void
        @ScaledMetric(relativeTo: .body) private var chevronSize = 16
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Button(action: action) {
                LabeledContent {
                    Image(uiImage: Lucide.chevronRight)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: chevronSize, height: chevronSize)
                        .foregroundStyle(.theme(.textSecondary))
                } label: {
                    Label {
                        Text(item.workspace.displayBranchName)
                            .foregroundStyle(.theme(isUnread ? .textPrimary : .textSecondary))
                            .fontWeight(isUnread ? .semibold : .regular)
                            .lineLimit(1)
                    } icon: {
                        if showsRepositoryIcon {
                            RepositoryIcon(repository: item.repository, size: iconSize)
                        }

                        if item.workspace.isWorking {
                            ProgressView()
                                .progressViewStyle(.conductor(phaseSeed: item.workspace.id))
                                .tint(.theme(.textSecondary))
                                .frame(width: iconSize, height: iconSize)
                        } else {
                            Image(uiImage: Lucide.gitBranch)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: iconSize, height: iconSize)
                                .foregroundStyle(.theme(.textSecondary))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .labelStyle(.conductorStandard)
                .labeledContentStyle(.conductorStandard)
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private var isUnread: Bool {
            (item.workspace.unread ?? 0) > 0
        }
    }

    private struct WorkspaceFilterMenu: View {
        @Bindable var store: StoreOf<Workspaces>
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
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
                                Label(sort.title, systemImage: "checkmark")
                            } else {
                                Text(sort.title)
                            }
                        }
                    }
                }
            } label: {
                Image(uiImage: Lucide.listFilter)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(.theme(.textPrimary))
            }
            .accessibilityLabel("Filter workspaces")
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
