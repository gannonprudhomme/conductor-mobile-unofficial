import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import LucideIcons
import SQLiteData
import SwiftUI

@Reducer
public struct Chat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents var destination: Destination.State?
        @FetchAll var messages: [Message]
        public let session: Session
        public var turns: [Turn]? = nil

        public init(session: Session) {
            self.session = session
            self._messages = FetchAll(
                wrappedValue: [],
                Message
                    .where { $0.sessionID.eq(session.id) }
                    .order {
                        (
                            $0.sentAt.asc(nulls: .last),
                            $0.createdAt
                        )
                    },
                animation: .default
            )
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)

        public enum Alert: Equatable { }
    }

    public enum Action {
        case task
        case destination(PresentationAction<Destination.Action>)
        case loadMessagesFailed(String)
        case messagesUpdated([Message])
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
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
                            .map(Action.messagesUpdated)
                    }
                )
                
            case .messagesUpdated(let messages):
                withAnimation {
                    state.turns = Turn.parse(messages: messages)
                }
                return .none

            case let .loadMessagesFailed(message):
                state.destination = .alert(.failedToLoadMessages(message: message))
                return .none

            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
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

extension Chat.Destination.State: Equatable { }

extension AlertState where Action == Chat.Destination.Alert {
    static func failedToLoadMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to load messages")
        } message: {
            TextState(message)
        }
    }
}

public struct ChatView: View {
    @Bindable var store: StoreOf<Chat>
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    public init(store: StoreOf<Chat>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ChatRows(turns: store.turns ?? [])
                    .padding(.horizontal, 16)
            }
            .scrollTargetLayout()
        }
        .overlay {
            if store.turns == nil { // Maybe empty too, idk
                ProgressView()
                    .progressViewStyle(.conductor)
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .background(.theme(.background))
        .themedNavigationTitle(verbatim: store.session.displayTitle)
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .onChange(of: store.messages.last?.id) { _, messageID in
            messagesChanged(messageID: messageID)
        }
        .task {
            await store.send(.task).finish()
        }
        .preferredColorScheme(.dark)
    }

    private func messagesChanged(messageID: Message.ID?) {
        guard let messageID else { return }
        withAnimation {
            scrollPosition.scrollTo(id: messageID, anchor: .bottom)
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
        let turns: [Turn]
        
        var body: some View {
            ForEach(turns) { turn in
                ForEach(turn.rows) { row in
                    makeRow(row)
                }
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
            }
        }
        
        @ViewBuilder
        private func makeAssistantMessage(_ assistantMessage: Turn.Row.AssistantMessage) -> some View {
            switch assistantMessage {
            case .text(_, let content):
                Text(content)
            case .toolCall(_, let toolCall):
                ToolCallRowView(toolCall: toolCall)
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
