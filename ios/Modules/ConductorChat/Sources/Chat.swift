//
//  Chat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Combine
import ComposableArchitecture
import SharedConductorData
import ConductorDesign
import ConductorMobileData
import Foundation
import Logging
import Sharing
import SQLiteData
import SwiftUI

/// Note: this is always embedded in ``WorkspaceChat``, never solo
/// i.e. this doesn't own its nav bar
@Reducer
public struct Chat: Sendable {
    public typealias TurnSummaryID = String

    @ObservableState
    public struct State: Equatable {
        @Shared(.desktopConnectionStatus)
        var connectionStatus

        @Shared var messageDraft: String

        @FetchAll var messages: [Message]
        @FetchOne var session: Session

        var isLoadingMessages = true
        var isMessageSnapshotEmpty = false
        var isMessageSendInFlight = false
        var isStopInFlight = false
        var scrollToBottomRequest = 0

        /// POST-confirmed message rows retained so a slower first WebSocket snapshot cannot hide them.
        var confirmedMessagesAwaitingInitialSnapshot: [Message] = []
        var expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []

        /// The turns + parsed rows (e.g. `Message.content` -> `AgentEvent`)
        ///
        /// We store this as this is *really* the source of truth in a sense for the rows we display.
        /// Whereas ``rows`` below may not contain all possible message rows, e.g. rows that are collapsible behind a "turn summary".
        var turns: [Turn]? = nil

        /// The final representation of rows to display.
        ///
        /// This hides or shows rows based on their collapsed status for turned rows
        var rows: [DisplayedChatRowWithPadding]? = nil

        var shouldShowEmptyChat: Bool {
            !isLoadingMessages && isMessageSnapshotEmpty
        }

        mutating func updateRows(sessionStatus: Session.Status) {
            guard let turns else {
                rows = nil
                return
            }

            rows = turns.flattenedChatRows(
                activeTurnID: sessionStatus == .working ? turns.last?.id : nil,
                expandedSummaryIDs: expandedSummaryIDs
            )
        }

        init(session: Session, messages: [Message] = []) {
            @Shared(.messageDrafts) var messageDrafts
            self._messageDraft = $messageDrafts[draftFor: session.id]
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = FetchAll(
                wrappedValue: messages,
                Message
                    .where { $0.sessionID.eq(session.id) }
                    .order {
                        (
                            $0.sentAt.asc(nulls: .last),
                            $0.createdAt,
                            $0.id // IDs provide stable ordering when Conductor gives multiple messages identical timestamps.
                        )
                    }
            )
        }

        /// `turns` and `rows` are derived presentation caches, while `session` captures
        /// status-driven changes.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.messages == rhs.messages
                && lhs.session == rhs.session
                && lhs.connectionStatus == rhs.connectionStatus
                && lhs.messageDraft == rhs.messageDraft
                && lhs.isLoadingMessages == rhs.isLoadingMessages
                && lhs.isMessageSnapshotEmpty == rhs.isMessageSnapshotEmpty
                && lhs.isMessageSendInFlight == rhs.isMessageSendInFlight
                && lhs.isStopInFlight == rhs.isStopInFlight
                && lhs.scrollToBottomRequest == rhs.scrollToBottomRequest
                && lhs.confirmedMessagesAwaitingInitialSnapshot
                    == rhs.confirmedMessagesAwaitingInitialSnapshot
                && lhs.expandedSummaryIDs == rhs.expandedSummaryIDs
        }

        /// Read by ``WorkspaceChat`` to track the selected session.
        var sessionID: Session.ID { session.id }
    }

    public enum Action {
        case task
        case initialMessagesResponse([Message])
        case loadMessagesFailed(any Error)
        case messagesUpdated([Message])
        /// Sent after POST returns its persisted row, before writing it locally. The message
        /// appears when that write is observed; this buffers it against an older first snapshot.
        case messageConfirmed(
            sessionID: Session.ID,
            message: Message
        )
        case sendButtonTapped
        case sendMessageResponse(
            sessionID: Session.ID,
            result: Result<String, any Error>
        )
        case sessionStatusChanged(Session.Status)
        case stopButtonTapped
        case stopSessionResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case turnSummaryTapped(Chat.TurnSummaryID)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    observeMessages(state),
                    .publisher {
                        state.$messages
                            .publisher
                            .removeDuplicates()
                            .map(Action.messagesUpdated)
                    }
                )

            case .messagesUpdated(let messages):
                state.isMessageSnapshotEmpty = messages.isEmpty
                state.turns = Turn.parse(
                    messages: messages,
                    reusing: state.turns ?? []
                )
                state.updateRows(sessionStatus: state.session.status)
                return .none

            case let .initialMessagesResponse(messages):
                // A completed send can race with an older first WebSocket snapshot. Prefer the
                // snapshot's copy when IDs overlap, and append only confirmed rows it omitted.
                let responseMessageIDs = Set(messages.map(\.id))
                let confirmedMessagesMissingFromSnapshot = state
                    .confirmedMessagesAwaitingInitialSnapshot
                    .filter { !responseMessageIDs.contains($0.id) }
                // After the first snapshot, database observation owns subsequent updates.
                state.confirmedMessagesAwaitingInitialSnapshot.removeAll()
                state.isMessageSnapshotEmpty = messages.isEmpty
                    && confirmedMessagesMissingFromSnapshot.isEmpty
                state.turns = Turn.parse(
                    messages: messages + confirmedMessagesMissingFromSnapshot,
                    reusing: state.turns ?? []
                )
                state.updateRows(sessionStatus: state.session.status)
                state.isLoadingMessages = false
                return .none

            case let .messageConfirmed(sessionID, message):
                guard sessionID == state.sessionID, state.isLoadingMessages else {
                    return .none
                }
                state.confirmedMessagesAwaitingInitialSnapshot.append(message)
                return .none

            case .sessionStatusChanged(let status):
                state.updateRows(sessionStatus: status)
                return .none

            case .turnSummaryTapped(let summaryID):
                if state.expandedSummaryIDs.remove(summaryID) == nil {
                    state.expandedSummaryIDs.insert(summaryID)
                }
                state.updateRows(sessionStatus: state.session.status)
                return .none

            case .sendButtonTapped:
                let message = state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, !state.isMessageSendInFlight else {
                    return .none
                }

                state.isMessageSendInFlight = true
                state.scrollToBottomRequest &+= 1
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    let result = await Result {
                        if let canonicalMessage = try await desktopClient.sendMessage(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            message: message
                        ) {
                            await send(
                                .messageConfirmed(
                                    sessionID: sessionID,
                                    message: canonicalMessage
                                )
                            )
                            do {
                                try await reconcileMessage(canonicalMessage)
                            } catch {
                                Logger.chat.error("Failed to reconcile sent message: \(error)")
                            }
                        }
                        return message
                    }

                    await send(
                        .sendMessageResponse(
                            sessionID: sessionID,
                            result: result
                        )
                    )
                }

            case let .sendMessageResponse(sessionID, result):
                // Send requests intentionally survive session navigation, so a late response
                // must not mutate the chat that replaced the request's originating session.
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isMessageSendInFlight = false
                switch result {
                case let .success(message):
                    if state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines) == message {
                        state.$messageDraft.withLock { $0 = "" }
                    }
                    return .none

                case .failure:
                    // Send errors are displayed by the parent ``WorkspaceChat``.
                    return .none
                }

            case .stopButtonTapped:
                guard state.session.status == .working, !state.isStopInFlight else {
                    return .none
                }

                state.isStopInFlight = true
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    let result = await Result {
                        if let canonicalSession = try await desktopClient.stopSession(
                            workspaceID: workspaceID,
                            sessionID: sessionID
                        ) {
                            do {
                                try await reconcileSession(canonicalSession)
                            } catch {
                                Logger.chat.error("Failed to reconcile stopped session: \(error)")
                            }
                        }
                    }

                    await send(
                        .stopSessionResponse(
                            sessionID: sessionID,
                            result: result
                        )
                    )
                }

            case let .stopSessionResponse(sessionID, _):
                // Like sends, stop requests intentionally survive session navigation, so ignore
                // responses for a session that has since been replaced.
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isStopInFlight = false
                return .none

            case .loadMessagesFailed:
                return .none
            }
        }
    }

    private func observeMessages(_ state: State) -> Effect<Action> {
        .run {
            [
                initiallyIsLoadingMessages = state.isLoadingMessages,
                sessionID = state.session.id,
                workspaceID = state.session.workspaceID,
            ] send in
            var isAwaitingInitialResponse = initiallyIsLoadingMessages
            await WebSocketHelpers.observe {
                desktopClient.observeMessages(
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
            } onValue: { messages in
                if isAwaitingInitialResponse {
                    isAwaitingInitialResponse = false
                    await send(.initialMessagesResponse(messages))
                }
                try await storeMessages(messages)
            } onFailure: { error in
                Logger.chat.error("Failed to load messages: \(error)")
                await send(.loadMessagesFailed(error))
            }
        }
    }

    private func reconcileMessage(_ message: Message) async throws {
        try await database.write { database in
            guard try Message.find(message.id).fetchOne(database) == nil else {
                return
            }
            try Message.insert { message }.execute(database)
        }
    }

    private func reconcileSession(_ session: Session) async throws {
        try await database.write { database in
            if let existingSession = try Session.find(session.id).fetchOne(database),
               let existingUpdatedDate = existingSession.updatedDate,
               let responseUpdatedDate = session.updatedDate,
               existingUpdatedDate >= responseUpdatedDate {
                // Conductor timestamps have second precision, so an equal row may be a newer
                // same-second state that already arrived through observation.
                return
            }
            try Session.upsert { session }.execute(database)
        }
    }

    @concurrent private func storeMessages(
        _ messages: [Message]
    ) async throws {
        guard !messages.isEmpty else {
            return
        }

        try await database.write { db in
            try Message.upsert { messages }
                .execute(db)
        }
    }
}

private extension Dictionary where Key == Session.ID, Value == String {
    subscript(draftFor sessionID: Session.ID) -> String {
        get { self[sessionID, default: ""] }
        set { self[sessionID] = newValue.isEmpty ? nil : newValue }
    }
}

private extension SharedKey where Self == FileStorageKey<[Session.ID: String]>.Default {
    static var messageDrafts: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "message-drafts.json")
            ),
            default: [:],
        ]
    }
}

struct ChatView: View {
    let store: StoreOf<Chat>
    let directoryName: String

    var body: some View {
        collectionView
            .overlay {
                if store.isLoadingMessages {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textSecondary))
                        .frame(width: 32, height: 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(.theme(.background))
                } else if store.shouldShowEmptyChat {
                    EmptyChatView(directoryName: directoryName)
                }
            }
            .background {
                Color.theme(.background)
                    .ignoresSafeArea()
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    if store.connectionStatus != .connected {
                        Label {
                            Text("Reconnecting")
                        } icon: {
                            ProgressView()
                                .progressViewStyle(.network)
                                .tint(.theme(.textSecondary))
                                .controlSize(.mini)
                        }
                            .labelStyle(.conductorSmall)
                            .font(.theme(.small))
                            .foregroundStyle(.theme(.textSecondary))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    ChatTextField(
                        text: Binding(store.$messageDraft),
                        agentType: store.session.agentType,
                        isSendInFlight: store.isMessageSendInFlight,
                        isStopInFlight: store.isStopInFlight,
                        isWorking: store.session.status == .working,
                        model: store.session.model,
                        onSendTapped: { store.send(.sendButtonTapped) },
                        onStopTapped: { store.send(.stopButtonTapped) }
                    )
                }
                .animation(.default, value: store.connectionStatus)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onChange(of: store.session.status) { _, status in
                store.send(.sessionStatusChanged(status))
            }
            .task(id: store.session.id) {
                await store.send(.task).finish()
            }
            .preferredColorScheme(.dark)
    }

    private var collectionView: some View {
        GeometryReader { proxy in
            ChatCollectionView(
                rows: store.rows ?? [],
                scrollToBottomRequest: store.scrollToBottomRequest,
                safeAreaInsets: proxy.safeAreaInsets,
                turnSummaryTapped: {
                    store.send(.turnSummaryTapped($0), animation: .default)
                }
            )
            // Draw beneath every bar and the keyboard; the proxy insets keep rows unobscured.
            .ignoresSafeArea(edges: [.top, .bottom])
        }
    }

    private struct EmptyChatView: View {
        let directoryName: String

        private var wrappableDirectoryName: String {
            // U+00AD is a soft hyphen: invisible until the text wraps at that character.
            directoryName.map(String.init).joined(separator: "\u{00AD}")
        }

        var body: some View {
            Text(
                "New chat in \(Text(verbatim: "/\(wrappableDirectoryName).").font(.theme(.codeSmall)))"
            )
                .font(.theme(.small))
                .foregroundStyle(.theme(.textSecondary))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#if DEBUG
@MainActor
private struct ChatPreview: View {
    let connectionStatus: Shared<DesktopClient.ConnectionStatus>
    let shouldCycleStatus: Bool
    let store: StoreOf<Chat>

    init(
        status: DesktopClient.ConnectionStatus,
        shouldCycleStatus: Bool = false
    ) {
        let content = try! ChatPreviewContent()
        let _ = try! prepareDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { content.messages }
                    .execute(db)
            }
            $0.desktopClient.observeMessages = { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield([])
                }
            }
        }

        let (connectionStatus, store) = withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = status }
            return (
                $connectionStatus,
                Store(initialState: Chat.State(session: content.session)) {
                    Chat()
                }
            )
        }
        self.connectionStatus = connectionStatus
        self.shouldCycleStatus = shouldCycleStatus
        self.store = store
    }
    var body: some View {
        NavigationStack {
            ChatView(store: store, directoryName: "tacoma-v1")
        }
        .preferredColorScheme(.dark)
        .task {
            await cycleStatus()
        }
    }

    private func cycleStatus() async {
        guard shouldCycleStatus else {
            return
        }

        let statuses = DesktopClient.ConnectionStatus.allPreviewStatuses
        var index = statuses.firstIndex(of: connectionStatus.wrappedValue) ?? 0
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: .seconds(3))
            } catch {
                return
            }

            index = (index + 1) % statuses.count
            connectionStatus.withLock { $0 = statuses[index] }
        }
    }
}

private extension DesktopClient.ConnectionStatus {
    static let allPreviewStatuses: [Self] = [
        .connected,
        .connecting,
        .disconnected,
    ]
}

#Preview("Loop") {
    ChatPreview(status: .connected, shouldCycleStatus: true)
}

#Preview("Online") {
    ChatPreview(status: .connected)
}

#Preview("Connecting") {
    ChatPreview(status: .connecting)
}

#Preview("Offline") {
    ChatPreview(status: .disconnected)
}
#endif
