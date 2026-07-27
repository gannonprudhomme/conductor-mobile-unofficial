//
//  Chat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Combine
import ComposableArchitecture
import ConductorCloud
import ConductorDesign
import ConductorMobileData
import Foundation
import Logging
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI

/// Note: this is always embedded in ``WorkspaceChat``, never solo
/// i.e. this doesn't own its nav bar
@Reducer
public struct Chat: Sendable {
    public typealias TurnSummaryID = String

    enum Backend: Equatable, Sendable {
        case cloud
        case desktop
    }

    @ObservableState
    public struct State: Equatable {
        @Shared(.desktopConnectionStatus)
        var connectionStatus

        @Shared var messageDraft: String

        @FetchAll var messages: [Message]
        @FetchOne var session: Session
        let backend: Backend
        var cloudMessages: [Message] = []
        var cloudSessionStatus: Session.Status?
        var isFastModeEnabled: Bool
        var isLoadingMessages = true
        var isMessageSnapshotEmpty = false
        var isMessageSendInFlight = false
        var isStopInFlight = false
        var hasObservedSessionModelChange = false
        var hasUserSelectedModel = false
        var lastCloudMessageID: String?
        var scrollToBottomRequest = 0
        var shouldSendInitialPrompt = false
        var shouldFocusMessageField = false

        /// POST-confirmed message rows retained so a slower first WebSocket snapshot cannot hide them.
        var confirmedMessagesAwaitingInitialSnapshot: [Message] = []
        var expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []
        var selectedModel: Session.Model

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

        var allowsAgentSwitching: Bool {
            backend == .desktop
                && shouldShowEmptyChat
                && !isMessageSendInFlight
        }

        var isCloud: Bool {
            backend == .cloud
        }

        var sessionStatus: Session.Status {
            cloudSessionStatus ?? session.status
        }

        var nextCloudPollDelay: Duration {
            sessionStatus == .working ? .seconds(3) : .seconds(8)
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

        init(
            session: Session,
            messages: [Message] = [],
            selectedModel: Session.Model? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            self.backend = .desktop
            @Shared(.messageDrafts) var messageDrafts
            self._messageDraft = $messageDrafts[draftFor: session.id]
            self.isFastModeEnabled = session.isFastModeEnabled ?? false
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
            self.hasUserSelectedModel = selectedModel != nil
            self.selectedModel = selectedModel ?? session.model
            self.shouldFocusMessageField = shouldFocusMessageField
        }

        init(
            cloudSession: CloudSession,
            workspaceID: String,
            initialPrompt: String = "",
            shouldFocusMessageField: Bool = false
        ) {
            let session = Session(
                cloudSession: cloudSession,
                workspaceID: workspaceID
            )

            self.backend = .cloud
            @Shared(.messageDrafts) var messageDrafts
            self._messageDraft = $messageDrafts[draftFor: session.id]
            self.isFastModeEnabled = session.isFastModeEnabled ?? false
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = FetchAll(
                wrappedValue: [],
                Message.where { $0.sessionID.eq(session.id) }
            )
            self.hasUserSelectedModel = true
            self.selectedModel = session.model
            self.shouldFocusMessageField = shouldFocusMessageField
                || !initialPrompt.isEmpty
            self.shouldSendInitialPrompt = !initialPrompt.isEmpty
            if !initialPrompt.isEmpty {
                self.$messageDraft.withLock { $0 = initialPrompt }
            }
        }

        /// `turns` and `rows` are derived presentation caches, while `session` captures
        /// status-driven changes.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.backend == rhs.backend
                && lhs.messages == rhs.messages
                && lhs.session == rhs.session
                && lhs.connectionStatus == rhs.connectionStatus
                && lhs.cloudMessages == rhs.cloudMessages
                && lhs.cloudSessionStatus == rhs.cloudSessionStatus
                && lhs.isFastModeEnabled == rhs.isFastModeEnabled
                && lhs.messageDraft == rhs.messageDraft
                && lhs.isLoadingMessages == rhs.isLoadingMessages
                && lhs.isMessageSnapshotEmpty == rhs.isMessageSnapshotEmpty
                && lhs.isMessageSendInFlight == rhs.isMessageSendInFlight
                && lhs.isStopInFlight == rhs.isStopInFlight
                && lhs.hasObservedSessionModelChange == rhs.hasObservedSessionModelChange
                && lhs.hasUserSelectedModel == rhs.hasUserSelectedModel
                && lhs.lastCloudMessageID == rhs.lastCloudMessageID
                && lhs.scrollToBottomRequest == rhs.scrollToBottomRequest
                && lhs.shouldSendInitialPrompt == rhs.shouldSendInitialPrompt
                && lhs.shouldFocusMessageField == rhs.shouldFocusMessageField
                && lhs.confirmedMessagesAwaitingInitialSnapshot
                    == rhs.confirmedMessagesAwaitingInitialSnapshot
                && lhs.expandedSummaryIDs == rhs.expandedSummaryIDs
                && lhs.selectedModel == rhs.selectedModel
        }

        /// Read by ``WorkspaceChat`` to track the selected session.
        var sessionID: Session.ID { session.id }
    }

    public struct CloudSnapshot: Equatable, Sendable {
        let messages: [CloudTranscriptMessage]
        let status: CloudSessionStatusResponse
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case cloudPoll
        case cloudSnapshotResponse(
            isInitial: Bool,
            Result<CloudSnapshot, any Error>
        )
        case task
        case defaultModelFetched(Session.Model)
        case fastModeButtonTapped
        case initialMessagesResponse(
            sessionID: Session.ID,
            messages: [Message]
        )
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
        case sessionModelChanged(Session.Model)
        case sessionFastModeChanged(Bool)
        case sessionStatusChanged(Session.Status)
        case stopButtonTapped
        case stopSessionResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case turnSummaryTapped(Chat.TurnSummaryID)
        case viewDisappeared
    }

    private enum CancelID {
        case cloudPolling
    }

    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.uuid) var uuid

    init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .task:
                if state.backend == .cloud {
                    return loadCloudSnapshot(
                        sessionID: state.sessionID,
                        after: nil,
                        isInitial: true
                    )
                }
                return .merge(
                    .run { send in
                        guard let model = try? await desktopClient.fetchDefaultModel() else {
                            return
                        }
                        await send(.defaultModelFetched(model))
                    },
                    observeMessages(state),
                    .publisher {
                        state.$messages
                            .publisher
                            .removeDuplicates()
                            .map(Action.messagesUpdated)
                    }
                )

            case .cloudPoll:
                guard state.backend == .cloud else {
                    return .none
                }
                return loadCloudSnapshot(
                    sessionID: state.sessionID,
                    after: state.lastCloudMessageID,
                    isInitial: false
                )

            case let .cloudSnapshotResponse(isInitial, result):
                guard state.backend == .cloud else {
                    return .none
                }

                switch result {
                case let .failure(error):
                    if isInitial {
                        state.isLoadingMessages = false
                    }
                    return .merge(
                        .send(.loadMessagesFailed(error)),
                        scheduleCloudPoll(after: state.nextCloudPollDelay)
                    )

                case let .success(snapshot):
                    let transcriptMessages = CloudTranscriptMessage.normalized(
                        snapshot.messages
                    )
                    let incomingMessages = transcriptMessages.flatMap(\.chatMessages)
                    if isInitial {
                        state.cloudMessages = incomingMessages
                        state.isLoadingMessages = false
                        state.isMessageSnapshotEmpty = transcriptMessages.isEmpty
                    } else {
                        let incomingIDs = Set(incomingMessages.map(\.id))
                        state.cloudMessages.removeAll { incomingIDs.contains($0.id) }
                        state.cloudMessages.append(contentsOf: incomingMessages)
                        if !incomingMessages.isEmpty {
                            state.scrollToBottomRequest &+= 1
                        }
                    }
                    state.cloudMessages.sort {
                        if $0.createdAt != $1.createdAt {
                            $0.createdAt < $1.createdAt
                        } else {
                            $0.id < $1.id
                        }
                    }
                    state.lastCloudMessageID = transcriptMessages.last?.id
                        ?? state.lastCloudMessageID
                    state.cloudSessionStatus = Session.Status(
                        rawValue: snapshot.status.status.rawValue
                    )
                    state.turns = Turn.parse(
                        messages: state.cloudMessages,
                        reusing: state.turns ?? []
                    )
                    state.updateRows(sessionStatus: state.sessionStatus)

                    let shouldSendInitialPrompt = isInitial
                        && state.shouldSendInitialPrompt
                        && !state.messageDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    if isInitial {
                        state.shouldSendInitialPrompt = false
                    }
                    return .merge(
                        scheduleCloudPoll(after: state.nextCloudPollDelay),
                        shouldSendInitialPrompt ? .send(.sendButtonTapped) : .none
                    )
                }

            case let .defaultModelFetched(model):
                guard !state.hasObservedSessionModelChange,
                      !state.hasUserSelectedModel,
                      Session.Model.models(for: state.session.agentType).contains(model)
                else {
                    return .none
                }
                state.selectedModel = model
                return .none

            case .binding(\.selectedModel):
                state.hasUserSelectedModel = true
                return .none

            case .messagesUpdated(let messages):
                state.isMessageSnapshotEmpty = messages.isEmpty
                state.turns = Turn.parse(
                    messages: messages,
                    reusing: state.turns ?? []
                )
                state.updateRows(sessionStatus: state.session.status)
                return .none

            case let .initialMessagesResponse(sessionID, messages):
                guard sessionID == state.sessionID else {
                    return .none
                }
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
                guard state.backend == .desktop else {
                    return .none
                }
                state.updateRows(sessionStatus: status)
                return .none

            case let .sessionModelChanged(model):
                guard !state.hasUserSelectedModel else {
                    return .none
                }
                state.hasObservedSessionModelChange = true
                state.selectedModel = model
                return .none

            case let .sessionFastModeChanged(isFastModeEnabled):
                state.isFastModeEnabled = isFastModeEnabled
                return .none

            case .fastModeButtonTapped:
                guard state.backend == .desktop else {
                    return .none
                }
                state.isFastModeEnabled.toggle()
                return .none

            case .turnSummaryTapped(let summaryID):
                if state.expandedSummaryIDs.remove(summaryID) == nil {
                    state.expandedSummaryIDs.insert(summaryID)
                }
                state.updateRows(sessionStatus: state.sessionStatus)
                return .none

            case .sendButtonTapped:
                let message = state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, !state.isMessageSendInFlight else {
                    return .none
                }

                state.isMessageSendInFlight = true
                state.scrollToBottomRequest &+= 1
                let messageID = state.backend == .cloud
                    ? uuid().uuidString.lowercased()
                    : ""
                return .run {
                    [
                        backend = state.backend,
                        model = state.selectedModel,
                        isFastModeEnabled = state.isFastModeEnabled,
                        messageID,
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    let result = await Result {
                        if backend == .cloud {
                            _ = try await cloudAPIClient.sendMessage(
                                sessionID: sessionID,
                                messageID: messageID,
                                message: message
                            )
                            return message
                        }
                        if let canonicalMessage = try await desktopClient.sendMessage(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            message: message,
                            model: model,
                            isFastModeEnabled: isFastModeEnabled
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
                    if state.backend == .cloud {
                        state.cloudSessionStatus = .working
                        state.updateRows(sessionStatus: .working)
                        return scheduleCloudPoll(
                            after: .seconds(1),
                            cancelInFlight: true
                        )
                    }
                    return .none

                case .failure:
                    // Send errors are displayed by the parent ``WorkspaceChat``.
                    return .none
                }

            case .stopButtonTapped:
                guard state.sessionStatus == .working, !state.isStopInFlight else {
                    return .none
                }

                state.isStopInFlight = true
                return .run {
                    [
                        backend = state.backend,
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    let result = await Result {
                        if backend == .cloud {
                            _ = try await cloudAPIClient.cancelSession(
                                sessionID: sessionID
                            )
                            return
                        }
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

            case let .stopSessionResponse(sessionID, result):
                // Like sends, stop requests intentionally survive session navigation, so ignore
                // responses for a session that has since been replaced.
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isStopInFlight = false
                if state.backend == .cloud, case .success = result {
                    state.cloudSessionStatus = .idle
                    state.updateRows(sessionStatus: .idle)
                }
                return .none

            case .loadMessagesFailed:
                return .none

            case .viewDisappeared:
                return .cancel(id: CancelID.cloudPolling)

            case .binding:
                return .none
            }
        }
    }

    private func loadCloudSnapshot(
        sessionID: String,
        after messageID: String?,
        isInitial: Bool
    ) -> Effect<Action> {
        .run { send in
            await send(
                .cloudSnapshotResponse(
                    isInitial: isInitial,
                    await Result {
                        async let status = cloudAPIClient.sessionStatus(
                            sessionID: sessionID
                        )
                        let messages = if let messageID {
                            try await cloudAPIClient.messagesAfter(
                                sessionID: sessionID,
                                messageID: messageID
                            )
                        } else {
                            try await cloudAPIClient.allMessages(
                                sessionID: sessionID
                            )
                        }
                        return try await CloudSnapshot(
                            messages: messages,
                            status: status
                        )
                    }
                )
            )
        }
        .cancellable(id: CancelID.cloudPolling, cancelInFlight: true)
    }

    private func scheduleCloudPoll(
        after duration: Duration,
        cancelInFlight: Bool = false
    ) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: duration)
            await send(.cloudPoll)
        }
        .cancellable(
            id: CancelID.cloudPolling,
            cancelInFlight: cancelInFlight
        )
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
                let request = try await messageSyncRequest(sessionID: sessionID)
                return desktopClient.observeMessages(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    request: request
                )
            } onValue: { response in
                let messages = try await reconcileMessages(
                    response,
                    sessionID: sessionID
                )
                if isAwaitingInitialResponse {
                    isAwaitingInitialResponse = false
                    await send(
                        .initialMessagesResponse(
                            sessionID: sessionID,
                            messages: messages
                        )
                    )
                }
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

    @concurrent func messageSyncRequest( // only non-private for tests
        sessionID: Session.ID
    ) async throws -> MessageSyncRequest {
        let messages = try await database.read { database in
            try fetchMessages(sessionID: sessionID, from: database)
        }
        var fingerprints: [Message.ID: Data] = [:]
        for message in messages {
            fingerprints[message.id] = try message.syncFingerprint()
        }
        return MessageSyncRequest(fingerprints: fingerprints)
    }

    @concurrent func reconcileMessages( // only non-private for tests
        _ response: MessageSyncResponse,
        sessionID: Session.ID
    ) async throws -> [Message] {
        guard response.messages.allSatisfy({ $0.sessionID == sessionID }) else {
            throw MessageReconciliationError.invalidSession
        }

        guard !response.messages.isEmpty || !response.deletedMessageIDs.isEmpty else {
            return try await database.read { database in
                try fetchMessages(sessionID: sessionID, from: database)
            }
        }

        return try await database.write { database in
            if !response.deletedMessageIDs.isEmpty {
                try Message
                    .where {
                        $0.id.in(response.deletedMessageIDs)
                            && $0.sessionID.eq(sessionID)
                    }
                    .delete()
                    .execute(database)
            }
            if !response.messages.isEmpty {
                try Message.upsert { response.messages }.execute(database)
            }
            return try fetchMessages(sessionID: sessionID, from: database)
        }
    }

    private func fetchMessages(
        sessionID: Session.ID,
        from database: Database
    ) throws -> [Message] {
        try Message
            .where { $0.sessionID.eq(sessionID) }
            .order {
                (
                    $0.sentAt.asc(nulls: .last),
                    $0.createdAt,
                    $0.id
                )
            }
            .fetchAll(database)
    }
}

extension Session {
    init(
        cloudSession: CloudSession,
        workspaceID: String,
        status: Status = .idle
    ) {
        let model = Model(
            rawValue: cloudSession.model
                ?? cloudSession.resolvedModel
                ?? Model.gpt_5_6_sol.rawValue
        )
        self.init(
            id: cloudSession.id,
            workspaceID: workspaceID,
            title: cloudSession.name ?? "Untitled",
            agentType: model.agentType ?? .codex,
            isHidden: cloudSession.archivedAt != nil,
            createdAt: "",
            updatedAt: "",
            lastUserMessageAt: nil,
            status: status,
            model: model,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0,
            isFastModeEnabled: cloudSession.fastMode
        )
    }
}

enum MessageReconciliationError: Error { // only non-private for tests
    case invalidSession
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

extension CloudTranscriptMessage {
    var chatMessages: [Message] {
        guard case let .object(content) = content,
              let contentType = content["type"]?.stringValue
        else {
            return []
        }

        let turnID = content["turnId"]?.stringValue ?? id
        switch contentType {
        case "userMessage":
            guard let text = content["message"]?.stringValue else {
                return []
            }
            return [
                Message(
                    id: id,
                    sessionID: sessionID,
                    role: .user,
                    content: text,
                    createdAt: receivedAt,
                    sentAt: receivedAt,
                    turnID: turnID,
                    senderID: content["senderId"]?.stringValue
                ),
            ]

        case "agent":
            guard case let .object(rawPayload) = content["rawPayload"],
                  case let .object(event) = rawPayload["event"]
            else {
                return []
            }
            return normalizedAgentMessages(event: event, turnID: turnID)

        default:
            return []
        }
    }

    private func normalizedAgentMessages(
        event: [String: CloudJSONValue],
        turnID: String
    ) -> [Message] {
        guard let eventType = event["type"]?.stringValue else {
            return []
        }

        switch eventType {
        case "item.started", "item.completed":
            guard case let .object(item) = event["item"],
                  let itemType = item["type"]?.stringValue
            else {
                return []
            }
            return normalizedItemMessages(
                item,
                itemType: itemType,
                isCompleted: eventType == "item.completed",
                turnID: turnID
            )

        case "turn.completed":
            return message(
                event: [
                    "type": "result",
                    "usage": [
                        "input_tokens": 0,
                        "output_tokens": 0,
                        "cache_read_input_tokens": 0,
                    ],
                ],
                turnID: turnID
            )

        case "turn.failed", "error":
            let error = event["error"]?.displayString
                ?? event["message"]?.stringValue
                ?? "The cloud agent reported an error."
            return message(
                event: [
                    "type": "error",
                    "content": error,
                    "willRetry": false,
                ],
                turnID: turnID
            )

        default:
            return []
        }
    }

    private func normalizedItemMessages(
        _ item: [String: CloudJSONValue],
        itemType: String,
        isCompleted: Bool,
        turnID: String
    ) -> [Message] {
        let toolUseID = item["id"]?.stringValue ?? id

        switch (itemType, isCompleted) {
        case ("agentMessage", true):
            guard let text = item["text"]?.stringValue, !text.isEmpty else {
                return []
            }
            return message(
                event: assistantEvent(
                    content: [
                        "type": "text",
                        "text": text,
                    ]
                ),
                turnID: turnID
            )

        case ("commandExecution", false):
            return message(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "Bash",
                        input: [
                            "command": item["command"]?.stringValue ?? "",
                        ]
                    )
                ),
                turnID: turnID
            )

        case ("commandExecution", true):
            let status = item["status"]?.stringValue
            let exitCode = item["exitCode"]?.integerValue
            return message(
                event: toolResult(
                    id: toolUseID,
                    content: item["aggregatedOutput"]?.stringValue ?? "",
                    isError: status == "failed" || (exitCode.map { $0 != 0 } ?? false)
                ),
                turnID: turnID
            )

        case ("imageView", false):
            return message(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "Read",
                        input: [
                            "file_path": item["path"]?.stringValue ?? "",
                        ]
                    )
                ),
                turnID: turnID
            )

        case ("imageView", true):
            return message(
                event: toolResult(id: toolUseID, content: "", isError: false),
                turnID: turnID
            )

        case ("mcpToolCall", false):
            let server = item["server"]?.stringValue ?? "unknown"
            let tool = item["tool"]?.stringValue ?? "unknown"
            return message(
                event: assistantEvent(
                    content: toolUse(
                        id: toolUseID,
                        name: "mcp__\(server)__\(tool)",
                        input: item["arguments"]?.foundationObject ?? [:]
                    )
                ),
                turnID: turnID
            )

        case ("mcpToolCall", true):
            let status = item["status"]?.stringValue
            let error = item["error"]?.displayString
            return message(
                event: toolResult(
                    id: toolUseID,
                    content: error
                        ?? item["result"]?.displayString
                        ?? "",
                    isError: error != nil || status == "failed"
                ),
                turnID: turnID
            )

        case ("fileChange", _):
            guard case let .array(changes) = item["changes"] else {
                return []
            }
            return changes.enumerated().flatMap { index, change -> [Message] in
                guard case let .object(change) = change else {
                    return []
                }
                let changeID = "\(toolUseID):\(index)"
                if isCompleted {
                    return message(
                        event: toolResult(
                            id: changeID,
                            content: "",
                            isError: item["status"]?.stringValue == "failed"
                        ),
                        turnID: turnID,
                        idSuffix: index
                    )
                }
                return message(
                    event: assistantEvent(
                        content: toolUse(
                            id: changeID,
                            name: "Edit",
                            input: [
                                "file_path": change["path"]?.stringValue ?? "",
                                "old_string": "",
                                "new_string": change["diff"]?.stringValue ?? "",
                            ]
                        )
                    ),
                    turnID: turnID,
                    idSuffix: index
                )
            }

        default:
            return []
        }
    }

    private func message(
        event: [String: Any],
        turnID: String,
        idSuffix: Int? = nil
    ) -> [Message] {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(
                  withJSONObject: event,
                  options: .sortedKeys
              ),
              let content = String(data: data, encoding: .utf8)
        else {
            return []
        }
        return [
            Message(
                id: idSuffix.map { "\(id):\($0)" } ?? id,
                sessionID: sessionID,
                role: .assistant,
                content: content,
                createdAt: receivedAt,
                sentAt: receivedAt,
                turnID: turnID
            ),
        ]
    }

    private func assistantEvent(content: [String: Any]) -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [content],
            ],
        ]
    }

    private func toolUse(
        id: String,
        name: String,
        input: [String: Any]
    ) -> [String: Any] {
        [
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": input,
        ]
    }

    private func toolResult(
        id: String,
        content: String,
        isError: Bool
    ) -> [String: Any] {
        [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": content,
                        "is_error": isError,
                    ],
                ],
            ],
        ]
    }
}

private extension CloudJSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value):
            value
        case let .number(value):
            Int64(exactly: value)
        default:
            nil
        }
    }

    var foundationObject: [String: Any]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value.mapValues(\.foundationValue)
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .number(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map(\.foundationValue)
        case let .object(value):
            value.mapValues(\.foundationValue)
        }
    }

    var displayString: String? {
        if let stringValue {
            return stringValue
        }
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: foundationValue),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}

struct ChatView: View {
    @Bindable var store: StoreOf<Chat>
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
                    if !store.isCloud, store.connectionStatus != .connected {
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
                        allowsAgentSwitching: store.allowsAgentSwitching,
                        isFastModeEnabled: store.isFastModeEnabled,
                        isFastModeButtonDisabled: store.isCloud,
                        isSendInFlight: store.isMessageSendInFlight,
                        isStopInFlight: store.isStopInFlight,
                        isWorking: store.sessionStatus == .working,
                        selectedModel: $store.selectedModel,
                        shouldFocusOnAppear: store.shouldFocusMessageField,
                        onFastModeTapped: { store.send(.fastModeButtonTapped) },
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
            .onChange(of: store.session.model) { _, model in
                store.send(.sessionModelChanged(model))
            }
            .onChange(of: store.session.isFastModeEnabled) { _, isFastModeEnabled in
                store.send(.sessionFastModeChanged(isFastModeEnabled ?? false))
            }
            .task(id: store.session.id) {
                await store.send(.task).finish()
            }
            .onDisappear {
                store.send(.viewDisappeared)
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
            $0.desktopClient.observeMessages = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(
                        MessageSyncResponse(messages: [], deletedMessageIDs: [])
                    )
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
