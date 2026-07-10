import ComposableArchitecture
import ConductorData
import ConductorDesign
import Foundation
import SQLiteData
import SwiftUI

@Reducer
public struct Chat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?
        @FetchAll public var messages: [Message]
        public let session: Session

        public init(session: Session) {
            self.session = session
            self._messages = FetchAll(
                wrappedValue: [],
                Message
                    .where { $0.sessionID.eq(session.id) }
                    .order { $0.createdAt.asc() },
                animation: .default
            )
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)
        @ReducerCaseIgnored case message(Message)

        public enum Alert: Equatable { }
    }

    public enum Action {
        case task
        case destination(PresentationAction<Destination.Action>)
        case loadMessagesFailed(String)
        case messageTapped(Message)
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient

    public init() { }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { [sessionID = state.session.id, workspaceID = state.session.workspaceID] send in
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

            case .destination:
                return .none

            case let .loadMessagesFailed(message):
                state.destination = .alert(.failedToLoadMessages(message: message))
                return .none

            case let .messageTapped(message):
                state.destination = .message(message)
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func refreshMessages(
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

    private func loadMessages(workspaceID: String, sessionID: String) async throws {
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
            LazyVStack(spacing: 0) {
                ForEach(store.messages) { message in
                    MessageRow(message: message) {
                        store.send(.messageTapped(message))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .background(.theme(.background))
        .overlay {
            if store.messages.isEmpty {
                EmptyChatView()
            }
        }
        .themedNavigationTitle(verbatim: store.session.displayTitle)
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .sheet(item: $store.scope(state: \.destination?.message, action: \.destination.message)) { messageStore in
            MessageSheet(message: messageStore.withState { $0 })
        }
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

    private struct MessageRow: View {
        let message: Message
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(message.previewContent)
                    .font(.theme(.body))
                    .foregroundStyle(.theme(.textPrimary))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private struct MessageSheet: View {
        let message: Message

        var body: some View {
            ScrollView {
                Text(message.fullContent)
                    .font(.theme(.body))
                    .foregroundStyle(.theme(.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(.theme(.background))
            .presentationDragIndicator(.visible)
        }
    }
}

private extension Message {
    var fullContent: String {
        fullMessage ?? content ?? ""
    }

    var previewContent: String {
        content ?? fullMessage ?? ""
    }
}

#Preview {
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
    }
    let session = try! JSONDecoder().decode(
        Session.self,
        from: Data(
            """
            {
              "id": "session-1",
              "workspace_id": "workspace-1",
              "title": "Chat",
              "agent_type": "codex",
              "created_at": "2026-07-09 00:00:00",
              "updated_at": "2026-07-09 00:00:00",
              "status": "idle",
              "model": "gpt-5",
              "unread_count": 0,
              "freshly_compacted": 0,
              "context_token_count": 0
            }
            """.utf8
        )
    )

    NavigationStack {
        ChatView(
            store: Store(initialState: Chat.State(session: session)) {
                Chat()
            }
        )
    }
    .preferredColorScheme(.dark)
}
