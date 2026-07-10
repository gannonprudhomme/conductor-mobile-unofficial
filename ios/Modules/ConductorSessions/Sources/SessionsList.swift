import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import LucideIcons
import SQLiteData
import SwiftUI

@Reducer
public struct SessionsList: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?
        public var hasLoadedSessions = false
        public let workspace: Workspace

        @FetchAll(Session.none)
        public var sessions

        public init(workspace: Workspace) {
            self.workspace = workspace
            self._sessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case loadSessionsFailed(String)
        case loadSessionsSucceeded
        case refresh
        case task

        public enum Alert: Equatable { }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .alert:
                return .none

            case let .loadSessionsFailed(message):
                state.alert = .failedToLoadSessions(message: message)
                return .none

            case .loadSessionsSucceeded:
                state.hasLoadedSessions = true
                return .none

            case .refresh, .task:
                let workspaceID = state.workspace.id
                return .run { send in
                    do {
                        try await loadSessions(workspaceID: workspaceID)
                        await send(.loadSessionsSucceeded)
                    } catch {
                        await send(.loadSessionsFailed(error.localizedDescription))
                    }
                }
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    private func loadSessions(workspaceID: String) async throws {
        let sessions = try await desktopClient.fetchSessions(workspaceID)

        try await database.write { db in
            try Session
                .where { $0.workspaceID.eq(workspaceID) }
                .delete()
                .execute(db)

            for session in sessions {
                try Session.upsert { session }
                    .execute(db)
            }
        }
    }
}

extension AlertState where Action == SessionsList.Action.Alert {
    static func failedToLoadSessions(message: String) -> Self {
        AlertState {
            TextState("Failed to load sessions")
        } message: {
            TextState(message)
        }
    }
}

public struct SessionsListView: View {
    @Bindable var store: StoreOf<SessionsList>

    public init(store: StoreOf<SessionsList>) {
        self.store = store
    }

    public var body: some View {
        List(store.sessions) { session in
            SessionRow(session: session)
                .listRowBackground(Color.theme(.background))
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .overlay {
            // Only display the no sessions text when we're 100% sure there aren't sessions (aka we've fetched)
            if store.hasLoadedSessions && store.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This workspace has no sessions. Is this not impossible?")
                )
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
            }
        }
        .themedNavigationTitle("Sessions")
        .refreshable {
            await store.send(.refresh).finish()
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.alert, action: \.alert))
        .task {
            await store.send(.task).finish()
        }
    }

    private struct SessionRow: View {
        let session: Session
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.theme(.body))
                        .foregroundStyle(.theme(.textPrimary))
                    Text(session.debugSubtitle)
                        .font(.theme(.footnote))
                        .foregroundStyle(.theme(.textSecondary))
                        .lineLimit(1)
                }
            } icon: {
                Image(uiImage: Lucide.messageSquare)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(.theme(.textSecondary))
            }
        }
    }
}

#Preview {
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
    }
    let workspace = try! JSONDecoder().decode(
        Workspace.self,
        from: Data(
            """
            {
              "id": "workspace-1",
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00"
            }
            """.utf8
        )
    )

    NavigationStack {
        SessionsListView(
            store: Store(initialState: SessionsList.State(workspace: workspace)) {
                SessionsList()
            }
        )
    }
    .preferredColorScheme(.dark)
}
