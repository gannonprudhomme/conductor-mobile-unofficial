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
    public typealias TurnSummaryID = String

    @ObservableState
    public struct State: Equatable {
        @FetchAll var messages: [Message]
        @FetchOne var session: Session

        var messageDraft = ""
        var isMessageSendInFlight = false
        var isStopInFlight = false
        var displayedContentRevision = 0
        var expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []

        /// The turns + parsed rows (e.g. `Message.content` -> `CodexEvent`)
        ///
        /// We store this as this is *really* the source of truth in a sense for the rows we display.
        /// Whereas ``rows`` below may not contain all possible message rows, e.g. rows that are collapsible behind a "turn summary".
        var turns: [Turn]? = nil

        /// The final representation of rows to display.
        ///
        /// This hides or shows rows based on their collapsed status for turned rows
        var rows: [DisplayedChatRow]? = nil

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
                && lhs.isStopInFlight == rhs.isStopInFlight
                && lhs.displayedContentRevision == rhs.displayedContentRevision
                && lhs.expandedSummaryIDs == rhs.expandedSummaryIDs
        }

        /// Read by ``WorkspaceChat`` to track the selected session.
        var sessionID: Session.ID { session.id }
    }

    public enum Action: BindableAction {
        case task
        case loadMessagesFailed(String)
        case messagesUpdated([Message])
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
                if status != .working {
                    state.isStopInFlight = false
                }
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
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    let result = await Result {
                        try await desktopClient.sendMessage(workspaceID, sessionID, message)
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
                        state.messageDraft = ""
                    }

                case .failure:
                    // Send errors are displayed by the parent ``WorkspaceChat``.
                    break
                }
                return .none

            case .stopButtonTapped:
                guard state.session.status == .working, !state.isStopInFlight else {
                    return .none
                }

                state.isStopInFlight = true
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    await send(
                        .stopSessionResponse(
                            sessionID: sessionID,
                            result: await Result {
                                try await desktopClient.stopSession(workspaceID, sessionID)
                            }
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
                ChatRows(
                    rows: store.rows ?? [],
                    turnSummaryTapped: {
                        store.send(.turnSummaryTapped($0), animation: .default)
                    }
                )

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
        .defaultScrollAnchor(.bottom)
        .background {
            Color.theme(.background)
                .ignoresSafeArea()
        }
        .safeAreaBar(edge: .bottom) {
            ChatTextField(
                text: $store.messageDraft,
                isSendInFlight: store.isMessageSendInFlight,
                isStopInFlight: store.isStopInFlight,
                isWorking: store.session.status == .working,
                onSendTapped: { store.send(.sendButtonTapped) },
                onStopTapped: { store.send(.stopButtonTapped) }
            )
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
            
            Task { // TODO: Not convinced this helps but it doesn't hurt
                await Task.yield()
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
        let turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void

        var body: some View {
            ForEach(rows) { row in
                ChatRowView(
                    row: row,
                    turnSummaryTapped: turnSummaryTapped
                )
                    .padding(.horizontal, ChatRowLayout.horizontalPadding)
                    .padding(.top, ChatRowLayout.rowTopPadding)
            }
        }
    }

    private struct ChatRowView: View {
        let row: DisplayedChatRow
        let turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void

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
            case .turnSummary(let summary):
                TurnSummaryRowView(summary: summary) {
                    turnSummaryTapped(summary.id)
                }
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
