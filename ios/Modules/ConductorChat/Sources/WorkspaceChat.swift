//
//  WorkspaceChat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Combine
import ComposableArchitecture
import SharedConductorData
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import Logging
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
        var hasUserSelectedSession = false
        var isCreatingSession = false
        var isLoadingSessions = true
        var hasPersistedInitialSessionSnapshot = false
        /// Cleared once observation identifies a session created after this snapshot.
        var sessionIDsBeforeCreation: Set<Session.ID>?
        var sessionIDAwaitingObservation: Session.ID?

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]
        @FetchOne public var workspaceWithRepository: WorkspaceWithRepository

        public init(
            workspaceWithRepository: WorkspaceWithRepository,
            selectedModel: Session.Model? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            let workspace = workspaceWithRepository.workspace
            self._workspaceWithRepository = FetchOne(
                wrappedValue: workspaceWithRepository,
                WorkspaceWithRepository.all(workspaceID: workspace.id),
                animation: .default
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
                    .order(by: \.createdAt),
                animation: .default
            )

            self._activeSessions = activeSessions

            let session = self.activeSessions.first {
                $0.id == workspace.activeSessionID
            } ?? self.activeSessions.first

            self.chat = session.map {
                Chat.State(
                    session: $0,
                    selectedModel: selectedModel,
                    shouldFocusMessageField: shouldFocusMessageField
                )
            }
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
        case activeSessionIDChanged(Session.ID?)
        case archiveWorkspaceButtonTapped
        case archiveWorkspaceResponse(Result<Void, any Error>)
        case archivedSessionsButtonTapped
        case chat(Chat.Action)
        case createSessionButtonTapped
        case createSessionResponse(Result<Session, any Error>)
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsResponse(Result<[Session], any Error>)
        case sessionSnapshotPersisted
        case sessionButtonTapped(Session)
        case task

        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case workspaceArchived
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let workspace = state.$workspaceWithRepository
                // The workspace and sessions arrive through independent sockets. Reconcile when
                // either one changes so an active-session-only update cannot leave chat stale.
                return .merge(
                    .publisher {
                        workspace.publisher
                            .map(\.workspace.activeSessionID)
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.activeSessionIDChanged)
                    },
                    observeSessions(workspaceID: state.workspace.id)
                )

            case let .activeSessionIDChanged(activeSessionID):
                // The workspace and session snapshots are persisted independently. Do not let a
                // workspace update clear or replace the chat while SQLite is still catching up.
                guard !state.hasUserSelectedSession,
                      let activeSessionID,
                      let activeSession = state.activeSessions.first(where: {
                          $0.id == activeSessionID
                      }),
                      state.chat?.sessionID != activeSessionID else {
                    return .none
                }
                state.chat = Chat.State(session: activeSession)
                return .none

            case .archiveWorkspaceButtonTapped:
                return .run { [workspaceID = state.workspace.id] send in
                    await send(
                        .archiveWorkspaceResponse(
                            Result {
                                try await desktopClient.archiveWorkspace(workspaceID: workspaceID)
                            }
                        )
                    )
                }

            case .archiveWorkspaceResponse(.success):
                return .send(.delegate(.workspaceArchived))

            case let .archiveWorkspaceResponse(.failure(error)):
                Logger.chat.error("Failed to archive workspace: \(error)")
                state.destination = .alert(
                    .failedToArchiveWorkspace(message: error.localizedDescription)
                )
                return .none

            case .archivedSessionsButtonTapped:
                state.destination = .archivedSessions(
                    ArchivedSessions.State(
                        workspaceID: state.workspace.id,
                        sessions: state.archivedSessions
                    )
                )
                return .none

            case .createSessionButtonTapped:
                guard state.activeSessions.count < 5 else {
                    state.destination = .alert(.maximumTabsReached)
                    return .none
                }
                guard !state.isCreatingSession else {
                    return .none
                }

                state.isCreatingSession = true
                state.sessionIDsBeforeCreation = Set(state.activeSessions.map(\.id))
                return .run { [workspaceID = state.workspace.id] send in
                    await send(
                        .createSessionResponse(
                            Result {
                                try await desktopClient.createSession(workspaceID: workspaceID)
                            }
                        )
                    )
                }

            case let .createSessionResponse(.success(session)):
                let hasObservedSession = state.sessionIDsBeforeCreation == nil
                state.hasUserSelectedSession = true
                state.isCreatingSession = false
                state.sessionIDAwaitingObservation = hasObservedSession ? nil : session.id
                state.sessionIDsBeforeCreation = nil
                if state.chat?.sessionID != session.id {
                    state.chat = Chat.State(
                        session: session,
                        shouldFocusMessageField: true
                    )
                }
                return .none

            case let .createSessionResponse(.failure(error)):
                Logger.chat.error("Failed to create session: \(error)")
                state.isCreatingSession = false
                state.sessionIDsBeforeCreation = nil
                state.destination = .alert(
                    .failedToCreateSession(message: error.localizedDescription)
                )
                return .none

            case let .loadSessionsResponse(.success(sessions)):
                if let sessionIDsBeforeCreation = state.sessionIDsBeforeCreation,
                   let createdSession = sessions.last(where: {
                       !sessionIDsBeforeCreation.contains($0.id) && !$0.isHidden
                   }) {
                    state.hasUserSelectedSession = true
                    state.sessionIDsBeforeCreation = nil
                    state.chat = Chat.State(
                        session: createdSession,
                        shouldFocusMessageField: true
                    )
                }
                if sessions.contains(where: { $0.id == state.sessionIDAwaitingObservation }) {
                    state.sessionIDAwaitingObservation = nil
                }
                state.chat = Self.selectedChat(
                    afterReceiving: sessions,
                    currentChat: state.chat,
                    workspaceActiveSessionID: state.workspace.activeSessionID,
                    hasUserSelectedSession: state.hasUserSelectedSession,
                    sessionIDAwaitingObservation: state.sessionIDAwaitingObservation
                )
                state.isLoadingSessions = false
                return .none

            case let .loadSessionsResponse(.failure(error)):
                Logger.chat.error("Failed to load sessions: \(error)")
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadSessions(message: error.localizedDescription)
                )
                return .none

            case .sessionSnapshotPersisted:
                state.hasPersistedInitialSessionSnapshot = true
                return .none

            case let .chat(.initialMessagesResponse(sessionID, _)):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                return markWorkspaceReadIfNeeded(
                    state,
                    selectedSession: state.chat?.session
                )

            case let .chat(.loadMessagesFailed(error)):
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadMessages(message: error.localizedDescription)
                )
                return .none

            case let .chat(.sendMessageResponse(sessionID, .failure(error))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to send message: \(error)")
                state.destination = .alert(
                    .failedToSendMessage(message: error.localizedDescription)
                )
                return .none

            case let .chat(.stopSessionResponse(sessionID, .failure(error))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                // Observation can receive the canonical stopped session before a delayed
                // POST failure, so do not report a stop failure once it is no longer working.
                guard state.chat?.session.status == .working else {
                    return .none
                }

                Logger.chat.error("Failed to stop session: \(error)")
                state.destination = .alert(
                    .failedToStopSession(message: error.localizedDescription)
                )
                return .none

            case let .sessionButtonTapped(session):
                /// Session button was tapped, don't let a new active session switch it for the lifetime of this
                state.hasUserSelectedSession = true
                state.sessionIDAwaitingObservation = nil
                guard state.chat?.sessionID != session.id else {
                    return .none
                }
                state.chat = Chat.State(session: session)
                return .none

            case .chat, .delegate, .destination:
                return .none

            }
        }
        .ifLet(\.chat, action: \.chat) {
            Chat()
        }
        .ifLet(\.$destination, action: \.destination)
    }

    /// Reconciles the selected chat after session or workspace updates.
    ///
    /// Sessions can be removed, archived, or added while the workspace's active session can
    /// change independently. The current chat therefore has to be checked after either update.
    private static func selectedChat(
        afterReceiving sessions: [Session],
        currentChat: Chat.State?,
        workspaceActiveSessionID: Session.ID?,
        hasUserSelectedSession: Bool,
        sessionIDAwaitingObservation: Session.ID?
    ) -> Chat.State? {
        let activeSessions = sessions.filter { !$0.isHidden } // Archived sessions are displayed separately and cannot remain selected in the chat.
        if let sessionIDAwaitingObservation,
           currentChat?.sessionID == sessionIDAwaitingObservation {
            return currentChat
        } else if hasUserSelectedSession,
           let currentChat,
            activeSessions.contains(where: { $0.id == currentChat.sessionID }) {
            // Preserve a reconciled or explicit selection instead of resetting it on every snapshot.
            return currentChat
        } else {
            // Prefer Conductor's active session, then fall back to the most recently updated session.
            let session = activeSessions.first { $0.id == workspaceActiveSessionID } /// Get the active session
                ?? activeSessions.max { /// Fallback to the most recently updated session
                    ($0.updatedDate ?? .distantPast) < ($1.updatedDate ?? .distantPast)
                }
            // Avoid rebuilding the current chat when the selected session has not changed.
            let canReuseCurrentChat = session?.id == currentChat?.sessionID
            guard !canReuseCurrentChat else {
                return currentChat
            }
            return session.map { Chat.State(session: $0) }
        }
    }

    private func observeSessions(workspaceID: String) -> Effect<Action> {
        .run { send in
            await WebSocketHelpers.observe {
                desktopClient.observeSessions(workspaceID: workspaceID)
            } onValue: { sessions in
                await send(.loadSessionsResponse(.success(sessions)))

                try await database.write { db in
                    try Session
                        .where { $0.workspaceID.eq(workspaceID) }
                        .delete()
                        .execute(db)

                    try Session.upsert { sessions }
                        .execute(db)
                }
                await send(.sessionSnapshotPersisted)
            } onFailure: { error in
                await send(.loadSessionsResponse(.failure(error)))
            }
        }
    }

    private func markWorkspaceReadIfNeeded(
        _ state: State,
        selectedSession: Session?
    ) -> Effect<Action> {
        guard (state.workspace.unread ?? 0) > 0
              || (selectedSession?.unreadCount ?? 0) > 0 else {
            return .none
        }

        return .run { [workspaceID = state.workspace.id] _ in
            do {
                _ = try await desktopClient.setWorkspaceUnread(
                    workspaceID: workspaceID,
                    isUnread: false
                )
            } catch {
                Logger.chat.error("Failed to mark workspace as read: \(error)")
                return
            }

            do {
                try await database.write { db in
                    try Workspace
                        .find(workspaceID)
                        .update { $0.unread = #bind(0) }
                        .execute(db)
                    try Session
                        .where {
                            $0.workspaceID.eq(workspaceID)
                                && !$0.isHidden
                                && $0.unreadCount.gt(0)
                        }
                        .update { $0.unreadCount = 0 }
                        .execute(db)
                }
            } catch {
                Logger.chat.error("Failed to update cached unread state: \(error)")
            }
        }
    }
}

extension WorkspaceChat.Destination.State: Equatable { }

extension AlertState where Action == WorkspaceChat.Destination.Alert {
    static var maximumTabsReached: Self {
        AlertState {
            TextState("Maximum of 5 tabs allowed")
        }
    }

    static func failedToLoadMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to load messages")
        } message: {
            TextState(message)
        }
    }

    static func failedToArchiveWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to archive workspace")
        } message: {
            TextState(message)
        }
    }

    static func failedToCreateSession(message: String) -> Self {
        AlertState {
            TextState("Failed to create session")
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

    static func failedToSendMessage(message: String) -> Self {
        AlertState {
            TextState("Failed to send message")
        } message: {
            TextState(message)
        }
    }

    static func failedToStopSession(message: String) -> Self {
        AlertState {
            TextState("Failed to stop agent")
        } message: {
            TextState(message)
        }
    }
}

public struct WorkspaceChatView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var store: StoreOf<WorkspaceChat>
    @ScaledMetric(relativeTo: .body) private var sessionPickerHeight = 52

    public init(store: StoreOf<WorkspaceChat>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let chatStore = store.scope(state: \.chat, action: \.chat) {
                ChatView(
                    store: chatStore,
                    directoryName: store.workspace.emptyChatDirectoryName
                )
                    // Treat each session as distinct content so view-local scroll state resets.
                    .id(chatStore.sessionID)
            } else {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .themedNavigationTitle(
            verbatim: store.workspace.displayName,
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
                .foregroundStyle(.theme(.textSecondary))
            }
            .labelStyle(.conductorExtraSmall)
        }
        .toolbar {
            toolbarMenu
        }
        .safeAreaBar(edge: .top) {
            SessionPicker(
                sessions: store.activeSessions,
                selectedSessionID: store.chat?.sessionID,
                isCreatingSession: store.isCreatingSession,
                animatesSessionChanges: store.hasPersistedInitialSessionSnapshot,
                height: sessionPickerHeight
            ) { session in
                store.send(.sessionButtonTapped(session))
            } createSession: {
                store.send(.createSessionButtonTapped)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if store.isLoadingSessions {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(.theme(.background))
            }
        }
        .background(.theme(.background))
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .sensoryFeedback(.error, trigger: store.destination) { _, destination in
            destination?.alert != nil
        }
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

    private var toolbarMenu: some View {
        Menu {
            if !store.isLoadingSessions, !store.archivedSessions.isEmpty {
                Button {
                    store.send(.archivedSessionsButtonTapped)
                } label: {
                    Label {
                        Text("Archived sessions")
                    } icon: {
                        ColoredMenuImage(Lucide.history, color: .theme(.textPrimary))
                    }
                }
            }

            if let pullRequestURL = store.workspaceWithRepository.pullRequestURL {
                Button {
                    openURL(pullRequestURL)
                } label: {
                    Label {
                        Text("Open PR in GitHub")
                    } icon: {
                        ScaledImage.gitHub(size: 16, relativeTo: .body)
                    }
                }
                .accessibilityLabel("Pull request")
            }

            Section {
                Button(role: .destructive) {
                    store.send(.archiveWorkspaceButtonTapped)
                } label: {
                    Label {
                        Text("Archive")
                    } icon: {
                        ColoredMenuImage(
                            Lucide.archive,
                            color: .theme(.destructive)
                        )
                    }
                }
            }
        } label: {
            Label {
                Text("More")
            } icon: {
                LucideIcon(Lucide.ellipsis, size: 20, relativeTo: .body)
                    .foregroundStyle(.theme(.textPrimary))
            }
            .labelStyle(.iconOnly)
        }
    }

    private struct SessionPicker: View {
        let sessions: [Session]
        let selectedSessionID: Session.ID?
        let isCreatingSession: Bool
        let animatesSessionChanges: Bool
        let height: CGFloat
        let action: @MainActor (Session) -> Void
        let createSession: @MainActor () -> Void
        @State private var scrollPosition = ScrollPosition(idType: Session.ID.self)

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
                            // This padding originally lived on the GlassEffectContainer, but
                            // applying it directly to the edge buttons keeps them from touching
                            // the screen edge when ScrollPosition scrolls to them.
                            .padding(.leading, session.id == sessions.first?.id ? 16 : 0)
                        }

                        NewSessionButton(
                            isCreatingSession: isCreatingSession,
                            action: createSession
                        )
                        .padding(.leading, sessions.isEmpty ? 16 : 0)
                        .padding(.trailing, 16)
                    }
                    .scrollTargetLayout()
                    .animation(
                        animatesSessionChanges ? .default : nil,
                        value: sessions.map(\.id)
                    )
                }
                .padding(.vertical, 8)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("workspace-chat.session-picker")
            .frame(height: height)
            // Run initially for the cached active session, then follow active or user selections.
            .onChange(of: selectedSessionID, initial: true) { _, sessionID in
                selectedSessionChanged(sessionID)
            }
            .onChange(of: sessions.map(\.id)) {
                selectedSessionChanged(selectedSessionID)
            }
        }

        private func selectedSessionChanged(_ sessionID: Session.ID?) {
            guard let sessionID else {
                return
            }

            if animatesSessionChanges {
                withAnimation {
                    scrollPosition.scrollTo(id: sessionID, anchor: .center)
                }
            } else {
                scrollPosition.scrollTo(id: sessionID, anchor: .center)
            }
        }
    }

    private struct NewSessionButton: View {
        let isCreatingSession: Bool
        let action: @MainActor () -> Void
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var iconSize = ThemeFontStyle.small.size
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var buttonSize = ThemeFontStyle.small.size + 12

        var body: some View {
            Button(action: action) {
                Group {
                    if isCreatingSession {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.textSecondary))
                            .controlSize(.mini)
                    } else {
                        LucideIcon(Lucide.plus, size: iconSize, relativeTo: .footnote)
                            .foregroundStyle(.theme(.textSecondary))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .frame(width: buttonSize, height: buttonSize)
            }
            .glassEffect(.clear.interactive(), in: .circle)
            .disabled(isCreatingSession)
            .accessibilityLabel("New session")
            .accessibilityIdentifier("workspace-chat.new-session")
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
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            try MobileWorkspaceState.upsert { content.mobileState }.execute(db)
            try Session.upsert { content.sessions }.execute(db)
            try Message.upsert { content.messages }.execute(db)
        }
        $0.desktopClient.observeSessions = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(content.sessions)
            }
        }
        $0.desktopClient.observeMessages = { _, sessionID in
            AsyncThrowingStream { continuation in
                continuation.yield(
                    content.messages.filter { $0.sessionID == sessionID }
                )
            }
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // mimic a back button
                Button {
                } label: {
                    Image(systemName: "chevron.left")
                        .imageScale(.medium)
                        .foregroundStyle(.theme(.textPrimary))
                }
            }
        }
    }
    .preferredColorScheme(.dark)
}
#endif
