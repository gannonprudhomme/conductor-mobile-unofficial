//
//  WorkspaceChat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//

import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import LucideIcons
import SQLiteData
import SwiftUI

/// A wrapper over ``Chat`` which enables switch between sessions for this workspace
@Reducer
public struct WorkspaceChat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?

        // TODO: Ideally this would be non-nil but couldn't figure out a good way to achieve it
        var chat: Chat.State?

        /// We want to switch to the active session if our local cached data is out of date and we get
        /// and updated active_session from the remote.
        ///
        /// However we want to prevent that from overriding a local switch from the user
        var shouldPreferRemoteActiveSession = true

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]
        @FetchOne public var workspaceWithRepository: WorkspaceWithRepository

        public init(workspaceWithRepository: WorkspaceWithRepository) {
            let workspace = workspaceWithRepository.workspace
            self._workspaceWithRepository = FetchOne(
                wrappedValue: workspaceWithRepository,
                WorkspaceWithRepository.all(workspaceID: workspace.id)
            )

            self.chat = nil

            self._archivedSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and($0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )

            let activeSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and(!$0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )

            self._activeSessions = activeSessions

            let session = self.activeSessions.first {
                $0.id == workspace.activeSessionID
            } ?? self.activeSessions.first

            self.chat = session.map(Chat.State.init)
        }

        public var workspace: Workspace {
            workspaceWithRepository.workspace
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
        case chat(Chat.Action)
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsResponse(Result<[Session], any Error>)
        case refresh
        case sessionButtonTapped(Session)
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

            case let .loadSessionsResponse(.success(sessions)):
                state.chat = Self.selectedChat(
                    afterLoading: sessions,
                    currentChat: state.chat,
                    workspaceActiveSessionID: state.workspace.activeSessionID,
                    shouldPreferRemoteActiveSession: state.shouldPreferRemoteActiveSession
                )
                state.shouldPreferRemoteActiveSession = false
                return .none

            case let .loadSessionsResponse(.failure(error)):
                state.destination = .alert(
                    .failedToLoadSessions(message: error.localizedDescription)
                )
                return .none

            case let .chat(.loadMessagesFailed(message)):
                state.destination = .alert(.failedToLoadMessages(message: message))
                return .none

            case .refresh:
                return .run { [workspaceID = state.workspace.id] send in
                    await refreshSessions(workspaceID: workspaceID, send: send)
                }

            case let .sessionButtonTapped(session):
                /// Session button was tapped, don't let a new active session switch it for the lifetime of this
                state.shouldPreferRemoteActiveSession = false
                guard state.chat?.sessionID != session.id else { return .none }
                state.chat = Chat.State(session: session)
                return .none

            case .chat, .destination:
                return .none

            }
        }
        .ifLet(\.chat, action: \.chat) {
            Chat()
        }
        .ifLet(\.$destination, action: \.destination)
    }

    /// Reconciles the selected chat after each session refresh.
    ///
    /// Session polling can remove, archive, or add sessions while this screen is open. The
    /// current chat therefore has to be checked against each response before it is kept.
    private static func selectedChat(
        afterLoading sessions: [Session],
        currentChat: Chat.State?,
        workspaceActiveSessionID: Session.ID?,
        shouldPreferRemoteActiveSession: Bool
    ) -> Chat.State? {
        let activeSessions = sessions.filter { !$0.isHidden } // Archived sessions are displayed separately and cannot remain selected in the chat.
        if !shouldPreferRemoteActiveSession,
           let currentChat,
           activeSessions.contains(where: { $0.id == currentChat.sessionID }) {
            // Preserve a reconciled or explicit selection instead of resetting it on every poll.
            return currentChat
        } else {
            // Prefer Conductor's active session, then fall back to the most recently updated session.
            let session = activeSessions.first { $0.id == workspaceActiveSessionID } /// Get the active session
                ?? activeSessions.max { /// Fallback to the most recently updated session
                    ($0.updatedDate ?? .distantPast) < ($1.updatedDate ?? .distantPast)
                }
            return session.map(Chat.State.init)
        }
    }

    @concurrent private func refreshSessions(workspaceID: String, send: Send<Action>) async {
        do {
            let sessions = try await loadSessions(workspaceID: workspaceID)
            await send(.loadSessionsResponse(.success(sessions)))
        } catch is CancellationError {
            return
        } catch {
            await send(.loadSessionsResponse(.failure(error)))
        }
    }

    @concurrent private func loadSessions(workspaceID: String) async throws -> [Session] {
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

        return sessions
    }
}

extension WorkspaceChat.Destination.State: Equatable { }

extension AlertState where Action == WorkspaceChat.Destination.Alert {
    static func failedToLoadMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to load messages")
        } message: {
            TextState(message)
        }
    }

    static func failedToLoadSessions(message: String) -> Self {
        AlertState {
            TextState("Failed to load sessions")
        } message: {
            TextState(message)
        }
    }
}

public struct WorkspaceChatView: View {
    @Bindable var store: StoreOf<WorkspaceChat>
    @ScaledMetric(relativeTo: .body) private var sessionPickerHeight = 52

    public init(store: StoreOf<WorkspaceChat>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let chatStore = store.scope(state: \.chat, action: \.chat) {
                ChatView(store: chatStore)
                    // Treat each session as distinct content so switching runs the transition.
                    .id(chatStore.sessionID)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .progressViewStyle(.conductor)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        // Animate only the chat replacement when the selected session changes.
        // We animate the *effects* of selections, not the selections themsleves
        .animation(.default, value: store.chat?.sessionID)
        .themedNavigationTitle(
            verbatim: store.workspace.displayBranchName,
            alignment: .leading
        ) {
            Label {
                Text(verbatim: store.workspaceWithRepository.repositoryDisplayName)
                    .lineLimit(1)
            } icon: {
                RepositoryIcon(
                    repository: store.workspaceWithRepository.repository,
                    size: 13,
                    relativeTo: .footnote
                )
            }
            .labelStyle(.conductorExtraSmall)
        }
        .toolbar {
            if !store.archivedSessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.send(.archivedSessionsButtonTapped)
                    } label: {
                        Label {
                            Text("Archived sessions")
                        } icon: {
                            LucideIcon(Lucide.history, size: 20, relativeTo: .title)
                        }
                        .foregroundStyle(.theme(.textPrimary))
                    }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top) {
            SessionPicker(
                sessions: store.activeSessions,
                selectedSessionID: store.chat?.sessionID,
                height: sessionPickerHeight
            ) { session in
                store.send(.sessionButtonTapped(session))
            }
            // Update the selected glass tint immediately while the chat transitions above.
            .animation(nil, value: store.chat?.sessionID)
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

    private struct SessionPicker: View {
        let sessions: [Session]
        let selectedSessionID: Session.ID?
        let height: CGFloat
        let action: @MainActor (Session) -> Void

        var body: some View {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(sessions) { session in
                            SessionButton(
                                session: session,
                                isSelected: session.id == selectedSessionID
                            ) {
                                action(session)
                            }
                        }
                    }
                }
                .padding(EdgeInsets(vertical: 8, horizontal: 16))
            }
            .scrollIndicators(.hidden)
            .frame(height: height)
        }
    }

    private struct SessionButton: View {
        let session: Session
        let isSelected: Bool
        let action: @MainActor () -> Void
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var iconSize = ThemeFontStyle.small.size

        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var unreadIndicatorSize = 6 // kinda a magic number just got it by tweaking

        var body: some View {
            Button(action: action) {
                Label {
                    Text(session.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.theme(isSelected ? .textPrimary : .textSecondary))
                } icon: {
                    if session.status == .working {
                        ProgressView()
                            .progressViewStyle(.conductor(phaseSeed: session.id))
                            .tint(.theme(.textSecondary))
                            .frame(width: iconSize, height: iconSize)
                    } else if session.unreadCount > 0 {
                        UnreadIcon(size: unreadIndicatorSize)
                    }
                }
                .labelStyle(.conductorExtraSmall)
                .font(.theme(.small))
                .frame(maxWidth: 120)
                .padding(EdgeInsets(vertical: 4, horizontal: 12))
            }
            .glassEffect(
                .clear
                    .tint(isSelected ? .theme(.highlight) : Color.clear)
                    .interactive()
            )
            .tint(isSelected ? .theme(.highlight) : .clear)
        }
    }
}

#if DEBUG
#Preview("Realistic workspace") {
    let content = try! WorkspaceChatPreviewContent()
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
        try $0.defaultDatabase.write { db in
            try Workspace.upsert { content.workspace }.execute(db)
            try Repository.upsert { content.repository }.execute(db)
            try Session.upsert { content.sessions }.execute(db)
            try Message.upsert { content.messages }.execute(db)
        }
        $0.desktopClient.fetchSessions = { _ in content.sessions }
        $0.desktopClient.fetchMessages = { _, sessionID in
            content.messages.filter { $0.sessionID == sessionID }
        }
    }

    NavigationStack {
        WorkspaceChatView(
            store: Store(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: content.workspaceWithRepository
                )
            ) {
                WorkspaceChat()
            }
        )
    }
    .preferredColorScheme(.dark)
}
#endif
