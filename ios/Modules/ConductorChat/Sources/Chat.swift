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
import LucideIcons
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
        var rows: [Turn.Row]? = nil
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
                    },
                animation: .default
            )
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
                let pollMessages: Effect<Action> = .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
                    await refreshMessages(
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        send: send
                    )
                    for await _ in clock.timer(interval: .seconds(1)) {
                        await refreshMessages(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            send: send
                        )
                    }
                }
                
                return .merge(
                    pollMessages,
                    .publisher {
                        state.$messages
                            .publisher
                            .removeDuplicates()
                            .map(Action.messagesUpdated)
                    }
                )

            case .messagesUpdated(let messages):
                state.turns = Turn.parse(messages: messages)
                state.updateRows(sessionStatus: state.session.status)
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

    @concurrent private func refreshMessages(
        workspaceID: String,
        sessionID: String,
        send: Send<Action>
    ) async {
        do {
            try await loadMessages(
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        } catch is CancellationError {
            return
        } catch {
            Logger.chat.error("Failed to load messages: \(error)")
            await send(.loadMessagesFailed(error.localizedDescription))
        }
    }

    // Do it off the mian thread!
    @concurrent private func loadMessages(workspaceID: String, sessionID: String) async throws {
        let messages = try await desktopClient.fetchMessages(workspaceID, sessionID)
        guard !messages.isEmpty else { return }

        try await database.write { db in
            try Message.upsert { messages }
                .execute(db)
        }
    }
}

struct ChatView: View {
    @Bindable var store: StoreOf<Chat>
    @State private var isBottomMarkerVisible = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    init(store: StoreOf<Chat>) {
        self.store = store
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ChatRows(rows: store.rows ?? [])
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange { isVisible in
                        isBottomMarkerVisible = isVisible
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
        .onChange(of: store.turns) { previousTurns, turns in
            turnsChanged(from: previousTurns, to: turns)
        }
        .onChange(of: store.session.status) { _, status in
            sessionStatusChanged(status)
        }
        .task(id: store.session.id) {
            await store.send(.task).finish()
        }
        .preferredColorScheme(.dark)
    }

    private func turnsChanged(from previousTurns: [Turn]?, to turns: [Turn]?) {
        let isInitialLoad = (previousTurns?.isEmpty ?? true) && turns?.isEmpty == false
        guard isInitialLoad || isBottomMarkerVisible else { return }

        withAnimation {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func sessionStatusChanged(_ status: Session.Status) {
        store.send(.sessionStatusChanged(status))
        guard status == .working, isBottomMarkerVisible else { return }

        withAnimation {
            scrollPosition.scrollTo(edge: .bottom)
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
        let rows: [Turn.Row]

        var body: some View {
            ForEach(rows) { row in
                makeRow(row)
            }
        }
        
        @ViewBuilder
        func makeRow(_ row: Turn.Row) -> some View {
            switch row {
            case .humanMessageRow(let humanMessageRow):
                HumanMessageRowView(row: humanMessageRow)
            case .assistantMessage(let assistantMessage):
                makeAssistantMessage(assistantMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .turnInProgress(let turnInProgress):
                TurnInProgressView(row: turnInProgress)
            }
        }
        
        @ViewBuilder
        private func makeAssistantMessage(_ assistantMessage: Turn.Row.AssistantMessage) -> some View {
            switch assistantMessage {
            case .text(_, let content, let isMostRecentTextInTurn):
                Text(content)
                    .foregroundStyle(.theme(isMostRecentTextInTurn ? .textPrimary : .textSecondary))
            case .toolCall(_, let toolCall):
                ToolCallRowView(toolCall: toolCall)
                    .foregroundStyle(.theme(.textPrimary))
            case .error(_, let message):
                Text("Error: \(message)")
                    .foregroundStyle(.theme(.destructive))
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
