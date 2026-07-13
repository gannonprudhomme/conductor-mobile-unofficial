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
import SQLiteData
import SwiftUI

/// Note: this is always embedded in ``WorkspaceChat``, never solo
/// i.e. this doesn't own its nav bar
@Reducer
public struct Chat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @FetchAll var messages: [Message]
        @FetchOne var session: Session
        var messageDraft = ""
        var isMessageSendInFlight = false
        var displayedContentRevision = 0
        var rows: [DisplayedChatRow]? = nil
        var turns: [Turn]? = nil

        mutating func updateRows(sessionStatus: Session.Status) {
            guard let turns else {
                rows = nil
                return
            }

            rows = turns.flattenedChatRows(
                activeTurnID: sessionStatus == .working ? turns.last?.id : nil
            )
        }

        init(session: Session) {
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = FetchAll(
                wrappedValue: [],
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

        /// `turns` and `rows` are derived presentation caches. `session` captures status-driven
        /// changes, while the revision records when message-driven rebuilding of both completes.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.messages == rhs.messages
                && lhs.session == rhs.session
                && lhs.messageDraft == rhs.messageDraft
                && lhs.isMessageSendInFlight == rhs.isMessageSendInFlight
                && lhs.displayedContentRevision == rhs.displayedContentRevision
        }

        /// Read by ``WorkspaceChat`` for the animation/identity of this reducer + view
        var sessionID: Session.ID { session.id }
    }

    public enum Action: BindableAction {
        case task
        case loadMessagesFailed(String)
        case messagesUpdated([Message])
        case sendButtonTapped
        case sendMessageResponse(Result<String, any Error>)
        case sessionStatusChanged(Session.Status)
        case binding(BindingAction<State>)
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    pollMessages(state),
                    .publisher {
                        state.$messages
                            .publisher
                            .removeDuplicates()
                            .map(Action.messagesUpdated)
                    }
                )

            case .messagesUpdated(let messages):
                state.turns = Turn.parse(
                    messages: messages,
                    reusing: state.turns ?? []
                )
                state.updateRows(sessionStatus: state.session.status)
                state.displayedContentRevision += 1
                return .none

            case .sessionStatusChanged(let status):
                state.updateRows(sessionStatus: status)
                return .none

            case .sendButtonTapped:
                let message = state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, !state.isMessageSendInFlight else {
                    return .none
                }

                state.isMessageSendInFlight = true
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    let result = await Result {
                        try await desktopClient.sendMessage(workspaceID, sessionID, message)
                        return message
                    }

                    await send(.sendMessageResponse(result))
                }

            case let .sendMessageResponse(result):
                state.isMessageSendInFlight = false
                switch result {
                case let .success(message):
                    if state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines) == message {
                        state.messageDraft = ""
                    }

                case .failure:
                    // Send errors are displayed by the parent ``WorkspaceChat``.
                    break
                }
                return .none

            case .binding, .loadMessagesFailed:
                return .none
            }
        }
    }

    private func pollMessages(_ state: State) -> Effect<Action> {
        .run {
            [
                previousMessages = Set(state.messages),
                sessionID = state.session.id,
                workspaceID = state.session.workspaceID,
            ] send in
            var previousMessages = previousMessages
            guard let messages = await refreshMessages(
                workspaceID: workspaceID,
                sessionID: sessionID,
                previousMessages: previousMessages,
                send: send
            ) else {
                return
            }
            previousMessages = messages

            for await _ in clock.timer(interval: .seconds(1)) {
                guard let messages = await refreshMessages(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    previousMessages: previousMessages,
                    send: send
                ) else {
                    return
                }
                previousMessages = messages
            }
        }
    }

    @concurrent private func refreshMessages(
        workspaceID: String,
        sessionID: String,
        previousMessages: Set<Message>,
        send: Send<Action>
    ) async -> Set<Message>? {
        do {
            return try await loadMessages(
                workspaceID: workspaceID,
                sessionID: sessionID,
                previousMessages: previousMessages
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else {
                return nil
            }
            Logger.chat.error("Failed to load messages: \(error)")
            await send(.loadMessagesFailed(error.localizedDescription))
            // Preserve the last successful snapshot after a recoverable failure so the polling
            // loop can retry in one second without treating every existing message as new.
            return previousMessages
        }
    }

    @concurrent private func loadMessages(
        workspaceID: String,
        sessionID: String,
        previousMessages: Set<Message>
    ) async throws -> Set<Message> {
        let messages = try await desktopClient.fetchMessages(workspaceID, sessionID)
        guard !messages.isEmpty else {
            return previousMessages
        }

        let newMessages = Set(messages)
        guard newMessages != previousMessages else {
            return previousMessages
        }

        try await database.write { db in
            try Message.upsert { messages }
                .execute(db)
        }
        return newMessages
    }
}

struct ChatView: View {
    @Bindable var store: StoreOf<Chat>
    @State private var scrollState = ScrollState()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    init(store: StoreOf<Chat>) {
        self.store = store
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: ChatRowLayout.stackSpacing) {
                ChatRows(rows: store.rows ?? [])

                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange { isVisible in
                        guard scrollState.isBottomMarkerVisible != isVisible else {
                            return
                        }

                        scrollState.isBottomMarkerVisible = isVisible
                    }
            }
            .scrollTargetLayout()
        }
        .overlay {
            if store.turns == nil {
                ProgressView()
                    .progressViewStyle(.conductor)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .background {
            Color.theme(.background)
                .ignoresSafeArea()
        }
        .safeAreaBar(edge: .bottom) {
            ChatTextField(
                text: $store.messageDraft,
                isSendInFlight: store.isMessageSendInFlight
            ) {
                store.send(.sendButtonTapped)
            }
        }
        .onChange(of: store.displayedContentRevision) {
            displayedContentRevisionChanged()
        }
        .onChange(of: store.session.status) { _, status in
            sessionStatusChanged(status)
        }
        .task(id: store.session.id) {
            await store.send(.task).finish()
        }
        .preferredColorScheme(.dark)
    }

    private func displayedContentRevisionChanged() {
        switch scrollState.displayedContentChanged(hasRows: store.rows?.isEmpty == false) {
        case .initial:
            withAnimation(nil) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        case .subsequent:
            withAnimation(.default) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        case .none:
            return
        }
    }

    private func sessionStatusChanged(_ status: Session.Status) {
        store.send(.sessionStatusChanged(status))
        guard status == .working, scrollState.isBottomMarkerVisible else {
            return
        }

        withAnimation {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    @MainActor
    final class ScrollState {
        var hasDisplayedContent = false
        var isBottomMarkerVisible = true

        enum DisplayedContentScroll: Equatable {
            case none
            case initial
            case subsequent
        }

        func displayedContentChanged(hasRows: Bool) -> DisplayedContentScroll {
            guard hasRows else {
                return .none
            }

            let isInitialLoad = !hasDisplayedContent
            hasDisplayedContent = true
            guard isInitialLoad || isBottomMarkerVisible else {
                return .none
            }

            return isInitialLoad ? .initial : .subsequent
        }
    }

    private struct EmptyChatView: View {
        var body: some View {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("This session has no messages.")
            )
            .foregroundStyle(.theme(.textPrimary))
            .font(.theme(.body))
        }
    }

    private struct ChatRows: View {
        let rows: [DisplayedChatRow]

        var body: some View {
            ForEach(rows) { row in
                ChatRowView(row: row)
                    .padding(.horizontal, ChatRowLayout.horizontalPadding)
                    .padding(.top, ChatRowLayout.rowTopPadding)
            }
        }
    }

    private struct ChatRowView: View {
        let row: DisplayedChatRow

        var body: some View {
            switch row {
            case .humanMessage(let message):
                HumanMessageRowView(row: message)
            case let .assistantTextChunk(_, chunk, isMostRecentTextInTurn):
                AssistantMessageTextView(
                    chunk: chunk,
                    isMostRecentTextInTurn: isMostRecentTextInTurn
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .assistantToolCall(_, let toolCall):
                ToolCallRowView(toolCall: toolCall)
                    .foregroundStyle(.theme(.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .assistantError(_, let message):
                Text("Error: \(message)")
                    .foregroundStyle(.theme(.destructive))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .turnInProgress(let row):
                TurnInProgressView(row: row)
            }
        }
    }
}

#if DEBUG
#Preview {
    let content = try! ChatPreviewContent()
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
        try $0.defaultDatabase.write { db in
            try Message.upsert { content.messages }
                .execute(db)
        }
        $0.desktopClient.fetchMessages = { _, _ in [] }
    }
    NavigationStack {
        ChatView(
            store: Store(initialState: Chat.State(session: content.session)) {
                Chat()
            }
        )
    }
    .preferredColorScheme(.dark)
}
#endif
