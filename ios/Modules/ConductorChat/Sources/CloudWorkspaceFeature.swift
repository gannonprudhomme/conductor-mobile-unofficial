//
//  CloudWorkspaceFeature.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/24/26.
//

import ComposableArchitecture
import ConductorCloud
import ConductorDesign
import SharedConductorData
import SwiftUI

@Reducer
public struct CloudWorkspaceFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        public let workspaceID: String
        public var chat: Chat.State?
        public var errorMessage: String?
        public var fallbackTitle: String
        public var hasLoadedInitialSessionSnapshot = false
        public var isCreatingSession = false
        public var isLoading = true
        public var lifecycle: CloudWorkspaceStatusResponse?
        public var selectedSessionID: String?
        public var sessions: [CloudSession] = []
        public var sessionStatuses: [Session.ID: Session.Status] = [:]
        public var workspace: CloudWorkspace?

        public init(
            workspaceID: String,
            fallbackTitle: String,
            initialSessionID: String? = nil,
            initialPrompt: String = ""
        ) {
            self.workspaceID = workspaceID
            self.fallbackTitle = fallbackTitle
            self.selectedSessionID = initialSessionID
            if let initialSessionID {
                self.chat = Chat.State(
                    cloudSession: CloudSession(
                        id: initialSessionID,
                        deepLink: CloudAPIClient.productionBaseURL
                    ),
                    workspaceID: workspaceID,
                    initialPrompt: initialPrompt
                )
            }
        }

        public var title: String {
            workspace?.name ?? fallbackTitle
        }

        var activeSessions: [Session] {
            var activeSessions = sessions
                .filter { $0.archivedAt == nil }
                .map {
                    Session(
                        cloudSession: $0,
                        workspaceID: workspaceID,
                        status: $0.id == chat?.sessionID
                            ? chat?.sessionStatus ?? sessionStatuses[$0.id] ?? .idle
                            : sessionStatuses[$0.id] ?? .idle
                    )
                }
            if let chat,
               !chat.session.isHidden,
               !activeSessions.contains(where: { $0.id == chat.sessionID }) {
                activeSessions.append(chat.session)
            }
            return activeSessions
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let lifecycle: CloudWorkspaceStatusResponse
        public let sessions: [CloudSession]
        public let workspace: CloudWorkspace

        public init(
            lifecycle: CloudWorkspaceStatusResponse,
            sessions: [CloudSession],
            workspace: CloudWorkspace
        ) {
            self.lifecycle = lifecycle
            self.sessions = sessions
            self.workspace = workspace
        }
    }

    public enum Action {
        case alert(PresentationAction<Alert>)
        case chat(Chat.Action)
        case createSessionButtonTapped
        case createSessionResponse(Result<CloudSession, any Error>)
        case refresh
        case response(Result<Snapshot, any Error>)
        case retryButtonTapped
        case sessionButtonTapped(Session.ID)
        case sessionStatusesResponse(
            Result<[Session.ID: Session.Status], any Error>
        )
        case task
        case viewDisappeared

        public enum Alert: Equatable { }
    }

    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.continuousClock) var clock

    public init() { }

    private enum CancelID {
        case sessionStatusPolling
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.errorMessage = nil
                state.isLoading = true
                return load(workspaceID: state.workspaceID)

            case .refresh, .retryButtonTapped:
                guard !state.isLoading else {
                    return .none
                }
                state.errorMessage = nil
                state.isLoading = true
                return load(workspaceID: state.workspaceID)

            case .createSessionButtonTapped:
                guard state.activeSessions.count < 5 else {
                    state.alert = .maximumTabsReached
                    return .none
                }
                guard !state.isCreatingSession else {
                    return .none
                }

                let model = state.chat?.selectedModel ?? .gpt_5_6_sol
                let agent = model.agentType
                    ?? state.chat?.session.agentType
                    ?? .codex
                let request = CloudCreateSessionRequest(
                    workspaceID: state.workspaceID,
                    agent: agent.rawValue,
                    model: model.rawValue,
                    fastMode: state.chat?.isFastModeEnabled
                )
                state.isCreatingSession = true
                return .run { send in
                    await send(
                        .createSessionResponse(
                            await Result {
                                try await cloudAPIClient.createSession(
                                    request: request
                                )
                            }
                        )
                    )
                }

            case let .createSessionResponse(.success(session)):
                state.isCreatingSession = false
                state.sessions.removeAll { $0.id == session.id }
                state.sessions.append(session)
                state.selectedSessionID = session.id
                state.chat = Chat.State(
                    cloudSession: session,
                    workspaceID: state.workspaceID,
                    shouldFocusMessageField: true
                )
                return state.hasLoadedInitialSessionSnapshot
                    ? pollSessionStatuses(sessionIDs: state.activeSessions.map(\.id))
                    : .none

            case let .createSessionResponse(.failure(error)):
                state.isCreatingSession = false
                state.alert = .failedToCreateSession(
                    message: error.localizedDescription
                )
                return .none

            case let .response(result):
                state.isLoading = false
                state.hasLoadedInitialSessionSnapshot = true
                switch result {
                case let .failure(error):
                    state.errorMessage = error.localizedDescription

                case let .success(snapshot):
                    state.lifecycle = snapshot.lifecycle
                    state.sessions = snapshot.sessions
                    state.workspace = snapshot.workspace
                    let visibleSessions = snapshot.sessions.filter {
                        $0.archivedAt == nil
                    }
                    let visibleSessionIDs = Set(visibleSessions.map(\.id))
                    state.sessionStatuses = state.sessionStatuses.filter {
                        visibleSessionIDs.contains($0.key)
                    }
                    let selectedSessionID = state.selectedSessionID.flatMap { selectedID in
                        visibleSessions.contains { $0.id == selectedID }
                            ? selectedID
                            : nil
                    }
                        ?? visibleSessions.first?.id
                        ?? state.chat?.sessionID
                    state.selectedSessionID = selectedSessionID
                    if selectedSessionID != state.chat?.sessionID {
                        state.chat = visibleSessions
                            .first { $0.id == selectedSessionID }
                            .map {
                                Chat.State(
                                    cloudSession: $0,
                                    workspaceID: state.workspaceID
                                )
                            }
                    }
                }
                return pollSessionStatuses(sessionIDs: state.activeSessions.map(\.id))

            case let .sessionButtonTapped(selectedSessionID):
                guard selectedSessionID != state.chat?.sessionID,
                      let selectedSession = state.sessions.first(where: {
                          $0.id == selectedSessionID && $0.archivedAt == nil
                      })
                else {
                    return .none
                }
                state.selectedSessionID = selectedSessionID
                state.chat = Chat.State(
                    cloudSession: selectedSession,
                    workspaceID: state.workspaceID
                )
                return .none

            case let .chat(.loadMessagesFailed(error)):
                state.alert = .failedToLoadCloudMessages(
                    message: error.localizedDescription
                )
                return .none

            case let .chat(.cloudSnapshotResponse(_, .success(snapshot))):
                state.sessionStatuses[snapshot.status.sessionID] = Session.Status(
                    rawValue: snapshot.status.status.rawValue
                )
                return .none

            case let .sessionStatusesResponse(.success(statuses)):
                state.sessionStatuses.merge(statuses) { _, newStatus in
                    newStatus
                }
                return .none

            case .viewDisappeared:
                return .cancel(id: CancelID.sessionStatusPolling)

            case .sessionStatusesResponse(.failure):
                return .none

            case .alert, .chat:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.chat, action: \.chat) {
            Chat()
        }
    }

    private func load(workspaceID: String) -> Effect<Action> {
        .run { send in
            await send(
                .response(
                    await Result {
                        async let workspace = cloudAPIClient.workspace(
                            workspaceID: workspaceID
                        )
                        async let lifecycle = cloudAPIClient.workspaceStatus(
                            workspaceID: workspaceID
                        )
                        async let sessions = cloudAPIClient.allSessions(
                            workspaceID: workspaceID
                        )
                        return try await Snapshot(
                            lifecycle: lifecycle,
                            sessions: sessions,
                            workspace: workspace
                        )
                    }
                )
            )
        }
    }

    private func pollSessionStatuses(
        sessionIDs: [Session.ID]
    ) -> Effect<Action> {
        guard !sessionIDs.isEmpty else {
            return .cancel(id: CancelID.sessionStatusPolling)
        }

        let clock = clock
        let cloudAPIClient = cloudAPIClient
        return .run { send in
            while !Task.isCancelled {
                await send(
                    .sessionStatusesResponse(
                        await Result {
                            try await withThrowingTaskGroup(
                                of: (Session.ID, Session.Status).self
                            ) { group in
                                for sessionID in sessionIDs {
                                    group.addTask {
                                        let response = try await cloudAPIClient.sessionStatus(
                                            sessionID: sessionID
                                        )
                                        return (
                                            sessionID,
                                            Session.Status(rawValue: response.status.rawValue)
                                        )
                                    }
                                }

                                var statuses: [Session.ID: Session.Status] = [:]
                                for try await (sessionID, status) in group {
                                    statuses[sessionID] = status
                                }
                                return statuses
                            }
                        }
                    )
                )
                try await clock.sleep(for: .seconds(5))
            }
        }
        .cancellable(id: CancelID.sessionStatusPolling, cancelInFlight: true)
    }
}

public struct CloudWorkspaceView: View {
    @Bindable private var store: StoreOf<CloudWorkspaceFeature>
    @ScaledMetric(relativeTo: .body) private var sessionPickerHeight = 52

    public init(store: StoreOf<CloudWorkspaceFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let chat = store.scope(state: \.chat, action: \.chat) {
                ChatView(
                    store: chat,
                    directoryName: store.workspace?.name ?? store.fallbackTitle
                )
                .id(chat.sessionID)
            } else if let errorMessage = store.errorMessage {
                ContentUnavailableView {
                    Label("Cloud workspace unavailable", systemImage: "exclamationmark.cloud")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        store.send(.retryButtonTapped)
                    }
                    .buttonStyle(.conductorSecondary)
                }
                .foregroundStyle(.theme(.textPrimary))
            } else {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "text.bubble",
                    description: Text("This cloud workspace does not have a visible session.")
                )
                .foregroundStyle(.theme(.textPrimary))
            }
        }
        .background(.theme(.background))
        .themedNavigationTitle(verbatim: store.title, alignment: .leading) {
            lifecycleLabel
        }
        .safeAreaBar(edge: .top) {
            WorkspaceChatView.SessionPicker(
                sessions: store.activeSessions,
                selectedSessionID: store.chat?.sessionID,
                isCreatingSession: store.isCreatingSession,
                animatesSessionChanges: store.hasLoadedInitialSessionSnapshot,
                height: sessionPickerHeight
            ) { session in
                store.send(.sessionButtonTapped(session.id))
            } createSession: {
                store.send(.createSessionButtonTapped)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if store.isLoading {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(.theme(.background))
            }
        }
        .refreshable {
            await store.send(.refresh).finish()
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .task(id: store.workspaceID) {
            await store.send(.task).finish()
        }
        .onDisappear {
            store.send(.viewDisappeared)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var lifecycleLabel: some View {
        if let lifecycle = store.lifecycle {
            Label {
                Text(lifecycle.status.title)
                    .font(.theme(.small))
                    .foregroundStyle(.theme(.textSecondary))
            } icon: {
                CloudWorkspaceIcon(size: 14)
            }
            .labelStyle(.conductorExtraSmall)
            .accessibilityLabel("Cloud workspace")
            .accessibilityValue(lifecycle.status.title)
        }
    }
}

private extension AlertState where Action == CloudWorkspaceFeature.Action.Alert {
    static var maximumTabsReached: Self {
        AlertState {
            TextState("Maximum of 5 tabs allowed")
        }
    }

    static func failedToCreateSession(message: String) -> Self {
        AlertState {
            TextState("Failed to create session")
        } message: {
            TextState(message)
        }
    }

    static func failedToLoadCloudMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to load messages")
        } message: {
            TextState(message)
        }
    }
}
