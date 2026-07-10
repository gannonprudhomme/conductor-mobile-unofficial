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
        @Presents public var alert: AlertState<Action.Alert>?

        @FetchAll(
            Repository.all
                .order { ($0.name.lower(), $0.id) },
            animation: .default
        )
        public var repositories: [Repository] = []

        @Shared(.selectedRepositoryID)
        public var selectedRepositoryID

        @Shared(.workspaceSort)
        public var sort

        @FetchAll(
            WorkspaceWithRepository.all(),
            animation: .default
        )
        public var workspaces: [WorkspaceWithRepository] = []

        public init() {
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case loadWorkspacesFailed(String)
        case repositoryFilterButtonTapped(String?)
        case refresh
        case sortButtonTapped(WorkspaceWithRepository.Sort)
        case task
        case workspaceTapped(Workspace)

        public enum Alert: Equatable {
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() {
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task, .refresh:
                return .run { send in
                    do {
                        try await loadWorkspaces()
                    } catch {
                        await send(.loadWorkspacesFailed(error.localizedDescription))
                    }
                }

            case .alert, .workspaceTapped:
                return .none

            case let .loadWorkspacesFailed(message):
                state.alert = .failedToLoadWorkspaces(message: message)
                return .none

            case let .repositoryFilterButtonTapped(repositoryID):
                state.$selectedRepositoryID.withLock { $0 = repositoryID }
                return reloadWorkspaces(state)

            case let .sortButtonTapped(sort):
                state.$sort.withLock { $0 = sort }
                return reloadWorkspaces(state)
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func reloadWorkspaces(_ state: State) -> Effect<Action> {
        .run { [
            selectedRepositoryID = state.selectedRepositoryID,
            sort = state.sort,
            workspaces = state.$workspaces,
        ] send in
            do {
                let query = WorkspaceWithRepository.all(
                    repositoryID: selectedRepositoryID,
                    sortedBy: sort
                )
                try await workspaces.load(query, animation: .default)
            } catch {
                await send(.loadWorkspacesFailed(error.localizedDescription))
            }
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

    public init(store: StoreOf<Workspaces>) {
        self.store = store
    }

    public var body: some View {
        List(store.workspaces) { item in
            WorkspaceRow(item: item) {
                store.send(.workspaceTapped(item.workspace))
            }
            .listRowBackground(Color.theme(.background))
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
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

    private struct WorkspaceRow: View {
        let item: WorkspaceWithRepository
        let action: () -> Void
        @ScaledMetric(relativeTo: .body) private var chevronSize = 16
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Button(action: action) {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.workspace.displayBranchName)
                            Text(item.repositoryDisplayName)
                                .font(.theme(.footnote))
                                .foregroundStyle(.theme(.textSecondary))
                        }
                    } icon: {
                        Image(uiImage: Lucide.gitBranch)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: iconSize, height: iconSize)
                            .foregroundStyle(.theme(.textSecondary))
                    }
                    Spacer()
                    Image(uiImage: Lucide.chevronRight)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: chevronSize, height: chevronSize)
                        .foregroundStyle(.theme(.textSecondary))
                }
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private struct WorkspaceFilterMenu: View {
        @Bindable var store: StoreOf<Workspaces>
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Menu {
                Menu("Repository") {
                    Picker(
                        "Repository",
                        selection: $store.selectedRepositoryID.sending(
                            \.repositoryFilterButtonTapped
                        )
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
            }
            .accessibilityLabel("Filter workspaces")
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
