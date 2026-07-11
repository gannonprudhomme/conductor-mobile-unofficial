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
        @Presents public var destination: Destination.State?
        public var hasLoadedSessions = false
        public let repository: Repository?
        public let workspace: Workspace

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]

        public init(workspace: Workspace, repository: Repository? = nil) {
            self.repository = repository
            self.workspace = workspace
            self._activeSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and(!$0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )
            self._archivedSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and($0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )
        }

        public var repositoryDisplayName: String {
            WorkspaceWithRepository(
                workspace: workspace,
                repository: repository
            )
            .repositoryDisplayName
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)
        case archivedSessions(ArchivedSessions)

        public enum Alert: Equatable { }
    }

    public enum Action {
        case archivedSessionsButtonTapped
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsFailed(String)
        case loadSessionsSucceeded
        case refresh
        case sessionTapped(Session)
        case task
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { [workspaceID = state.workspace.id] send in
                    await refreshSessions(workspaceID: workspaceID, send: send)
                    for await _ in clock.timer(interval: .seconds(1)) {
                        await refreshSessions(workspaceID: workspaceID, send: send)
                    }
                }

            case .archivedSessionsButtonTapped:
                state.destination = .archivedSessions(
                    ArchivedSessions.State(
                        workspaceID: state.workspace.id,
                        sessions: state.archivedSessions
                    )
                )
                return .none

            case .destination, .sessionTapped:
                return .none

            case let .loadSessionsFailed(message):
                state.destination = .alert(.failedToLoadSessions(message: message))
                return .none

            case .loadSessionsSucceeded:
                state.hasLoadedSessions = true
                return .none

            case .refresh:
                return .run { [workspaceID = state.workspace.id] send in
                    await refreshSessions(workspaceID: workspaceID, send: send)
                }
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func refreshSessions(workspaceID: String, send: Send<Action>) async {
        do {
            try await loadSessions(workspaceID: workspaceID)
            await send(.loadSessionsSucceeded)
        } catch is CancellationError {
            return
        } catch {
            await send(.loadSessionsFailed(error.localizedDescription))
        }
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

extension SessionsList.Destination.State: Equatable { }

extension AlertState where Action == SessionsList.Destination.Alert {
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
    @ScaledMetric(relativeTo: .footnote) private var repositoryIconSize = 13
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 20

    public init(store: StoreOf<SessionsList>) {
        self.store = store
    }

    public var body: some View {
        List(store.activeSessions) { session in
            SessionRow(session: session) {
                store.send(.sessionTapped(session))
            }
                .listRowBackground(Color.theme(.background))
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.theme(.background))
        .overlay {
            // Only display the no sessions text when we're 100% sure there aren't sessions (aka we've fetched)
            if store.hasLoadedSessions && store.activeSessions.isEmpty {
                ContentUnavailableView(
                    "No sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This workspace has no sessions. Is this not impossible?")
                )
                .foregroundStyle(.theme(.textPrimary))
                .font(.theme(.body))
            }
        }
        .themedNavigationTitle(
            verbatim: store.workspace.displayBranchName,
            alignment: .leading
        ) {
            HStack(spacing: 4) {
                if let repository = store.repository {
                    RepositoryIcon(repository: repository, size: repositoryIconSize)
                } else {
                    RepositoryIcon(iconName: nil, avatarURL: nil, size: repositoryIconSize)
                }

                Text(verbatim: store.repositoryDisplayName)
                    .lineLimit(1)
            }
        }
        .toolbar {
            if !store.archivedSessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.send(.archivedSessionsButtonTapped)
                    } label: {
                        Image(uiImage: Lucide.history)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: toolbarIconSize, height: toolbarIconSize)
                            .foregroundStyle(.theme(.textPrimary))
                    }
                    .accessibilityLabel("Archived sessions")
                }
            }
        }
        .refreshable {
            await store.send(.refresh).finish()
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .sheet(
            item: $store.scope(
                state: \.destination?.archivedSessions,
                action: \.destination.archivedSessions
            )
        ) { archivedSessionsStore in
            ArchivedSessionsView(store: archivedSessionsStore)
                .presentationDetents([.medium, .large])
        }
        .task {
            await store.send(.task).finish()
        }
    }

    private struct SessionRow: View {
        let session: Session
        let action: () -> Void
        @ScaledMetric(relativeTo: .body) private var iconSize = 20

        var body: some View {
            Button(action: action) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle)
                            .font(.theme(.body))
                            .foregroundStyle(.theme(.textPrimary))
                            .lineLimit(1)

                        Text(session.debugSubtitle)
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.textSecondary))
                            .lineLimit(1)
                    }
                } icon: {
                    if session.status == .working {
                        ProgressView()
                            .progressViewStyle(.conductor(phaseSeed: session.id))
                            .tint(.theme(.textSecondary))
                            .frame(width: iconSize, height: iconSize)
                    } else {
                        AgentIcon(agentType: session.agentType, size: iconSize)
                    }
                }
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
    let workspace = try! JSONDecoder.conductor.decode(
        Workspace.self,
        from: Data(
            """
            {
              "id": "workspace-1",
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "is_working": false
            }
            """.utf8
        )
    )

    NavigationStack {
        SessionsListView(
            store: Store(
                initialState: SessionsList.State(
                    workspace: workspace,
                    repository: .preview()
                )
            ) {
                SessionsList()
            }
        )
    }
    .preferredColorScheme(.dark)
}
