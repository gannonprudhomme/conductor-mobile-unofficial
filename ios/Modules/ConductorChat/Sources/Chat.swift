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

        @Shared(.cloudConfiguration)
        var cloudConfiguration

        @Shared(.mobileModelSettingsOverride)
        var mobileModelSettingsOverride

        @Shared var messageDraft: String

        @FetchAll var messages: [Message]
        @FetchAll var fetchedDeliveryAttempts: [MessageDeliveryAttempt]
        @FetchOne var session: Session
        var deliveryAttempts: [MessageDeliveryAttempt] = []
        var queuedMessages: QueuedMessages.State
        var displayedSessionStatus: Session.Status
        var isFastModeEnabled: Bool
        var mutationRoute: WorkspaceMutationRoute?
        var source: WorkspaceSource
        var isEnqueueInFlight = false
        var isLoadingMessages = true
        var isMessageSnapshotEmpty = false
        var isStopInFlight = false
        var hasObservedSessionFastModeChange = false
        var hasObservedSessionModelChange = false
        var hasObservedSessionReasoningEffortChange = false
        var hasUserSelectedFastMode = false
        var hasUserSelectedModel = false
        var hasUserSelectedReasoningEffort = false
        var animatedScrollToBottomRequest = 0
        var scrollToBottomRequest = 0
        var shouldFocusMessageField = false

        var expandedSummaryIDs: Set<DisplayedChatRow.TurnSummary.ID> = []
        var reportedContextWindowTokenLimits: [Session.Model: Int] = [:]
        var messageIDToBubbleID: [Message.ID: UUID] = [:]
        var recentlyEnqueuedAttempt: MessageDeliveryAttempt?
        var selectedModel: Session.Model
        var selectedReasoningEffort: Session.ReasoningEffort?
        var workCycle = WorkCycle.idle(
            attemptID: nil,
            baselineTurnID: nil,
            correlatedTurnID: nil
        )

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
            !isLoadingMessages
                && isMessageSnapshotEmpty
                && queuedMessages.messages.isEmpty
                && !hasOptimisticMessages
        }

        var isCloudHosted: Bool {
            source == .cloud
        }

        var allowsAgentSwitching: Bool {
            !isLoadingMessages
                && isMessageSnapshotEmpty
                && queuedMessages.messages.isEmpty
                && !isMessageSendInFlight
                && !displayedDeliveryAttempts.contains {
                    $0.messageMode == .sent
                        && $0.deliveryState != .rejected
                        && (
                            $0.deliveryState != .acknowledged
                                || !hasCanonicalMessage(for: $0)
                        )
                }
        }

        var configurationInteractionMode: ModelConfigurationInteractionMode {
            if mutationRoute.capabilities.canConfigureMessages {
                .editable
            } else if source == .cloud {
                .readOnlyInformational
            } else {
                .hidden
            }
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

        var hasOptimisticMessages: Bool {
            displayedDeliveryAttempts.contains {
                $0.messageMode == .sent
                    && (
                        $0.deliveryState != .acknowledged
                            || !hasCanonicalMessage(for: $0)
                    )
            }
        }

        var isMessageSendInFlight: Bool {
            isEnqueueInFlight
                || displayedDeliveryAttempts.contains { attempt in
                    attempt.deliveryState == .ready
                        || attempt.deliveryState == .dispatching
                }
        }

        var displayedDeliveryAttempts: [MessageDeliveryAttempt] {
            if let recentlyEnqueuedAttempt,
               !deliveryAttempts.contains(where: {
                   $0.attemptID == recentlyEnqueuedAttempt.attemptID
               }) {
                deliveryAttempts + [recentlyEnqueuedAttempt]
            } else {
                deliveryAttempts
            }
        }

        func hasCanonicalMessage(
            for attempt: MessageDeliveryAttempt
        ) -> Bool {
            messageIDToBubbleID.values.contains(attempt.attemptID)
        }

        mutating func beginSendCycle(attemptID: UUID) {
            workCycle = .working(
                attemptID: attemptID,
                baselineTurnID: turns?.last?.id,
                correlatedTurnID: nil
            )
        }

        mutating func endSendCycle(attemptID: UUID) {
            workCycle = switch workCycle {
            case let .idle(activeAttemptID, baselineTurnID, _)
                where activeAttemptID == attemptID:
                .idle(
                    attemptID: nil,
                    baselineTurnID: baselineTurnID,
                    correlatedTurnID: nil
                )
            case let .working(activeAttemptID, baselineTurnID, _)
                where activeAttemptID == attemptID:
                .idle(
                    attemptID: nil,
                    baselineTurnID: baselineTurnID,
                    correlatedTurnID: nil
                )
            case .idle, .working:
                workCycle
            }
        }

        mutating func initializeIdleBaseline() {
            guard case let .idle(attemptID, nil, correlatedTurnID) = workCycle else {
                return
            }
            workCycle = .idle(
                attemptID: attemptID,
                baselineTurnID: turns?.last?.id,
                correlatedTurnID: correlatedTurnID
            )
        }

        mutating func observeCorrelatedTurn(
            _ turnID: Turn.ID,
            attemptID: UUID
        ) {
            workCycle = switch workCycle {
            case let .idle(activeAttemptID, baselineTurnID, _)
                where activeAttemptID == attemptID:
                .idle(
                    attemptID: activeAttemptID,
                    baselineTurnID: baselineTurnID,
                    correlatedTurnID: turnID
                )
            case let .working(activeAttemptID, baselineTurnID, _)
                where activeAttemptID == attemptID:
                .working(
                    attemptID: activeAttemptID,
                    baselineTurnID: baselineTurnID,
                    correlatedTurnID: turnID
                )
            case let .idle(nil, _, correlatedTurnID):
                .idle(
                    attemptID: nil,
                    baselineTurnID: turnID,
                    correlatedTurnID: correlatedTurnID
                )
            case .idle, .working:
                workCycle
            }
        }

        mutating func sessionStatusChanged(_ sessionStatus: Session.Status) {
            let turns = turns ?? []
            workCycle = if sessionStatus == .working {
                switch workCycle {
                case let .idle(
                    attemptID,
                    baselineTurnID,
                    correlatedTurnID
                ):
                    .working(
                        attemptID: attemptID,
                        baselineTurnID: baselineTurnID,
                        correlatedTurnID: correlatedTurnID
                    )
                case .working:
                    workCycle
                }
            } else {
                .idle(
                    attemptID: nil,
                    baselineTurnID: turns.last?.id,
                    correlatedTurnID: nil
                )
            }
            displayedSessionStatus = sessionStatus
            updateRows()
        }

        mutating func applySessionSnapshot(_ session: Session) {
            if displayedSessionStatus != session.status {
                sessionStatusChanged(session.status)
            }
            if !hasUserSelectedModel, selectedModel != session.model {
                hasObservedSessionModelChange = true
                selectedModel = session.model
            }
            let sessionFastMode = session.isFastModeEnabled ?? false
            if isFastModeEnabled != sessionFastMode {
                hasObservedSessionFastModeChange = true
                isFastModeEnabled = sessionFastMode
            }
            let previousReasoningEffort = selectedReasoningEffort
            if previousReasoningEffort != session.reasoningEffort {
                selectedReasoningEffort = session.reasoningEffort
                reconcileSelectedReasoningEffort()
            }
            if selectedReasoningEffort != previousReasoningEffort {
                hasObservedSessionReasoningEffortChange = true
            }
        }

        mutating func updateRows() {
            let turns = turns ?? []
            let isSessionWorking = displayedSessionStatus == .working
                || workCycle.isWorking
            let activeAttempt = workCycle.attemptID.flatMap { attemptID in
                displayedDeliveryAttempts.last {
                    $0.attemptID == attemptID
                }
            }
            let activeTurnID: Turn.ID? = switch workCycle {
            case .idle:
                nil
            case let .working(_, baselineTurnID, correlatedTurnID):
                if let correlatedTurnID,
                   turns.contains(where: { $0.id == correlatedTurnID }) {
                    correlatedTurnID
                } else if displayedSessionStatus == .working,
                          turns.last?.id != baselineTurnID {
                    turns.last?.id
                } else {
                    nil
                }
            }
            let optimisticRows = displayedDeliveryAttempts
                .filter {
                    $0.messageMode == .sent
                        && (
                            $0.deliveryState != .acknowledged
                                || !hasCanonicalMessage(for: $0)
                        )
                }
                .map { attempt -> (Turn.ID?, DisplayedChatRowWithPadding) in
                    let status: DisplayedChatRow.OptimisticMessage.Status
                    switch attempt.deliveryState {
                    case .accepted:
                        status = .acceptedAwaitingObservation
                    case .rejected:
                        status = .rejected
                    case .ready, .dispatching:
                        status = .sending
                    case .unknown:
                        status = .unconfirmed
                    case .acknowledged:
                        status = .acceptedAwaitingObservation
                    default:
                        status = .unconfirmed
                    }
                    return (
                        attempt.previousTurnID,
                        DisplayedChatRowWithPadding(
                            content: .optimisticMessage(
                                .init(
                                    id: attempt.attemptID,
                                    content: attempt.content,
                                    deliveryDetail: attempt.resultDetail,
                                    status: status
                                )
                            ),
                            topPadding: 24,
                            bottomPadding: 12
                        )
                    )
                }
            var rows = optimisticRows
                .filter { $0.0 == nil }
                .map(\.1)
            for turn in turns {
                rows.append(
                    contentsOf: [turn].flattenedChatRows(
                        activeTurnID: activeTurnID,
                        expandedSummaryIDs: expandedSummaryIDs
                    )
                )
                rows.append(
                    contentsOf: optimisticRows
                        .filter { $0.0 == turn.id }
                        .map(\.1)
                )
            }
            let existingTurnIDs = Set(turns.map(\.id))
            rows.append(
                contentsOf: optimisticRows
                    .filter { previousTurnID, _ in
                        previousTurnID.map { !existingTurnIDs.contains($0) } == true
                    }
                    .map(\.1)
            )
            if let progressIndex = rows.indices.last(where: {
                if case .turnInProgress = rows[$0].content {
                    true
                } else {
                    false
                }
            }), progressIndex != rows.index(before: rows.endIndex) {
                let progress = rows.remove(at: progressIndex)
                rows.append(progress)
            }
            if isSessionWorking, activeTurnID == nil {
                let progressID = activeAttempt?.attemptID.uuidString
                    ?? "\(sessionID):pending"
                rows.append(
                    DisplayedChatRowWithPadding(
                        content: .turnInProgress(
                            .init(
                                id: progressID,
                                startedAt: activeAttempt?.dispatchStartedAt
                                    ?? activeAttempt?.createdAt
                                    ?? session.updatedDate
                                    ?? turns.last?.startedAt
                                    ?? .now
                            )
                        ),
                        topPadding: 0,
                        bottomPadding: 0
                    )
                )
            }

            self.rows = rows
        }

        enum WorkCycle: Equatable {
            case idle(
                attemptID: UUID?,
                baselineTurnID: Turn.ID?,
                correlatedTurnID: Turn.ID?
            )
            case working(
                attemptID: UUID?,
                baselineTurnID: Turn.ID?,
                correlatedTurnID: Turn.ID?
            )

            var attemptID: UUID? {
                switch self {
                case let .idle(attemptID, _, _),
                     let .working(attemptID, _, _):
                    attemptID
                }
            }

            var isWorking: Bool {
                if case .working = self {
                    true
                } else {
                    false
                }
            }
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
            isCloudHosted: Bool = false,
            mutationRoute: WorkspaceMutationRoute? = nil,
            selectedModel: Session.Model? = nil,
            selectedReasoningEffort: Session.ReasoningEffort? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            @Shared(.messageDrafts) var messageDrafts
            self._messageDraft = $messageDrafts[draftFor: session.id]
            self.displayedSessionStatus = session.status
            self.workCycle = if session.status == .working {
                .working(
                    attemptID: nil,
                    baselineTurnID: nil,
                    correlatedTurnID: nil
                )
            } else {
                .idle(
                    attemptID: nil,
                    baselineTurnID: nil,
                    correlatedTurnID: nil
                )
            }
            self.isFastModeEnabled = session.isFastModeEnabled ?? false
            self.source = isCloudHosted ? .cloud : .desktop
            self.mutationRoute = mutationRoute
                ?? (isCloudHosted ? nil : .desktop)
            self.queuedMessages = QueuedMessages.State(
                session: session,
                mutationRoute: mutationRoute
                    ?? (isCloudHosted ? nil : .desktop)
            )
            self._session = FetchOne(
                wrappedValue: session,
                Session.find(session.id),
                animation: .default
            )
            self._messages = if isCloudHosted {
                FetchAll(
                    wrappedValue: messages,
                    CloudMessageMetadata.messages(sessionID: session.id)
                )
            } else {
                FetchAll(
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
                                // SQLite's default BINARY collation preserves the protocol's raw
                                // UTF-8 tie-break when timestamps match.
                                $0.id
                            )
                        }
                )
            }
            self._fetchedDeliveryAttempts = FetchAll(
                wrappedValue: [],
                MessageDeliveryAttempt
                    .where {
                        $0.canonicalSessionID.eq(session.id)
                    }
                    .order(by: \.createdAt)
            )
            self.hasUserSelectedModel = selectedModel != nil
            self.hasUserSelectedReasoningEffort = selectedReasoningEffort != nil
            self.selectedModel = selectedModel ?? session.model
            self.selectedReasoningEffort = selectedReasoningEffort ?? session.reasoningEffort
            self.shouldFocusMessageField = shouldFocusMessageField
            reconcileSelectedReasoningEffort()
        }

        mutating func reconcileSelectedReasoningEffort() {
            guard configurationInteractionMode == .editable else {
                return
            }
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
                && lhs.cloudConfiguration == rhs.cloudConfiguration
                && lhs.mobileModelSettingsOverride == rhs.mobileModelSettingsOverride
                && lhs.displayedSessionStatus == rhs.displayedSessionStatus
                && lhs.isFastModeEnabled == rhs.isFastModeEnabled
                && lhs.deliveryAttempts == rhs.deliveryAttempts
                && lhs.mutationRoute == rhs.mutationRoute
                && lhs.source == rhs.source
                && lhs.messageDraft == rhs.messageDraft
                && lhs.isEnqueueInFlight == rhs.isEnqueueInFlight
                && lhs.isLoadingMessages == rhs.isLoadingMessages
                && lhs.isMessageSnapshotEmpty == rhs.isMessageSnapshotEmpty
                && lhs.isStopInFlight == rhs.isStopInFlight
                && lhs.hasObservedSessionFastModeChange == rhs.hasObservedSessionFastModeChange
                && lhs.hasObservedSessionModelChange == rhs.hasObservedSessionModelChange
                && lhs.hasObservedSessionReasoningEffortChange
                    == rhs.hasObservedSessionReasoningEffortChange
                && lhs.hasUserSelectedFastMode == rhs.hasUserSelectedFastMode
                && lhs.hasUserSelectedModel == rhs.hasUserSelectedModel
                && lhs.hasUserSelectedReasoningEffort == rhs.hasUserSelectedReasoningEffort
                && lhs.animatedScrollToBottomRequest == rhs.animatedScrollToBottomRequest
                && lhs.scrollToBottomRequest == rhs.scrollToBottomRequest
                && lhs.shouldFocusMessageField == rhs.shouldFocusMessageField
                && lhs.expandedSummaryIDs == rhs.expandedSummaryIDs
                && lhs.reportedContextWindowTokenLimits
                    == rhs.reportedContextWindowTokenLimits
                && lhs.messageIDToBubbleID == rhs.messageIDToBubbleID
                && lhs.recentlyEnqueuedAttempt == rhs.recentlyEnqueuedAttempt
                && lhs.selectedModel == rhs.selectedModel
                && lhs.selectedReasoningEffort == rhs.selectedReasoningEffort
                && lhs.workCycle == rhs.workCycle
        }

        /// Read by ``WorkspaceChat`` to track the selected session.
        var sessionID: Session.ID { session.id }
    }

    public enum Action {
        case cloudConfigurationChanged(CloudConfiguration?)
        case configurationControlTapped(ModelConfigurationControl)
        case task
        case modelSettingsFetched(DesktopClient.ModelSettings)
        case fastModeButtonTapped
        case initialMessagesResponse(
            sessionID: Session.ID,
            messages: [Message]
        )
        case loadMessagesFailed(
            sessionID: Session.ID,
            error: any Error
        )
        case deliveryAttemptsUpdated([MessageDeliveryAttempt])
        case queuedDeliveryResult(
            attemptID: UUID,
            state: MessageDeliveryAttempt.State,
            detail: String
        )
        case messagesUpdated([Message])
        case queuedMessages(QueuedMessages.Action)
        case modelSelected(Session.Model)
        case reasoningEffortSelected(Session.ReasoningEffort)
        case sendButtonTapped(MessageSendMode)
        case enqueueMessageResponse(
            sessionID: Session.ID,
            submittedDraft: String,
            mode: MessageSendMode,
            result: Result<MessageDeliveryAttempt, any Error>
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
        case scrollDownButtonTapped
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.messageDeliveryOutbox) var messageDeliveryOutbox
    @Dependency(\.workspaceMutationClient) var workspaceMutationClient
    private let messagePersistence = MessagePersistencePipeline()

    init() { }

    public var body: some ReducerOf<Self> {
        Scope(state: \.queuedMessages, action: \.queuedMessages) {
            QueuedMessages()
        }

        Reduce { state, action in
            switch action {
            case .task:
                let cloudConfiguration = state.$cloudConfiguration
                let messageObservation: Effect<Action> = .merge(
                    observeMessages(state),
                    observePersistedMessages(state)
                )
                guard state.source == .desktop else {
                    return .merge(
                        .publisher {
                            cloudConfiguration.publisher
                                .removeDuplicates()
                                .dropFirst()
                                .map(Action.cloudConfigurationChanged)
                        },
                        messageObservation,
                        observeDeliveryAttempts(state)
                    )
                }
                return .merge(
                    .run { send in
                        guard let settings = try? await desktopClient.fetchModelSettings() else {
                            return
                        }
                        await send(.modelSettingsFetched(settings))
                    },
                    messageObservation,
                    observeDeliveryAttempts(state)
                )

            case let .cloudConfigurationChanged(configuration):
                guard state.source == .cloud else {
                    return .none
                }
                guard configuration != nil else {
                    return .cancel(id: CancelID.messageObservation)
                }
                return observeMessages(state)

            case let .modelSettingsFetched(settings):
                guard state.configurationInteractionMode == .editable else {
                    return .none
                }
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

            case let .modelSelected(model):
                guard state.mutationRoute.capabilities.canConfigureMessages else {
                    return .none
                }
                state.hasUserSelectedModel = true
                state.selectedModel = model
                state.reconcileSelectedReasoningEffort()
                return .none

            case .scrollDownButtonTapped:
                state.animatedScrollToBottomRequest &+= 1
                state.scrollToBottomRequest &+= 1
                return .none

            case .messagesUpdated(let messages):
                state.isMessageSnapshotEmpty = messages.isEmpty
                reconcileCanonicalMessages(messages, state: &state)
                if state.isLoadingMessages {
                    state.initializeIdleBaseline()
                }
                return .none

            case let .deliveryAttemptsUpdated(attempts):
                return handleDeliveryAttemptsUpdated(
                    attempts,
                    state: &state
                )

            case let .initialMessagesResponse(sessionID, messages):
                guard sessionID == state.sessionID else {
                    return .none
                }
                let transcriptMessages = if state.isCloudHosted {
                    messages
                } else {
                    messages
                        .filter(Self.isCompletedHistoryMessage)
                        .sorted(by: Self.isEarlierInCompletedHistory)
                }
                state.isMessageSnapshotEmpty = transcriptMessages.isEmpty
                reconcileCanonicalMessages(transcriptMessages, state: &state)
                state.initializeIdleBaseline()
                state.isLoadingMessages = false
                return .none

            case .sessionStatusChanged(let status):
                state.sessionStatusChanged(status)
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
                guard state.mutationRoute.capabilities.canConfigureMessages else {
                    return .none
                }
                state.hasUserSelectedFastMode = true
                state.isFastModeEnabled.toggle()
                return .none

            case let .reasoningEffortSelected(reasoningEffort):
                guard state.mutationRoute.capabilities.canConfigureMessages,
                      state.availableReasoningEfforts.contains(reasoningEffort) else {
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
                state.updateRows()
                return .none

            case let .sendButtonTapped(mode):
                let submittedDraft = state.messageDraft
                let message = submittedDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !message.isEmpty,
                      !state.isMessageSendInFlight,
                      let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canSend else {
                    return .none
                }

                state.isEnqueueInFlight = true
                state.scrollToBottomRequest &+= 1
                return .run {
                    [
                        model = state.selectedModel,
                        reasoningEffort = state.selectedReasoningEffort,
                        isFastModeEnabled = state.isFastModeEnabled,
                        mutationRoute,
                        previousTurnID = state.turns?.last?.id,
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                        submittedDraft,
                    ] send in
                    let result = await Result {
                        try await messageDeliveryOutbox.enqueue(
                            MessageDeliveryRequest(
                                route: mutationRoute,
                                canonicalWorkspaceID: workspaceID,
                                canonicalSessionID: sessionID,
                                content: message,
                                model: model,
                                isFastModeEnabled: isFastModeEnabled,
                                mode: mode,
                                reasoningEffort: reasoningEffort,
                                submittedDraft: submittedDraft,
                                previousTurnID: previousTurnID
                            )
                        )
                    }

                    await send(
                        .enqueueMessageResponse(
                            sessionID: sessionID,
                            submittedDraft: submittedDraft,
                            mode: mode,
                            result: result
                        )
                    )
                }

            case let .enqueueMessageResponse(
                sessionID,
                submittedDraft,
                mode,
                result
            ):
                // Send requests intentionally survive session navigation, so a late response
                // must not mutate the chat that replaced the request's originating session.
                guard sessionID == state.sessionID else {
                    return .none
                }

                state.isEnqueueInFlight = false
                switch result {
                case let .success(attempt):
                    state.recentlyEnqueuedAttempt = attempt
                    if mode == .sent, state.messageDraft == submittedDraft {
                        state.$messageDraft.withLock { $0 = "" }
                    }
                    if mode == .sent,
                       attempt.deliveryState != .rejected,
                       attempt.deliveryState != .unknown {
                        state.beginSendCycle(attemptID: attempt.attemptID)
                    }
                    state.updateRows()
                    return .none

                case .failure:
                    // Send errors are displayed by the parent ``WorkspaceChat``.
                    return .none
                }

            case .stopButtonTapped:
                guard state.session.status == .working,
                      !state.isStopInFlight,
                      let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canCancel else {
                    return .none
                }

                state.isStopInFlight = true
                return .run {
                    [
                        mutationRoute,
                        sessionID = state.session.id,
                        workspaceID = state.session.workspaceID,
                    ] send in
                    let result = await Result {
                        _ = try await workspaceMutationClient.cancelSession(
                            route: mutationRoute,
                            canonicalWorkspaceID: workspaceID,
                            canonicalSessionID: sessionID
                        )
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

            case let .loadMessagesFailed(sessionID, _):
                guard sessionID == state.sessionID else {
                    return .none
                }
                return .none

            case .configurationControlTapped,
                 .queuedDeliveryResult,
                 .queuedMessages:
                return .none
            }
        }
    }

    private func handleDeliveryAttemptsUpdated(
        _ attempts: [MessageDeliveryAttempt],
        state: inout State
    ) -> Effect<Action> {
        state.deliveryAttempts = attempts
        if let recent = state.recentlyEnqueuedAttempt,
           attempts.contains(where: { $0.attemptID == recent.attemptID }) {
            state.recentlyEnqueuedAttempt = nil
        }
        for attempt in attempts
        where attempt.messageMode == .sent
            && (
                attempt.deliveryState == .rejected
                    || attempt.deliveryState == .unknown
            ) {
            state.endSendCycle(attemptID: attempt.attemptID)
        }
        reconcileCanonicalMessages(Array(state.messages), state: &state)

        for attempt in attempts
        where attempt.messageMode == .queued
            && attempt.resultPresentedAt == nil {
            switch attempt.deliveryState {
            case .accepted, .acknowledged:
                if state.messageDraft == attempt.submittedDraft {
                    state.$messageDraft.withLock { $0 = "" }
                }
                return markDeliveryResultPresented(
                    attemptID: attempt.attemptID
                )

            case .rejected, .unknown:
                return .merge(
                    markDeliveryResultPresented(
                        attemptID: attempt.attemptID
                    ),
                    .send(
                        .queuedDeliveryResult(
                            attemptID: attempt.attemptID,
                            state: attempt.deliveryState,
                            detail: attempt.resultDetail
                                ?? "Delivery could not be determined."
                        )
                    )
                )

            case .ready, .dispatching:
                continue

            default:
                continue
            }
        }
        return .none
    }

    /// Starts the hosting-specific transcript observation used by the feature task.
    ///
    /// Desktop observations distinguish events already persisted by the lease-protected socket
    /// from legacy mocks that still require feature-owned persistence. Cloud observations have
    /// their own account-scoped cache contract.
    private func observeMessages(_ state: State) -> Effect<Action> {
        if state.source == .cloud {
            return observeCloudMessages(state)
        }
        return .run {
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
            } onValue: { observation in
                switch observation {
                case let .persisted(event):
                    // A usable cache and a cursorless recovery are both emitted as complete
                    // snapshots. Incremental frames must not dismiss loading on their own.
                    if isAwaitingInitialResponse, event.isSnapshot {
                        isAwaitingInitialResponse = false
                        await send(
                            .initialMessagesResponse(
                                sessionID: sessionID,
                                messages: event.messages
                            )
                        )
                    }

                case let .requiresPersistence(event):
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

                }
            } onFailure: { error in
                Logger.chat.error("Failed to load messages: \(error)")
                await send(
                    .loadMessagesFailed(
                        sessionID: sessionID,
                        error: error
                    )
                )
            }
        }
        .cancellable(id: CancelID.messageObservation, cancelInFlight: true)
    }

    private func observeCloudMessages(_ state: State) -> Effect<Action> {
        .run {
            [
                initiallyIsLoadingMessages = state.isLoadingMessages,
                sessionID = state.session.id,
            ] send in
            var isAwaitingInitialResponse = initiallyIsLoadingMessages
            do {
                let cache = try await database.write { database in
                    try CloudChatPersistence.reconcileDeliveryAttempts(
                        for: sessionID,
                        in: database
                    )
                    return try CloudChatPersistence.cachedTranscript(
                        for: sessionID,
                        in: database
                    )
                }
                if isAwaitingInitialResponse, cache.checkpoint != nil {
                    isAwaitingInitialResponse = false
                    await send(
                        .initialMessagesResponse(
                            sessionID: sessionID,
                            messages: cache.messages
                        )
                    )
                }
                let updates = cloudAPIClient.observeTranscript(
                    sessionID: cache.remoteSessionID,
                    checkpoint: cache.checkpoint
                )
                for try await update in updates {
                    let messages = try await database.write { database in
                        _ = try CloudChatPersistence.persist(update, in: database)
                        return try CloudMessageMetadata
                            .messages(sessionID: sessionID)
                            .fetchAll(database)
                    }
                    if isAwaitingInitialResponse, update.kind == .complete {
                        isAwaitingInitialResponse = false
                        await send(
                            .initialMessagesResponse(
                                sessionID: sessionID,
                                messages: messages
                            )
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                Logger.chat.error("Failed to load Cloud messages: \(error)")
                await send(
                    .loadMessagesFailed(
                        sessionID: sessionID,
                        error: error
                    )
                )
            }
        }
        .cancellable(id: CancelID.messageObservation, cancelInFlight: true)
    }

    private func observePersistedMessages(_ state: State) -> Effect<Action> {
        .publisher {
            state.$messages.publisher
                .removeDuplicates()
                .map(Action.messagesUpdated)
        }
    }

    private func observeDeliveryAttempts(_ state: State) -> Effect<Action> {
        .publisher {
            state.$fetchedDeliveryAttempts.publisher
                .removeDuplicates()
                .map(Action.deliveryAttemptsUpdated)
        }
    }

    private func markDeliveryResultPresented(
        attemptID: UUID
    ) -> Effect<Action> {
        .run { [attemptID, database] _ in
            try await database.write { database in
                guard let attempt = try MessageDeliveryAttempt
                    .find(attemptID)
                    .fetchOne(database),
                      attempt.resultPresentedAt == nil else {
                    return
                }
                try MessageDeliveryAttempt
                    .find(attemptID)
                    .update { $0.resultPresentedAt = #bind(Date()) }
                    .execute(database)
            }
        }
    }

    /// Mirrors the protocol's completed-history partition for legacy direct-persistence events.
    private static func isCompletedHistoryMessage(_ message: Message) -> Bool {
        !message.isQueued
    }

    /// Matches the desktop resume protocol's completed-history ordering exactly.
    private static func isEarlierInCompletedHistory(
        _ lhs: Message,
        _ rhs: Message
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return RawUTF8Key(lhs.id) < RawUTF8Key(rhs.id)
    }

    private func reconcileCanonicalMessages(
        _ messages: [Message],
        state: inout State
    ) {
        let userMessages = messages.filter { $0.role == .user }
        var aliases = state.messageIDToBubbleID
        for message in userMessages where aliases[message.id] == nil {
            guard let attempt = state.displayedDeliveryAttempts.first(where: {
                let attemptID = $0.attemptID.uuidString.lowercased()
                return $0.messageMode == .sent
                    && (
                        $0.canonicalMessageID == message.id
                            || (
                                $0.canonicalTurnID != nil
                                    && $0.canonicalTurnID == message.turnID
                            )
                            || message.sdkMessageID?.lowercased() == attemptID
                            || message.turnID?.lowercased() == attemptID
                    )
            }) else {
                continue
            }
            aliases[message.id] = attempt.attemptID
            if let turnID = message.turnID {
                state.observeCorrelatedTurn(
                    turnID,
                    attemptID: attempt.attemptID
                )
            }
        }

        state.messageIDToBubbleID = aliases
        state.turns = Turn.parse(
            messages: messages,
            reusing: state.turns ?? [],
            messageIDToBubbleID: aliases
        )
        state.updateReportedContextWindowTokenLimits()
        state.updateRows()
    }

    private enum CancelID: Hashable {
        case messageObservation
    }
}

private actor MessagePersistencePipeline {
    func apply(
        _ event: MessageSyncEvent,
        sessionID: Session.ID,
        database: any DatabaseWriter
    ) async throws -> MessageSyncEvent {
        try await database.write { database in
            if event.isSnapshot {
                let messageIDs = Set(event.messages.map(\.id))
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

            for messageID in event.deletedMessageIDs {
                try Message
                    .where {
                        $0.id.eq(messageID)
                            && $0.sessionID.eq(sessionID)
                    }
                    .delete()
                    .execute(database)
            }

            if !event.messages.isEmpty {
                try Message.upsert { event.messages }
                    .execute(database)
            }
            try MessageDeliveryAttempt.acknowledgeDesktopMessages(
                event.messages,
                sessionID: sessionID,
                in: database
            )
        }
        return event
    }
}

extension Dictionary where Key == Session.ID, Value == String {
    subscript(draftFor sessionID: Session.ID) -> String {
        get { self[sessionID, default: ""] }
        set { self[sessionID] = newValue.isEmpty ? nil : newValue }
    }
}

extension SharedKey where Self == FileStorageKey<[Session.ID: String]>.Default {
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
    private static let overlaySpacing: CGFloat = 8
    private static let scrollDownButtonContentSpacing: CGFloat = 16

    @Bindable var store: StoreOf<Chat>
    @State private var composerHeight: CGFloat = 0
    @State private var queuedMessagesHeight: CGFloat = 0
    @State private var reconnectingSize: CGSize = .zero
    @State private var scrollDownButtonHeight: CGFloat = 0
    @State private var shouldShowScrollDownButton = false
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
                AnyLayout(VStackLayout(spacing: Self.overlaySpacing))
            } else {
                AnyLayout(HStackLayout(spacing: 0))
            }

            collectionView(
                bottomInset: bottomInset(
                    safeAreaBottom: proxy.safeAreaInsets.bottom,
                    queuedMessagesStore: queuedMessagesStore
                )
            )
            .overlay {
                if store.isLoadingMessages && !store.hasOptimisticMessages {
                    ProgressView()
                        .progressViewStyle(.network)
                        .tint(.theme(.textSecondary))
                        .frame(width: 32, height: 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(.theme(.background))
                        .accessibilityIdentifier("chat.loading")
                } else if store.shouldShowEmptyChat {
                    EmptyChatView(directoryName: directoryName)
                        .accessibilityIdentifier("chat.empty")
                }
            }
            .background {
                Color.theme(.background)
                    .ignoresSafeArea()
            }
            .safeAreaBar(edge: .bottom, spacing: 4) {
                bottomOverlay(
                    statusLayout: statusLayout,
                    queuedMessagesStore: queuedMessagesStore
                )
                .fixedSize(
                    horizontal: false,
                    vertical: !queuedMessagesStore.isExpanded
                )
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
        .onChange(of: store.session.status) { _, status in
            store.send(
                .sessionStatusChanged(status),
                animation: .smooth(duration: 0.25)
            )
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
        VStack(spacing: Self.overlaySpacing) {
            statusLayout {
                if shouldShowScrollDownButton || shouldShowReconnecting {
                    controlRow(isExpanded: queuedMessagesStore.isExpanded)
                }

                if !store.isLoadingMessages {
                    queuedMessagesView(queuedMessagesStore)
                        .fixedSize(
                            horizontal: !queuedMessagesStore.isExpanded,
                            vertical: false
                        )
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
        .animation(.default, value: shouldShowScrollDownButton)
        .animation(.default, value: queuedMessagesStore.displayedMessages)
    }

    private func controlRow(isExpanded: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowScrollDownButton {
                    scrollDownButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Color.clear
                        .frame(height: 0)
                }
            }
            .frame(
                maxWidth: isExpanded ? .infinity : nil,
                alignment: .leading
            )

            Group {
                if shouldShowReconnecting {
                    reconnecting
                        .transition(.opacity)
                } else {
                    Color.clear
                        .frame(height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Color.clear
                .frame(maxWidth: isExpanded ? .infinity : 0)
                .frame(height: 0)
        }
        .padding(
            EdgeInsets(
                top: 0,
                leading: QueuedMessagesPresentation.horizontalPadding,
                bottom: 0,
                trailing: isExpanded
                    ? QueuedMessagesPresentation.horizontalPadding
                    : 0
            )
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func queuedMessagesView(
        _ queuedMessagesStore: StoreOf<QueuedMessages>
    ) -> some View {
        if store.mutationRoute.capabilities.canManageQueue,
           !queuedMessagesStore.displayedMessages.isEmpty {
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

    private var shouldShowReconnecting: Bool {
        !store.isCloudHosted && store.connectionStatus != .connected
    }

    private var scrollDownButton: some View {
        Button {
            store.send(.scrollDownButtonTapped)
        } label: {
            Label {
                Text("Scroll down")
            } icon: {
                LucideIcon(Lucide.arrowDown, size: 20, relativeTo: .body)
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
        .accessibilityLabel("Scroll down")
        .accessibilityIdentifier("chat.scroll-down")
        .tint(.theme(.foreground))
        .glassEffect(
            .clear
                .tint(.theme(.background).opacity(0.75))
                .interactive(),
            in: .circle
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            scrollDownButtonHeight = height
        }
    }

    private func collectionView(bottomInset: CGFloat) -> some View {
        GeometryReader { proxy in
            ChatCollectionView(
                rows: store.rows ?? [],
                animatedScrollToBottomRequest: store.animatedScrollToBottomRequest,
                scrollToBottomRequest: store.scrollToBottomRequest,
                safeAreaInsets: EdgeInsets(
                    top: proxy.safeAreaInsets.top,
                    leading: proxy.safeAreaInsets.leading,
                    bottom: max(proxy.safeAreaInsets.bottom, bottomInset),
                    trailing: proxy.safeAreaInsets.trailing
                ),
                contentInsetAnimationDuration: QueuedMessagesPresentation.animationDuration,
                scrollDownButtonVisibilityChanged: {
                    shouldShowScrollDownButton = $0
                },
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
        let queueHeight = if store.isLoadingMessages
            || queuedMessagesStore.displayedMessages.isEmpty {
            CGFloat.zero
        } else {
            queuedMessagesHeight
        }
        let buttonHeight = if shouldShowScrollDownButton {
            scrollDownButtonHeight
        } else {
            CGFloat.zero
        }
        let connectionHeight = if shouldShowReconnecting {
            reconnectingSize.height
        } else {
            CGFloat.zero
        }

        let controlHeight = max(buttonHeight, connectionHeight)
        let statusHeight = if queuedMessagesStore.isExpanded {
            controlHeight
                + queueHeight
                + (
                    controlHeight > 0 && queueHeight > 0
                        ? Self.overlaySpacing
                        : 0
                )
        } else {
            max(max(buttonHeight, queueHeight), connectionHeight)
        }
        let statusSpacing = statusHeight > 0
            ? Self.overlaySpacing
            : 0
        let contentSpacing = shouldShowScrollDownButton
            ? Self.scrollDownButtonContentSpacing
            : 0

        return safeAreaBottom + composerHeight
            + statusSpacing + statusHeight
            + contentSpacing
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
            allowsAgentSwitching: store.mutationRoute.capabilities
                .canConfigureMessages && store.allowsAgentSwitching,
            configurationInteractionMode: store.configurationInteractionMode,
            contextWindowUsage: store.contextWindowUsage,
            allowsQueue: store.mutationRoute.capabilities.canManageQueue,
            isFastModeEnabled: store.isFastModeEnabled,
            isEditingQueuedMessage: queuedMessagesStore.isEditing,
            isSendInFlight: isSendInFlight,
            isStopInFlight: store.isStopInFlight,
            isWorking: store.session.status == .working,
            selectedModel: store.selectedModel,
            selectedReasoningEffort: store.selectedReasoningEffort,
            availableReasoningEfforts: store.availableReasoningEfforts,
            shouldFocusOnAppear: store.shouldFocusMessageField,
            onFastModeTapped: {
                store.send(.fastModeButtonTapped)
            },
            onCancelEditingTapped: {
                queuedMessagesStore.send(.cancelEditButtonTapped)
            },
            onConfigurationControlTapped: {
                store.send(.configurationControlTapped($0))
            },
            onSelectModel: {
                store.send(.modelSelected($0))
            },
            onSelectReasoningEffort: {
                store.send(.reasoningEffortSelected($0))
            },
            onSendTapped: {
                if queuedMessagesStore.isEditing {
                    queuedMessagesStore.send(.finishEditButtonTapped)
                } else {
                    store.send(
                        .sendButtonTapped(.sent),
                        animation: .smooth(duration: 0.25)
                    )
                }
            },
            onQueueTapped: {
                store.send(.sendButtonTapped(.queued))
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
                    continuation.yield(.persisted(.snapshot([])))
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
