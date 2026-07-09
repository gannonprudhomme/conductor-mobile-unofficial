import ComposableArchitecture
import ConductorData
import Foundation
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
            case .alert:
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
        NavigationStack {
            List(store.workspaces) { workspace in
                WorkspaceRow(workspace: workspace)
            }
            .listStyle(.plain)
            .overlay {
                if store.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No Workspaces",
                        systemImage: "rectangle.stack",
                        description: Text("Pair with Conductor on your Mac to see workspaces here.")
                    )
                }
            }
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await store.send(.refresh).finish()
            }
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .task {
            await store.send(.task).finish()
        }
    }

    private struct WorkspaceRow: View {
        let workspace: Workspace

        var body: some View {
            Label {
                Text(workspace.displayBranchName)
            } icon: {
                Image(systemName: "tv")
            }
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
}
