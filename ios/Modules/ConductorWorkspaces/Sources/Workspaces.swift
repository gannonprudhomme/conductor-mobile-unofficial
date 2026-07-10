import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import LucideIcons
import SQLiteData
import SwiftUI

@Reducer
public struct Workspaces: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        @FetchAll(
            Workspace
                .where { $0.state.neq(Workspace.State.archived) }
                .order { $0.updatedAt.desc() },
            animation: .default
        )
        public var workspaces

        public init() {
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case loadWorkspacesFailed(String)
        case refresh
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
            case .alert, .workspaceTapped:
                return .none

            case let .loadWorkspacesFailed(message):
                state.alert = .failedToLoadWorkspaces(message: message)
                return .none

            case .task, .refresh:
                return .run { send in
                    do {
                        try await loadWorkspaces()
                    } catch {
                        await send(.loadWorkspacesFailed(error.localizedDescription))
                    }
                }
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func loadWorkspaces() async throws {
        let workspaces = try await desktopClient.fetchWorkspaces()

        try await database.write { db in
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
        List(store.workspaces) { workspace in
            WorkspaceRow(workspace: workspace) {
                store.send(.workspaceTapped(workspace))
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
        .refreshable {
            await store.send(.refresh).finish()
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .task {
            await store.send(.task).finish()
        }
    }

    private struct WorkspaceRow: View {
        let workspace: Workspace
        let action: () -> Void
        @ScaledMetric(relativeTo: .body) private var chevronSize = 16
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Button(action: action) {
                HStack {
                    Label {
                        Text(workspace.displayBranchName)
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
}

#Preview {
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
    }

    WorkspacesView(
        store: Store(initialState: Workspaces.State()) {
            Workspaces()
        }
    )
    .preferredColorScheme(.dark)
}
