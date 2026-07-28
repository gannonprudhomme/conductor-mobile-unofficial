//
//  Chat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Combine
import ComposableArchitecture
import ConductorDesign
import ConductorMobileData
import Foundation
import Logging
import SharedConductorData
import Sharing
import SQLiteData
import SwiftUI

struct ContextWindowUsage: Equatable, Sendable {
    let usedTokens: Int
    let tokenLimit: Int

    init(usedTokens: Int, tokenLimit: Int) {
        self.usedTokens = max(0, usedTokens)
        self.tokenLimit = tokenLimit
    }

    var fraction: Double {
        guard tokenLimit > 0 else {
            return 0
        }
        return min(max(Double(usedTokens) / Double(tokenLimit), 0), 1)
    }

    var percentage: Int {
        Int((fraction * 100).rounded())
    }
}

/// Note: this is always embedded in ``WorkspaceChat``, never solo
/// i.e. this doesn't own its nav bar
@Reducer
public struct Chat: Sendable {
    public typealias TurnSummaryID = String

    @ObservableState
    public struct State: Equatable {
        @Shared(.desktopConnectionStatus)
        var connectionStatus//: DesktopClient.ConnectionStatus = .connecting

        @Shared(.mobileModelSettingsOverride)
        var mobileModelSettingsOverride

        @Shared var messageDraft: String

        @FetchAll var messages: [Message]
        @FetchOne var session: Session
        var queuedMessages: QueuedMessages.State
        var isFastModeEnabled: Bool
        var isLoadingMessages = true
        var isMessageSnapshotEmpty = false
        var isMessageSendInFlight = false
        var isStopInFlight = false
        var hasObservedSessionFastModeChange = false
        var hasObservedSessionModelChange = false
        var hasObservedSessionReasoningEffortChange = false
        var hasUserSelectedFastMode = false
        var hasUserSelectedModel = false
        var hasUserSelectedReasoningEffort = false
        var scrollToBottomRequest = 0
        var shouldFocusMessageField = false

        /// POST-confirmed message rows retained so a slower first WebSocket snapshot cannot hide them.
        var confirmedMessagesAwaitingInitialSnapshot: [Message] = []
        var expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []
        var reportedContextWindowTokenLimits: [Session.Model: Int] = [:]
        var selectedModel: Session.Model
        var selectedReasoningEffort: Session.ReasoningEffort?

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
            !isLoadingMessages && isMessageSnapshotEmpty && queuedMessages.messages.isEmpty
        }

        var allowsAgentSwitching: Bool {
            shouldShowEmptyChat && !isMessageSendInFlight
        }

        var availableReasoningEfforts: [Session.ReasoningEffort] {
            session.availableReasoningEfforts(for: selectedModel)
        }

        var contextWindowUsage: ContextWindowUsage? {
            let tokenLimit = reportedContextWindowTokenLimits[selectedModel]
                ?? selectedModel.fallbackContextWindowTokenLimit
            guard let tokenLimit else {
                return nil
            }
            return ContextWindowUsage(
                usedTokens: session.contextTokenCount,
                tokenLimit: tokenLimit
            )
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

        mutating func updateReportedContextWindowTokenLimits() {
            reportedContextWindowTokenLimits = (turns ?? []).reduce(into: [:]) { limits, turn in
                guard let report = turn.contextWindowReport else {
                    return
                }
                limits[Session.Model(rawValue: report.requestedModel)] = report.tokenLimit
            }
        }

        init(
            session: Session,
            messages: [Message] = [],
            selectedModel: Session.Model? = nil,
            selectedReasoningEffort: Session.ReasoningEffort? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            @Shared(.messageDrafts) var messageDrafts
            self._messageDraft = $messageDrafts[draftFor: session.id]
            self.isFastModeEnabled = session.isFastModeEnabled ?? false
            self.queuedMessages = QueuedMessages.State(session: session)
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = FetchAll(
                wrappedValue: messages,
                Message
                    .where {
                        $0.sessionID.eq(session.id)
                            && ($0.sentAt.isNot(nil) || $0.queueOrder.is(nil))
                    }
                    .order {
                        (
                            $0.sentAt.asc(nulls: .last),
                            $0.createdAt,
                            $0.id // IDs provide stable ordering when Conductor gives multiple messages identical timestamps.
                        )
                    }
            )
            self.hasUserSelectedModel = selectedModel != nil
            self.hasUserSelectedReasoningEffort = selectedReasoningEffort != nil
            self.selectedModel = selectedModel ?? session.model
            self.selectedReasoningEffort = selectedReasoningEffort ?? session.reasoningEffort
            self.shouldFocusMessageField = shouldFocusMessageField
            reconcileSelectedReasoningEffort()
        }

        mutating func reconcileSelectedReasoningEffort() {
            let efforts = availableReasoningEfforts
            guard let selectedReasoningEffort,
                  efforts.contains(selectedReasoningEffort) else {
                selectedReasoningEffort = efforts.contains(selectedModel.defaultReasoningEffort)
                    ? selectedModel.defaultReasoningEffort
                    : efforts.first
                return
            }
        }

        /// `turns` and `rows` are derived presentation caches, while `session` captures
        /// status-driven changes.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.messages == rhs.messages
                && lhs.queuedMessages == rhs.queuedMessages
                && lhs.session == rhs.session
                && lhs.connectionStatus == rhs.connectionStatus
                && lhs.mobileModelSettingsOverride == rhs.mobileModelSettingsOverride
                && lhs.isFastModeEnabled == rhs.isFastModeEnabled
                && lhs.messageDraft == rhs.messageDraft
                && lhs.isLoadingMessages == rhs.isLoadingMessages
                && lhs.isMessageSnapshotEmpty == rhs.isMessageSnapshotEmpty
                && lhs.isMessageSendInFlight == rhs.isMessageSendInFlight
                && lhs.isStopInFlight == rhs.isStopInFlight
                && lhs.hasObservedSessionFastModeChange == rhs.hasObservedSessionFastModeChange
                && lhs.hasObservedSessionModelChange == rhs.hasObservedSessionModelChange
                && lhs.hasObservedSessionReasoningEffortChange
                    == rhs.hasObservedSessionReasoningEffortChange
                && lhs.hasUserSelectedFastMode == rhs.hasUserSelectedFastMode
                && lhs.hasUserSelectedModel == rhs.hasUserSelectedModel
                && lhs.hasUserSelectedReasoningEffort == rhs.hasUserSelectedReasoningEffort
                && lhs.scrollToBottomRequest == rhs.scrollToBottomRequest
                && lhs.shouldFocusMessageField == rhs.shouldFocusMessageField
                && lhs.confirmedMessagesAwaitingInitialSnapshot
                    == rhs.confirmedMessagesAwaitingInitialSnapshot
                && lhs.expandedSummaryIDs == rhs.expandedSummaryIDs
                && lhs.reportedContextWindowTokenLimits
                    == rhs.reportedContextWindowTokenLimits
                && lhs.selectedModel == rhs.selectedModel
                && lhs.selectedReasoningEffort == rhs.selectedReasoningEffort
        }

        /// Read by ``WorkspaceChat`` to track the selected session.
        var sessionID: Session.ID { session.id }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case modelSettingsFetched(DesktopClient.ModelSettings)
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
        case queuedMessages(QueuedMessages.Action)
        case reasoningEffortSelected(Session.ReasoningEffort)
        case sendButtonTapped(DesktopClient.MessageMode)
        case sendMessageResponse(
            sessionID: Session.ID,
            result: Result<String, any Error>
        )
        case sessionModelChanged(Session.Model)
        case sessionFastModeChanged(Bool)
        case sessionStatusChanged(Session.Status)
        case sessionReasoningEffortChanged(Session.ReasoningEffort?)
        case stopButtonTapped
        case stopSessionResponse(
            sessionID: Session.ID,
            result: Result<Void, any Error>
        )
        case turnSummaryTapped(Chat.TurnSummaryID)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.desktopClient) var desktopClient
    private let messagePersistence = MessagePersistencePipeline()

    init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.queuedMessages, action: \.queuedMessages) {
            QueuedMessages()
        }

        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    .run { send in
                        guard let settings = try? await desktopClient.fetchModelSettings() else {
                            return
                        }
                        await send(.modelSettingsFetched(settings))
                    },
                    observeMessages(state),
                    observePersistedMessages(state)
                )

            case let .modelSettingsFetched(settings):
                let settings = state.mobileModelSettingsOverride ?? settings
                if !state.hasObservedSessionModelChange,
                   !state.hasUserSelectedModel,
                   Session.Model.models(for: state.session.agentType)
                    .contains(settings.defaultModel) {
                    state.selectedModel = settings.defaultModel
                    state.reconcileSelectedReasoningEffort()
                }
                if state.session.lastUserMessageAt == nil,
                   state.session.isFastModeEnabled == nil,
                   !state.hasObservedSessionFastModeChange,
                   !state.hasUserSelectedFastMode {
                    state.isFastModeEnabled = settings.isFastModeEnabled
                }
                if state.session.lastUserMessageAt == nil,
                   state.session.reasoningEffort == nil,
                   !state.hasObservedSessionReasoningEffortChange,
                   !state.hasUserSelectedReasoningEffort {
                    state.selectedReasoningEffort = settings.defaultReasoningEffort
                    state.reconcileSelectedReasoningEffort()
                }
                return .none

            case .binding(\.selectedModel):
                state.hasUserSelectedModel = true
                state.reconcileSelectedReasoningEffort()
                return .none

            case .messagesUpdated(let messages):
                state.isMessageSnapshotEmpty = messages.isEmpty
                state.turns = Turn.parse(
                    messages: messages,
                    reusing: state.turns ?? []
                )
                state.updateReportedContextWindowTokenLimits()
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
                let displayedMessages = messages + confirmedMessagesMissingFromSnapshot
                let transcriptMessages = displayedMessages
                    .filter(Self.isTranscriptMessage)
                    .sorted(by: Self.areMessagesInTranscriptOrder)
                state.isMessageSnapshotEmpty = transcriptMessages.isEmpty
                state.turns = Turn.parse(
                    messages: transcriptMessages,
                    reusing: state.turns ?? []
                )
                state.updateReportedContextWindowTokenLimits()
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

            case let .sessionModelChanged(model):
                guard !state.hasUserSelectedModel else {
                    return .none
                }
                state.hasObservedSessionModelChange = true
                state.selectedModel = model
                state.reconcileSelectedReasoningEffort()
                return .none

            case let .sessionFastModeChanged(isFastModeEnabled):
                state.hasObservedSessionFastModeChange = true
                state.isFastModeEnabled = isFastModeEnabled
                return .none

            case .fastModeButtonTapped:
                state.hasUserSelectedFastMode = true
                state.isFastModeEnabled.toggle()
                return .none

            case let .reasoningEffortSelected(reasoningEffort):
                guard state.availableReasoningEfforts.contains(reasoningEffort) else {
                    return .none
                }
                state.hasUserSelectedReasoningEffort = true
                state.selectedReasoningEffort = reasoningEffort
                return .none

            case let .sessionReasoningEffortChanged(reasoningEffort):
                state.hasObservedSessionReasoningEffortChange = true
                state.selectedReasoningEffort = reasoningEffort
                state.reconcileSelectedReasoningEffort()
                return .none

            case .turnSummaryTapped(let summaryID):
                if state.expandedSummaryIDs.remove(summaryID) == nil {
                    state.expandedSummaryIDs.insert(summaryID)
                }
                state.updateRows(sessionStatus: state.session.status)
                return .none

            case let .sendButtonTapped(mode):
                let message = state.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, !state.isMessageSendInFlight else {
                    return .none
                }

                state.isMessageSendInFlight = true
                state.scrollToBottomRequest &+= 1
                return .run {
                    [
                        model = state.selectedModel,
                        reasoningEffort = state.selectedReasoningEffort,
                        isFastModeEnabled = state.isFastModeEnabled,
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    let result = await Result {
                        if let canonicalMessage = try await desktopClient.sendMessage(
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            message: message,
                            model: model,
                            isFastModeEnabled: isFastModeEnabled,
                            mode: mode,
                            reasoningEffort: reasoningEffort
                        ) {
                            do {
                                try await messagePersistence.confirm(
                                    canonicalMessage,
                                    sessionID: sessionID,
                                    database: database
                                )
                            } catch {
                                Logger.chat.error(
                                    "Failed to reconcile sent message: \(error)"
                                )
                            }
                            await send(
                                .messageConfirmed(
                                    sessionID: sessionID,
                                    message: canonicalMessage
                                )
                            )
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

            case .binding, .queuedMessages:
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
            await StreamObservation.observe {
                desktopClient.observeMessages(
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
            } onValue: { event in
                let persistedEvent = try await messagePersistence.apply(
                    event,
                    sessionID: sessionID,
                    database: database
                )
                if isAwaitingInitialResponse, event.isSnapshot {
                    isAwaitingInitialResponse = false
                    await send(
                        .initialMessagesResponse(
                            sessionID: sessionID,
                            messages: persistedEvent.messages
                        )
                    )
                }
            } onFailure: { error in
                Logger.chat.error("Failed to load messages: \(error)")
                await send(.loadMessagesFailed(error))
            }
        }
    }

    private func observePersistedMessages(_ state: State) -> Effect<Action> {
        .publisher {
            state.$messages.publisher
                .removeDuplicates()
                .map(Action.messagesUpdated)
        }
    }

    private static func isTranscriptMessage(_ message: Message) -> Bool {
        message.sentAt != nil || message.queueOrder == nil
    }

    private static func areMessagesInTranscriptOrder(
        _ lhs: Message,
        _ rhs: Message
    ) -> Bool {
        if lhs.sentAt != rhs.sentAt {
            switch (lhs.sentAt, rhs.sentAt) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
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

}

private actor MessagePersistencePipeline {
    private var confirmedMessagesBySession: [Session.ID: [Message]] = [:]

    func confirm(
        _ message: Message,
        sessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws {
        storeConfirmedMessage(message, sessionID: sessionID)

        let persistedMessage = try await database.write { database in
            if let existingMessage = try Message.find(message.id).fetchOne(database) {
                return existingMessage
            }
            try Message.insert { message }.execute(database)
            return message
        }
        storeConfirmedMessage(persistedMessage, sessionID: sessionID)
    }

    func apply(
        _ event: MessageSyncEvent,
        sessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws -> MessageSyncEvent {
        let persistedEvent: MessageSyncEvent
        if event.isSnapshot {
            let messageIDs = Set(event.messages.map(\.id))
            let confirmedMessages = confirmedMessagesBySession.removeValue(
                forKey: sessionID
            ) ?? []
            persistedEvent = .snapshot(
                event.messages
                    + confirmedMessages.filter { !messageIDs.contains($0.id) }
            )
        } else {
            persistedEvent = event
        }

        try await database.write { database in
            if persistedEvent.isSnapshot {
                let messageIDs = Set(persistedEvent.messages.map(\.id))
                let storedMessages = try Message
                    .where { $0.sessionID.eq(sessionID) }
                    .fetchAll(database)
                for message in storedMessages where !messageIDs.contains(message.id) {
                    try Message
                        .where {
                            $0.id.eq(message.id)
                                && $0.sessionID.eq(sessionID)
                        }
                        .delete()
                        .execute(database)
                }
            }

            for messageID in persistedEvent.deletedMessageIDs {
                try Message
                    .where {
                        $0.id.eq(messageID)
                            && $0.sessionID.eq(sessionID)
                    }
                    .delete()
                    .execute(database)
            }

            if !persistedEvent.messages.isEmpty {
                try Message.upsert { persistedEvent.messages }
                    .execute(database)
            }
        }
        return persistedEvent
    }

    private func storeConfirmedMessage(
        _ message: Message,
        sessionID: Session.ID
    ) {
        var messages = confirmedMessagesBySession[sessionID, default: []]
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        confirmedMessagesBySession[sessionID] = messages
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
    private static let reconnectingQueueSpacing: CGFloat = 12

    @Bindable var store: StoreOf<Chat>
    @State private var composerHeight: CGFloat = 0
    @State private var queuedMessagesHeight: CGFloat = 0
    @State private var reconnectingSize: CGSize = .zero
    let directoryName: String
    let firstQueuedRowFrameChanged: @MainActor (CGRect) -> Void

    init(
        store: StoreOf<Chat>,
        directoryName: String,
        firstQueuedRowFrameChanged: @escaping @MainActor (CGRect) -> Void = { _ in }
    ) {
        self.store = store
        self.directoryName = directoryName
        self.firstQueuedRowFrameChanged = firstQueuedRowFrameChanged
    }

    var body: some View {
        let queuedMessagesStore = store.scope(
            state: \.queuedMessages,
            action: \.queuedMessages
        )

        GeometryReader { proxy in
            let statusLayout = if queuedMessagesStore.isExpanded {
                AnyLayout(VStackLayout(spacing: 8))
            } else {
                // AnyLayout(ZStackLayout(alignment: .trailing))
                AnyLayout(HStackLayout(spacing: 0))
            }

            collectionView(
                bottomInset: bottomInset(
                    safeAreaBottom: proxy.safeAreaInsets.bottom,
                    queuedMessagesStore: queuedMessagesStore
                )
            )
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
            .overlay(alignment: .bottom) {
                bottomOverlay(
                    statusLayout: statusLayout,
                    queuedMessagesStore: queuedMessagesStore
                )
                .frame(height: proxy.size.height, alignment: .bottom)
                .clipped()
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
        .onChange(of: store.session.status) { _, status in
            store.send(.sessionStatusChanged(status))
        }
        .onChange(of: store.session.model) { _, model in
            store.send(.sessionModelChanged(model))
        }
        .onChange(of: store.session.isFastModeEnabled) { _, isFastModeEnabled in
            store.send(.sessionFastModeChanged(isFastModeEnabled ?? false))
        }
        .onChange(of: store.session.reasoningEffort) { _, reasoningEffort in
            store.send(.sessionReasoningEffortChanged(reasoningEffort))
        }
        .task(id: store.session.id) {
            await store.send(.task).finish()
        }
        .preferredColorScheme(.dark)
    }

    private func bottomOverlay(
        statusLayout: AnyLayout,
        queuedMessagesStore: StoreOf<QueuedMessages>
    ) -> some View {
        VStack(spacing: 8) {
            statusLayout {
                if store.connectionStatus != .connected {
                    reconnecting
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !queuedMessagesStore.displayedMessages.isEmpty {
                    QueuedMessagesView(
                        store: queuedMessagesStore,
                        firstRowFrameChanged: firstQueuedRowFrameChanged
                    )
                    .id(store.session.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        queuedMessagesHeight = height
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ChatComposer(
                store: store,
                queuedMessagesStore: queuedMessagesStore
            )
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    let animation: Animation? = if composerHeight == 0 {
                        nil
                    } else {
                        QueuedMessagesPresentation.disclosureAnimation
                    }

                    withAnimation(animation) {
                        composerHeight = height
                    }
                }
        }
        .animation(.default, value: store.connectionStatus)
        .animation(.default, value: queuedMessagesStore.displayedMessages)
        .animation(
            QueuedMessagesPresentation.disclosureAnimation,
            value: queuedMessagesStore.isEditing
        )
    }

    private var reconnecting: some View {
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
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { geometry in
            geometry.size
        } action: { size in
            reconnectingSize = size
        }
    }

    private func collectionView(bottomInset: CGFloat) -> some View {
        GeometryReader { proxy in
            ChatCollectionView(
                rows: store.rows ?? [],
                scrollToBottomRequest: store.scrollToBottomRequest,
                safeAreaInsets: EdgeInsets(
                    top: proxy.safeAreaInsets.top,
                    leading: proxy.safeAreaInsets.leading,
                    bottom: max(proxy.safeAreaInsets.bottom, bottomInset),
                    trailing: proxy.safeAreaInsets.trailing
                ),
                contentInsetAnimationDuration: QueuedMessagesPresentation.animationDuration,
                turnSummaryTapped: {
                    store.send(.turnSummaryTapped($0), animation: .default)
                }
            )
            // Draw beneath every bar and the keyboard; the proxy insets keep rows unobscured.
            .ignoresSafeArea(edges: [.top, .bottom])
        }
    }

    private func bottomInset(
        safeAreaBottom: CGFloat,
        queuedMessagesStore: StoreOf<QueuedMessages>
    ) -> CGFloat {
        let spacing: CGFloat = 8

        let queueHeight = if queuedMessagesStore.displayedMessages.isEmpty {
            CGFloat.zero
        } else {
            queuedMessagesHeight
        }
        let connectionHeight = if store.connectionStatus == .connected {
            CGFloat.zero
        } else {
            reconnectingSize.height
        }

        let statusHeight = if queuedMessagesStore.isExpanded,
                              queueHeight > 0,
                              connectionHeight > 0 {
            connectionHeight + spacing + queueHeight
        } else {
            max(connectionHeight, queueHeight)
        }

        return safeAreaBottom
            + composerHeight
            + (statusHeight > 0 ? spacing + statusHeight : 0)
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

private struct ChatComposer: View {
    @Bindable var store: StoreOf<Chat>
    @Bindable var queuedMessagesStore: StoreOf<QueuedMessages>

    var body: some View {
        let isSendInFlight: Bool = if queuedMessagesStore.isEditing {
            queuedMessagesStore.isEditInFlight
        } else {
            store.isMessageSendInFlight
        }

        ChatTextField(
            text: composerText,
            agentType: store.session.agentType,
            allowsAgentSwitching: store.allowsAgentSwitching,
            contextWindowUsage: store.contextWindowUsage,
            isFastModeEnabled: store.isFastModeEnabled,
            isEditingQueuedMessage: queuedMessagesStore.isEditing,
            isSendInFlight: isSendInFlight,
            isStopInFlight: store.isStopInFlight,
            isWorking: store.session.status == .working,
            selectedModel: $store.selectedModel,
            selectedReasoningEffort: store.selectedReasoningEffort,
            availableReasoningEfforts: store.availableReasoningEfforts,
            shouldFocusOnAppear: store.shouldFocusMessageField,
            onFastModeTapped: {
                store.send(.fastModeButtonTapped)
            },
            onCancelEditingTapped: {
                queuedMessagesStore.send(.cancelEditButtonTapped)
            },
            onSelectReasoningEffort: {
                store.send(.reasoningEffortSelected($0))
            },
            onSendTapped: {
                if queuedMessagesStore.isEditing {
                    queuedMessagesStore.send(.finishEditButtonTapped)
                } else {
                    store.send(.sendButtonTapped(.steer))
                }
            },
            onQueueTapped: {
                store.send(.sendButtonTapped(.queue))
            },
            onStopTapped: {
                store.send(.stopButtonTapped)
            }
        )
    }

    private var composerText: Binding<String> {
        if queuedMessagesStore.isEditing {
            $queuedMessagesStore.editDraft
        } else {
            Binding(store.$messageDraft)
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
        shouldCycleStatus: Bool = false,
        queuedMessageContents: [String] = [],
        isQueuePaused: Bool = false,
        isResumeInFlight: Bool = false
    ) {
        let content = try! ChatPreviewContent()
        var session = content.session
        session.queuePausedAt = isQueuePaused ? "2026-07-26T12:00:00Z" : nil
        session.status = .working

        let queuedMessages = queuedMessageContents.enumerated().map { offset, content in
            Message(
                id: "preview-queued-message-\(offset)",
                sessionID: session.id,
                role: .user,
                content: content,
                createdAt: Date(
                    timeIntervalSince1970: 1_790_000_000 + TimeInterval(offset)
                ),
                queueOrder: offset + 1
            )
        }
        let _ = try! prepareDependencies {
            try $0.bootstrapDatabase()
            try $0.defaultDatabase.write { db in
                try Message.upsert { content.messages + queuedMessages }
                    .execute(db)
            }
            $0.desktopClient.observeMessages = { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.snapshot([]))
                }
            }
            $0.desktopClient.resumeQueuedMessages = { _, _ in }
        }

        let (connectionStatus, store) = withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = status }
            var state = Chat.State(session: session)
            state.queuedMessages.isExpanded = !queuedMessages.isEmpty
            state.queuedMessages.isResumeInFlight = isResumeInFlight
            return (
                $connectionStatus,
                Store(initialState: state) {
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

#Preview("Queue · 1 short") {
    ChatPreview(
        status: .connected,
        queuedMessageContents: ["Run the tests."]
    )
}

#Preview("Queue · 5 mixed") {
    ChatPreview(
        status: .connected,
        queuedMessageContents: [
            "Run the tests.",
            "Fix the empty state spacing.",
            "Check whether reconnecting preserves the queued messages.",
            "Update the copy.",
            "Please review the entire queue flow and verify that long queued messages truncate cleanly without moving the action and reorder controls off screen.",
        ]
    )
}

#Preview("Queue resuming · 1 long") {
    ChatPreview(
        status: .connected,
        queuedMessageContents: [
            "Please verify that a long queued message truncates to one line while the fake resume request is in flight and its progress indicator is visible.",
        ],
        isQueuePaused: true,
        isResumeInFlight: true
    )
}

#Preview("Queue paused · 5 mixed") {
    ChatPreview(
        status: .connected,
        queuedMessageContents: [
            "Run the tests.",
            "Fix the empty state spacing.",
            "Check whether reconnecting preserves the queued messages.",
            "Update the copy.",
            "Please review the entire queue flow and verify that long queued messages truncate cleanly without moving the Resume button off screen.",
        ],
        isQueuePaused: true
    )
}
#endif
