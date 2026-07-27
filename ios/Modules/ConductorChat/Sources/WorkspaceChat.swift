//
//  WorkspaceChat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Combine
import ComposableArchitecture
import SharedConductorData
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import Logging
import Sharing
import SQLiteData
import SwiftUI

/// A wrapper over ``Chat`` which enables switch between sessions for this workspace
@Reducer
public struct WorkspaceChat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?

        @Shared var outbox: MessageOutbox

        // TODO: Ideally this would be non-nil but couldn't figure out a good way to achieve it
        var chat: Chat.State?

        /// We want to switch to the active session if our local cached data is out of date and we get
        /// and updated active_session from the remote.
        ///
        /// However we want to prevent that from overriding a local switch from the user
        var hasUserSelectedSession = false
        var isCreatingSession = false
        var isRenamingBranch = false
        var isLoadingSessions = true
        var branchNameDraft = ""
        var hasPersistedInitialSessionSnapshot = false
        /// Cleared once observation identifies a session created after this snapshot.
        var sessionIDsBeforeCreation: Set<Session.ID>?
        var sessionIDAwaitingObservation: Session.ID?
        var bubbleIDAwaitingRetryConfirmation: UUID?
        var hasNormalizedRestoredOutbox = false
        var canonicalMessageIDsBySession: [Session.ID: Set<Message.ID>] = [:]
        var messageIDToBubbleID: [Message.ID: UUID] = [:]

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]
        @FetchOne public var workspaceWithRepository: WorkspaceWithRepository

        public init(
            workspaceWithRepository: WorkspaceWithRepository,
            outbox: Shared<MessageOutbox> = Shared(.messageOutbox),
            selectedModel: Session.Model? = nil,
            shouldFocusMessageField: Bool = false,
            creationPromptFailureMessage: String? = nil
        ) {
            self._outbox = outbox
            let workspace = workspaceWithRepository.workspace
            self._workspaceWithRepository = FetchOne(
                wrappedValue: workspaceWithRepository,
                WorkspaceWithRepository.all(workspaceID: workspace.id),
                animation: .default
            )

            self.chat = nil

            self._archivedSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and($0.isHidden) }
                    .order { $0.updatedAt.desc() },
                animation: .default
            )

            let activeSessions = FetchAll(
                Session
                    .where { $0.workspaceID.eq(workspace.id).and(!$0.isHidden) }
                    .order(by: \.createdAt),
                animation: .default
            )

            self._activeSessions = activeSessions

            let session = self.activeSessions.first {
                $0.id == workspace.activeSessionID
            } ?? self.activeSessions.first

            self.chat = session.map {
                Chat.State(
                    session: $0,
                    outbox: self.$outbox,
                    selectedModel: selectedModel,
                    shouldFocusMessageField: shouldFocusMessageField
                )
            }
            if let creationPromptFailureMessage {
                self.destination = .alert(
                    .creationPromptFailed(message: creationPromptFailureMessage)
                )
            }
        }

        public var workspace: Workspace {
            workspaceWithRepository.workspace
        }

        var canRenameBranch: Bool {
            let branch = branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !isRenamingBranch && !branch.isEmpty && branch != workspace.branch
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)
        case archivedSessions(ArchivedSessions)
        case renameBranch

        public enum Alert: Equatable {
            case confirmUnknownRetry
            case retryOutboxSave
        }
    }

    public enum Action: BindableAction {
        case activeSessionIDChanged(Session.ID?)
        case archiveWorkspaceButtonTapped
        case archiveWorkspaceResponse(Result<Void, any Error>)
        case archivedSessionsButtonTapped
        case binding(BindingAction<State>)
        case chat(Chat.Action)
        case createSessionButtonTapped
        case createSessionResponse(Result<Session, any Error>)
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsResponse(Result<[Session], any Error>)
        case messageSendResponse(SendAddress, DesktopClient.MessageDeliveryResult)
        case outboxSaveFailed(String)
        case renameBranchButtonTapped
        case renameBranchResponse(Result<Void, any Error>)
        case renameBranchSubmitted
        case stagedSendSuperseded(SendAddress)
        case stagedSendSaveFailed(SendAddress, isInitial: Bool, message: String)
        case sessionSnapshotPersisted
        case sessionButtonTapped(Session)
        case task
        case workspaceMutationFailed(any Error)
        case workspaceMutationUsedSQLiteFallback
        case workspacePinnedButtonTapped
        case workspaceStatusButtonTapped(Workspace.Status)
        case workspaceUnreadButtonTapped

        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case workspaceArchived
        }
    }

    public struct SendAddress: Equatable, Sendable {
        let workspaceID: Workspace.ID
        let sessionID: Session.ID
        let bubbleID: UUID
        let attemptID: UUID
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date.now) var now
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.uuid) var uuid

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                let workspace = state.$workspaceWithRepository
                let normalization = normalizeRestoredOutbox(state: &state)
                // The workspace and sessions arrive through independent sockets. Reconcile when
                // either one changes so an active-session-only update cannot leave chat stale.
                return .merge(
                    .publisher {
                        workspace.publisher
                            .map(\.workspace.activeSessionID)
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.activeSessionIDChanged)
                    },
                    observeSessions(workspaceID: state.workspace.id),
                    normalization
                )

            case let .activeSessionIDChanged(activeSessionID):
                // The workspace and session snapshots are persisted independently. Do not let a
                // workspace update clear or replace the chat while SQLite is still catching up.
                let activeSession = state.activeSessions.first {
                    $0.id == activeSessionID
                }
                guard !state.hasUserSelectedSession,
                      let activeSessionID,
                      let activeSession,
                      state.chat?.sessionID != activeSessionID else {
                    return .none
                }
                state.chat = Chat.State(
                    session: activeSession,
                    outbox: state.$outbox
                )
                refreshCurrentChat(state: &state)
                return .none

            case .archiveWorkspaceButtonTapped:
                return .run { [workspaceID = state.workspace.id] send in
                    await send(
                        .archiveWorkspaceResponse(
                            Result {
                                try await desktopClient.archiveWorkspace(workspaceID: workspaceID)
                            }
                        )
                    )
                }

            case .archiveWorkspaceResponse(.success):
                return .send(.delegate(.workspaceArchived))

            case let .archiveWorkspaceResponse(.failure(error)):
                Logger.chat.error("Failed to archive workspace: \(error)")
                state.destination = .alert(
                    .failedToArchiveWorkspace(message: error.localizedDescription)
                )
                return .none

            case .archivedSessionsButtonTapped:
                state.destination = .archivedSessions(
                    ArchivedSessions.State(
                        workspaceID: state.workspace.id,
                        sessions: state.archivedSessions
                    )
                )
                return .none

            case .renameBranchButtonTapped:
                state.branchNameDraft = state.workspace.branch ?? ""
                state.destination = .renameBranch
                return .none

            case .renameBranchSubmitted:
                guard state.canRenameBranch else {
                    return .none
                }

                let branch = state.branchNameDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                state.branchNameDraft = branch
                state.destination = nil
                state.isRenamingBranch = true
                return .run { [workspaceID = state.workspace.id, branch] send in
                    await send(
                        .renameBranchResponse(
                            Result {
                                try await desktopClient.renameWorkspaceBranch(
                                    workspaceID: workspaceID,
                                    branch: branch
                                )
                            }
                        )
                    )
                }

            case .renameBranchResponse(.success):
                state.isRenamingBranch = false
                return .none

            case let .renameBranchResponse(.failure(error)):
                Logger.chat.error("Failed to rename branch: \(error)")
                state.isRenamingBranch = false
                state.destination = .alert(
                    .failedToRenameBranch(message: error.localizedDescription)
                )
                return .none

            case .createSessionButtonTapped:
                guard state.activeSessions.count < 5 else {
                    state.destination = .alert(.maximumTabsReached)
                    return .none
                }
                guard !state.isCreatingSession else {
                    return .none
                }

                state.isCreatingSession = true
                state.sessionIDsBeforeCreation = Set(state.activeSessions.map(\.id))
                return .run { [workspaceID = state.workspace.id] send in
                    await send(
                        .createSessionResponse(
                            Result {
                                try await desktopClient.createSession(workspaceID: workspaceID)
                            }
                        )
                    )
                }

            case let .createSessionResponse(.success(session)):
                let hasObservedSession = state.sessionIDsBeforeCreation == nil
                state.hasUserSelectedSession = true
                state.isCreatingSession = false
                state.sessionIDAwaitingObservation = hasObservedSession ? nil : session.id
                state.sessionIDsBeforeCreation = nil
                if state.chat?.sessionID != session.id {
                    state.chat = Chat.State(
                        session: session,
                        outbox: state.$outbox,
                        shouldFocusMessageField: true
                    )
                    refreshCurrentChat(state: &state)
                }
                return .none

            case let .createSessionResponse(.failure(error)):
                Logger.chat.error("Failed to create session: \(error)")
                state.isCreatingSession = false
                state.sessionIDsBeforeCreation = nil
                state.destination = .alert(
                    .failedToCreateSession(message: error.localizedDescription)
                )
                return .none

            case let .loadSessionsResponse(.success(sessions)):
                if let sessionIDsBeforeCreation = state.sessionIDsBeforeCreation,
                   let createdSession = sessions.last(where: {
                       !sessionIDsBeforeCreation.contains($0.id) && !$0.isHidden
                   }) {
                    state.hasUserSelectedSession = true
                    state.sessionIDsBeforeCreation = nil
                    state.chat = Chat.State(
                        session: createdSession,
                        outbox: state.$outbox,
                        shouldFocusMessageField: true
                    )
                    refreshCurrentChat(state: &state)
                }
                let didObserveAwaitedSession = sessions.contains {
                    $0.id == state.sessionIDAwaitingObservation
                }
                if didObserveAwaitedSession {
                    state.sessionIDAwaitingObservation = nil
                }
                state.chat = Self.selectedChat(
                    afterReceiving: sessions,
                    currentChat: state.chat,
                    workspaceActiveSessionID: state.workspace.activeSessionID,
                    hasUserSelectedSession: state.hasUserSelectedSession,
                    sessionIDAwaitingObservation: state.sessionIDAwaitingObservation,
                    outbox: state.$outbox,
                    messageIDToBubbleID: state.messageIDToBubbleID
                )
                state.isLoadingSessions = false
                return .none

            case let .loadSessionsResponse(.failure(error)):
                Logger.chat.error("Failed to load sessions: \(error)")
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadSessions(message: error.localizedDescription)
                )
                return .none

            case .sessionSnapshotPersisted:
                state.hasPersistedInitialSessionSnapshot = true
                return .none

            case .chat(.sendButtonTapped):
                guard let chat = state.chat else {
                    return .none
                }
                guard canStageSend(state: &state) else {
                    return .none
                }
                let rawDraft = chat.messageDraft
                let content = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty, !chat.isMessageSendInFlight else {
                    return .none
                }

                let address = SendAddress(
                    workspaceID: chat.session.workspaceID,
                    sessionID: chat.session.id,
                    bubbleID: uuid(),
                    attemptID: uuid()
                )
                let precedingBubbleID = state.outbox[
                    address.workspaceID,
                    address.sessionID
                ].last?.bubbleID
                let bubble = MessageOutbox.Bubble(
                    bubbleID: address.bubbleID,
                    content: content,
                    createdAt: now,
                    isFastModeEnabled: chat.isFastModeEnabled,
                    model: chat.selectedModel,
                    precedingBubbleID: precedingBubbleID,
                    precedingTurnID: chat.turns?.last?.id,
                    attempts: [
                        .init(attemptID: address.attemptID, state: .sending),
                    ]
                )
                state.$outbox.withLock { outbox in
                    var bubbles = outbox[address.workspaceID, address.sessionID]
                    bubbles.append(bubble)
                    outbox[address.workspaceID, address.sessionID] = bubbles
                }
                let outboxSnapshot = state.outbox
                state.chat?.updateRows(
                    sessionStatus: chat.session.status,
                    outbox: outboxSnapshot
                )
                state.chat?.scrollToBottomRequest &+= 1
                return performStagedSend(
                    address: address,
                    isInitial: true,
                    rawDraft: rawDraft,
                    draft: chat.$messageDraft,
                    bubble: bubble,
                    outbox: state.$outbox
                )

            case let .chat(.retryButtonTapped(bubbleID)):
                guard let chat = state.chat else {
                    return .none
                }
                let bubble = state.outbox[chat.session.workspaceID, chat.session.id]
                    .first { $0.bubbleID == bubbleID }
                guard let bubble,
                      bubble.canRetry,
                      !chat.isMessageSendInFlight else {
                    return .none
                }
                let hasUnknownAttempt = bubble.attempts.contains { $0.state == .unknown }
                if hasUnknownAttempt {
                    state.bubbleIDAwaitingRetryConfirmation = bubbleID
                    state.destination = .alert(.confirmUnknownRetry)
                    return .none
                }
                return stageRetry(bubbleID: bubbleID, state: &state)

            case .destination(.presented(.alert(.confirmUnknownRetry))):
                // TODO: Revisit the unknown-retry UX when Conductor supports idempotent sends.
                guard let bubbleID = state.bubbleIDAwaitingRetryConfirmation else {
                    return .none
                }
                state.bubbleIDAwaitingRetryConfirmation = nil
                return stageRetry(bubbleID: bubbleID, state: &state)

            case .destination(.presented(.alert(.retryOutboxSave))):
                guard state.$outbox.loadError == nil else {
                    return .none
                }
                return saveOutbox(state.$outbox)

            case let .stagedSendSaveFailed(address, isInitial, message):
                guard state.$outbox.loadError == nil else {
                    state.destination = .alert(.outboxUnavailable(message: message))
                    return .none
                }
                var didRemoveAttempt = false
                state.$outbox.withLock { outbox in
                    var bubbles = outbox[address.workspaceID, address.sessionID]
                    let bubbleIndex = bubbles.firstIndex {
                        $0.bubbleID == address.bubbleID
                    }
                    guard let bubbleIndex else {
                        return
                    }
                    if isInitial {
                        bubbles.remove(at: bubbleIndex)
                        didRemoveAttempt = true
                    } else {
                        let previousAttemptCount = bubbles[bubbleIndex].attempts.count
                        bubbles[bubbleIndex].attempts.removeAll {
                            $0.attemptID == address.attemptID && $0.state == .sending
                        }
                        didRemoveAttempt =
                            bubbles[bubbleIndex].attempts.count < previousAttemptCount
                    }
                    outbox[address.workspaceID, address.sessionID] = bubbles
                }
                if didRemoveAttempt, state.chat?.sessionID == address.sessionID {
                    _ = reconcileCanonicalMessages(
                        Array(state.chat?.messages ?? []),
                        state: &state,
                        refreshingRows: true
                    )
                }
                return .send(.outboxSaveFailed(message))

            case let .stagedSendSuperseded(address):
                guard state.$outbox.loadError == nil else {
                    state.destination = .alert(
                        .outboxUnavailable(message: "The message outbox could not be loaded.")
                    )
                    return .none
                }
                var didRemoveAttempt = false
                state.$outbox.withLock { outbox in
                    var bubbles = outbox[address.workspaceID, address.sessionID]
                    let bubbleIndex = bubbles.firstIndex {
                        $0.bubbleID == address.bubbleID
                    }
                    guard let bubbleIndex else {
                        return
                    }
                    let hasAcceptedAttempt = bubbles[bubbleIndex].attempts.contains {
                        $0.attemptID != address.attemptID && $0.state.isAccepted
                    }
                    let attemptIndex = bubbles[bubbleIndex].attempts.firstIndex {
                        $0.attemptID == address.attemptID && $0.state == .sending
                    }
                    guard hasAcceptedAttempt, let attemptIndex else {
                        return
                    }
                    bubbles[bubbleIndex].attempts.remove(at: attemptIndex)
                    outbox[address.workspaceID, address.sessionID] = bubbles
                    didRemoveAttempt = true
                }
                guard didRemoveAttempt else {
                    return .none
                }
                if state.chat?.sessionID == address.sessionID {
                    _ = reconcileCanonicalMessages(
                        Array(state.chat?.messages ?? []),
                        state: &state
                    )
                }
                refreshCurrentChat(state: &state)
                return saveOutbox(state.$outbox)

            case let .messageSendResponse(address, result):
                guard state.$outbox.loadError == nil else {
                    state.destination = .alert(
                        .outboxUnavailable(message: "The message outbox could not be loaded.")
                    )
                    return .none
                }
                var didTransition = false
                state.$outbox.withLock { outbox in
                    var bubbles = outbox[address.workspaceID, address.sessionID]
                    let bubbleIndex = bubbles.firstIndex {
                        $0.bubbleID == address.bubbleID
                    }
                    guard let bubbleIndex else {
                        return
                    }
                    let attemptIndex = bubbles[bubbleIndex].attempts.firstIndex {
                        $0.attemptID == address.attemptID && $0.state == .sending
                    }
                    guard let attemptIndex else {
                        return
                    }
                    bubbles[bubbleIndex].attempts[attemptIndex].state = switch result {
                    case .accepted(let messageID):
                        .accepted(messageID: messageID)
                    case .unknown:
                        .unknown
                    case .rejected:
                        .rejected
                    }
                    outbox[address.workspaceID, address.sessionID] = bubbles
                    didTransition = true
                }
                guard didTransition else {
                    return .none
                }
                if state.chat?.sessionID == address.sessionID {
                    _ = reconcileCanonicalMessages(
                        Array(state.chat?.messages ?? []),
                        state: &state
                    )
                }
                refreshCurrentChat(state: &state)
                return saveOutbox(state.$outbox)

            case let .chat(.messagesUpdated(messages)):
                retainCanonicalMessageIDs(messages, state: &state)
                let didMutateOutbox = reconcileCanonicalMessages(messages, state: &state)
                return didMutateOutbox ? saveOutbox(state.$outbox) : .none

            case let .chat(.initialMessagesResponse(sessionID, messages)):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                retainCanonicalMessageIDs(messages, state: &state)
                let didMutateOutbox = reconcileCanonicalMessages(messages, state: &state)
                return .merge(
                    markWorkspaceReadIfNeeded(
                        state,
                        selectedSession: state.chat?.session
                    ),
                    didMutateOutbox ? saveOutbox(state.$outbox) : .none
                )

            case let .outboxSaveFailed(message):
                state.destination = .alert(.outboxSaveFailed(message: message))
                return .none

            case let .chat(.loadMessagesFailed(error)):
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadMessages(message: error.localizedDescription)
                )
                return .none

            case let .chat(.stopSessionResponse(sessionID, .failure(error))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                // Observation can receive the canonical stopped session before a delayed
                // POST failure, so do not report a stop failure once it is no longer working.
                guard state.chat?.session.status == .working else {
                    return .none
                }

                Logger.chat.error("Failed to stop session: \(error)")
                state.destination = .alert(
                    .failedToStopSession(message: error.localizedDescription)
                )
                return .none

            case let .sessionButtonTapped(session):
                /// Session button was tapped, don't let a new active session switch it for the lifetime of this
                state.hasUserSelectedSession = true
                state.sessionIDAwaitingObservation = nil
                guard state.chat?.sessionID != session.id else {
                    return .none
                }
                state.chat = Chat.State(session: session, outbox: state.$outbox)
                refreshCurrentChat(state: &state)
                return .none

            case let .workspaceMutationFailed(error):
                state.destination = .alert(
                    .failedToUpdateWorkspace(message: error.localizedDescription)
                )
                return .none

            case .workspaceMutationUsedSQLiteFallback:
                state.destination = .alert(.workspaceMutationUsedSQLiteFallback)
                return .none

            case .workspacePinnedButtonTapped:
                let item = state.workspaceWithRepository
                let isPinned = item.workspace.pinnedAt == nil
                let previousPinnedAt = item.workspace.pinnedAt
                let pinnedAt = isPinned ? now.ISO8601Format() : nil

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.pinnedAt = #bind(pinnedAt) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.pinnedAt == pinnedAt
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.pinnedAt = #bind(previousPinnedAt) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspacePinned(
                        workspaceID: item.id,
                        isPinned: isPinned
                    )
                }

            case let .workspaceStatusButtonTapped(status):
                let item = state.workspaceWithRepository
                guard item.workspace.status != status else {
                    return .none
                }
                let previousManualStatus = item.workspace.manualStatus

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.manualStatus = #bind(status.rawValue) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.manualStatus == status.rawValue
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.manualStatus = #bind(previousManualStatus) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspaceStatus(
                        workspaceID: item.id,
                        status: status
                    )
                }

            case .workspaceUnreadButtonTapped:
                let item = state.workspaceWithRepository
                let isUnread = (item.workspace.unread ?? 0) == 0
                let previousUnread = item.workspace.unread
                let unread = isUnread ? 1 : 0

                return updateWorkspace {
                    try await database.write { db in
                        try Workspace
                            .find(item.id)
                            .update { $0.unread = #bind(unread) }
                            .execute(db)
                    }
                } rollback: {
                    try await database.write { db in
                        guard let workspace = try Workspace.find(item.id).fetchOne(db),
                              workspace.unread == unread
                        else {
                            return
                        }

                        try Workspace
                            .find(item.id)
                            .update { $0.unread = #bind(previousUnread) }
                            .execute(db)
                    }
                } operation: {
                    try await desktopClient.setWorkspaceUnread(
                        workspaceID: item.id,
                        isUnread: isUnread
                    )
                }

            case .binding, .chat, .delegate, .destination:
                return .none

            }
        }
        .ifLet(\.chat, action: \.chat) {
            Chat()
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func updateWorkspace(
        _ optimisticUpdate: @escaping @Sendable () async throws -> Void,
        rollback: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async throws -> UIHookMutationPath
    ) -> Effect<Action> {
        .run { send in
            do {
                try await optimisticUpdate()
            } catch {
                Logger.chat.error("Failed to optimistically update workspace: \(error)")
                await send(.workspaceMutationFailed(error))
                return
            }

            do {
                if try await operation() == .sqliteFallback {
                    await send(.workspaceMutationUsedSQLiteFallback)
                }
            } catch let mutationError {
                do {
                    try await rollback()
                } catch {
                    Logger.chat.error("Failed to roll back workspace update: \(error)")
                }

                Logger.chat.error("Failed to update workspace: \(mutationError)")
                await send(.workspaceMutationFailed(mutationError))
            }
        }
    }

    private func canStageSend(state: inout State) -> Bool {
        if let error = state.$outbox.loadError {
            state.destination = .alert(
                .outboxUnavailable(message: error.localizedDescription)
            )
            return false
        }
        if let error = state.$outbox.saveError {
            state.destination = .alert(
                .outboxSaveFailed(message: error.localizedDescription)
            )
            return false
        }
        return true
    }

    private func normalizeRestoredOutbox(state: inout State) -> Effect<Action> {
        guard !state.hasNormalizedRestoredOutbox else {
            return .none
        }
        state.hasNormalizedRestoredOutbox = true
        guard state.$outbox.loadError == nil else {
            state.destination = .alert(
                .outboxUnavailable(
                    message: state.$outbox.loadError?.localizedDescription
                        ?? "The message outbox could not be loaded."
                )
            )
            return .none
        }

        let workspaceID = state.workspace.id
        state.$outbox.withLock { outbox in
            guard var sessions = outbox.workspaces[workspaceID] else {
                return
            }
            for sessionID in sessions.keys {
                guard var bubbles = sessions[sessionID] else {
                    continue
                }
                for bubbleIndex in bubbles.indices {
                    for attemptIndex in bubbles[bubbleIndex].attempts.indices
                    where bubbles[bubbleIndex].attempts[attemptIndex].state == .sending {
                        bubbles[bubbleIndex].attempts[attemptIndex].state = .unknown
                    }
                }
                sessions[sessionID] = bubbles
            }
            outbox.workspaces[workspaceID] = sessions
        }
        refreshCurrentChat(state: &state)
        // An explicit first save turns missing or empty storage into a valid v1 envelope.
        return saveOutbox(state.$outbox)
    }

    private func stageRetry(
        bubbleID: UUID,
        state: inout State
    ) -> Effect<Action> {
        guard canStageSend(state: &state),
              let chat = state.chat,
              !chat.isMessageSendInFlight else {
            return .none
        }
        let workspaceID = chat.session.workspaceID
        let sessionID = chat.session.id
        let attemptID = uuid()
        var stagedBubble: MessageOutbox.Bubble?
        state.$outbox.withLock { outbox in
            var bubbles = outbox[workspaceID, sessionID]
            let bubbleIndex = bubbles.firstIndex {
                $0.bubbleID == bubbleID
            }
            guard let bubbleIndex else {
                return
            }
            guard bubbles[bubbleIndex].canRetry else {
                return
            }
            bubbles[bubbleIndex].attempts.append(
                .init(attemptID: attemptID, state: .sending)
            )
            stagedBubble = bubbles[bubbleIndex]
            outbox[workspaceID, sessionID] = bubbles
        }
        guard let stagedBubble else {
            return .none
        }

        let address = SendAddress(
            workspaceID: workspaceID,
            sessionID: sessionID,
            bubbleID: bubbleID,
            attemptID: attemptID
        )
        refreshCurrentChat(state: &state)
        state.chat?.scrollToBottomRequest &+= 1
        return performStagedSend(
            address: address,
            isInitial: false,
            rawDraft: nil,
            draft: nil,
            bubble: stagedBubble,
            outbox: state.$outbox
        )
    }

    private func performStagedSend(
        address: SendAddress,
        isInitial: Bool,
        rawDraft: String?,
        draft: Shared<String>?,
        bubble: MessageOutbox.Bubble,
        outbox: Shared<MessageOutbox>
    ) -> Effect<Action> {
        .run { send in
            do {
                if let error = outbox.loadError {
                    throw error
                }
                try await outbox.save()
            } catch {
                await send(
                    .stagedSendSaveFailed(
                        address,
                        isInitial: isInitial,
                        message: error.localizedDescription
                    )
                )
                return
            }

            let shouldSend = outbox.withLock { outbox in
                let persistedBubble = outbox[address.workspaceID, address.sessionID]
                    .first { $0.bubbleID == address.bubbleID }
                guard let persistedBubble else {
                    return false
                }
                let hasAcceptedAttempt = persistedBubble.attempts.contains {
                    $0.attemptID != address.attemptID && $0.state.isAccepted
                }
                guard !hasAcceptedAttempt else {
                    return false
                }
                return persistedBubble.attempts.contains {
                    $0.attemptID == address.attemptID && $0.state == .sending
                }
            }
            guard shouldSend else {
                await send(.stagedSendSuperseded(address))
                return
            }

            if let rawDraft, let draft {
                draft.withLock { draft in
                    if draft == rawDraft {
                        draft = ""
                    }
                }
            }
            let result = await desktopClient.sendMessage(
                workspaceID: address.workspaceID,
                sessionID: address.sessionID,
                message: bubble.content,
                model: bubble.model,
                isFastModeEnabled: bubble.isFastModeEnabled,
                attemptID: address.attemptID
            )
            await send(.messageSendResponse(address, result))
        }
    }

    private func saveOutbox(_ outbox: Shared<MessageOutbox>) -> Effect<Action> {
        .run { send in
            guard outbox.loadError == nil else {
                await send(
                    .outboxSaveFailed(
                        outbox.loadError?.localizedDescription
                            ?? "The message outbox could not be loaded."
                    )
                )
                return
            }
            do {
                try await outbox.save()
            } catch {
                await send(.outboxSaveFailed(error.localizedDescription))
            }
        }
    }

    private func reconcileCanonicalMessages(
        _ messages: [Message],
        state: inout State,
        refreshingRows: Bool = false
    ) -> Bool {
        guard state.$outbox.loadError == nil, let chat = state.chat else {
            return false
        }
        let workspaceID = chat.session.workspaceID
        let sessionID = chat.session.id
        var aliases = state.messageIDToBubbleID
        var didMutateOutbox = false
        var hasRemainingBubbles = false
        var outboxSnapshot = state.outbox

        state.$outbox.withLock { outbox in
            var bubbles = outbox[workspaceID, sessionID]
            var claimedBubbleIDs = Set(aliases.values)
            let userMessages = messages.filter { $0.role == .user }
            let canonicalMessageIDs = state.canonicalMessageIDsBySession[
                sessionID,
                default: []
            ].union(userMessages.map(\.id))

            // Only durable receipt and attempt IDs can transition or alias an outbox bubble.
            for message in userMessages {
                let acceptedBubbleIndex = bubbles.firstIndex { bubble in
                    bubble.attempts.contains { attempt in
                        attempt.state.acceptedMessageID == message.id
                    }
                }
                var attemptBubbleIndex: Int?
                if let turnID = message.turnID.flatMap(UUID.init(uuidString:)) {
                    for bubbleIndex in bubbles.indices {
                        let attemptIndex = bubbles[bubbleIndex].attempts.firstIndex {
                            $0.attemptID == turnID
                        }
                        guard let attemptIndex else {
                            continue
                        }
                        let acceptedState = MessageOutbox.Attempt.State.accepted(
                            messageID: message.id
                        )
                        if bubbles[bubbleIndex].attempts[attemptIndex].state != acceptedState {
                            bubbles[bubbleIndex].attempts[attemptIndex].state = acceptedState
                            didMutateOutbox = true
                        }
                        attemptBubbleIndex = bubbleIndex
                        break
                    }
                }

                guard aliases[message.id] == nil,
                      let matchedBubbleIndex = acceptedBubbleIndex ?? attemptBubbleIndex,
                      !claimedBubbleIDs.contains(bubbles[matchedBubbleIndex].bubbleID) else {
                    continue
                }
                let bubble = bubbles[matchedBubbleIndex]
                aliases[message.id] = bubble.bubbleID
                claimedBubbleIDs.insert(bubble.bubbleID)
            }

            let aliasedBubbleIDs = Set(aliases.values)
            bubbles.removeAll { bubble in
                let acceptedMessageIDs = Set(
                    bubble.attempts.compactMap(\.state.acceptedMessageID)
                )
                let shouldRemove = aliasedBubbleIDs.contains(bubble.bubbleID)
                    && !bubble.attempts.contains {
                        $0.state == .sending || $0.state == .unknown
                    }
                    && acceptedMessageIDs.isSubset(of: canonicalMessageIDs)
                didMutateOutbox = didMutateOutbox || shouldRemove
                return shouldRemove
            }
            outbox[workspaceID, sessionID] = bubbles
            hasRemainingBubbles = !bubbles.isEmpty
            outboxSnapshot = outbox
        }

        if !hasRemainingBubbles {
            state.canonicalMessageIDsBySession[sessionID] = nil
        }
        let didChangeAliases = state.messageIDToBubbleID != aliases
        state.messageIDToBubbleID = aliases
        state.chat?.messageIDToBubbleID = aliases
        if didChangeAliases {
            let previousTurns = state.chat?.turns ?? []
            state.chat?.turns = Turn.parse(
                messages: messages,
                reusing: previousTurns,
                messageIDToBubbleID: aliases
            )
        }
        if refreshingRows || didChangeAliases || didMutateOutbox,
           let status = state.chat?.session.status {
            state.chat?.updateRows(
                sessionStatus: status,
                outbox: outboxSnapshot
            )
        }
        return didMutateOutbox
    }

    private func retainCanonicalMessageIDs(
        _ messages: [Message],
        state: inout State
    ) {
        guard let chat = state.chat,
              !state.outbox[chat.session.workspaceID, chat.session.id].isEmpty else {
            return
        }
        state.canonicalMessageIDsBySession[chat.session.id] = Set(
            messages.lazy.filter { $0.role == .user }.map(\.id)
        )
    }

    private func refreshCurrentChat(state: inout State) {
        let aliases = state.messageIDToBubbleID
        state.chat?.messageIDToBubbleID = aliases
        if let status = state.chat?.session.status {
            let outboxSnapshot = state.outbox
            state.chat?.updateRows(
                sessionStatus: status,
                outbox: outboxSnapshot
            )
        }
    }

    /// Reconciles the selected chat after session or workspace updates.
    ///
    /// Sessions can be removed, archived, or added while the workspace's active session can
    /// change independently. The current chat therefore has to be checked after either update.
    private static func selectedChat(
        afterReceiving sessions: [Session],
        currentChat: Chat.State?,
        workspaceActiveSessionID: Session.ID?,
        hasUserSelectedSession: Bool,
        sessionIDAwaitingObservation: Session.ID?,
        outbox: Shared<MessageOutbox>,
        messageIDToBubbleID: [Message.ID: UUID]
    ) -> Chat.State? {
        let activeSessions = sessions.filter { !$0.isHidden } // Archived sessions are displayed separately and cannot remain selected in the chat.
        let includesCurrentChat = currentChat.map { currentChat in
            activeSessions.contains { $0.id == currentChat.sessionID }
        } ?? false
        if let sessionIDAwaitingObservation,
           currentChat?.sessionID == sessionIDAwaitingObservation {
            return currentChat
        } else if hasUserSelectedSession,
           let currentChat,
           includesCurrentChat {
            // Preserve a reconciled or explicit selection instead of resetting it on every snapshot.
            return currentChat
        } else {
            // Prefer Conductor's active session, then fall back to the most recently updated session.
            let session = activeSessions.first { $0.id == workspaceActiveSessionID } /// Get the active session
                ?? activeSessions.max { /// Fallback to the most recently updated session
                    ($0.updatedDate ?? .distantPast) < ($1.updatedDate ?? .distantPast)
                }
            // Avoid rebuilding the current chat when the selected session has not changed.
            let canReuseCurrentChat = session?.id == currentChat?.sessionID
            guard !canReuseCurrentChat else {
                return currentChat
            }
            return session.map { session in
                var chat = Chat.State(session: session, outbox: outbox)
                chat.messageIDToBubbleID = messageIDToBubbleID
                chat.updateRows(sessionStatus: session.status)
                return chat
            }
        }
    }

    private func observeSessions(workspaceID: String) -> Effect<Action> {
        .run { send in
            await WebSocketHelpers.observe {
                desktopClient.observeSessions(workspaceID: workspaceID)
            } onValue: { sessions in
                await send(.loadSessionsResponse(.success(sessions)))

                try await database.write { db in
                    try Session
                        .where { $0.workspaceID.eq(workspaceID) }
                        .delete()
                        .execute(db)

                    try Session.upsert { sessions }
                        .execute(db)
                }
                await send(.sessionSnapshotPersisted)
            } onFailure: { error in
                await send(.loadSessionsResponse(.failure(error)))
            }
        }
    }

    private func markWorkspaceReadIfNeeded(
        _ state: State,
        selectedSession: Session?
    ) -> Effect<Action> {
        guard (state.workspace.unread ?? 0) > 0
              || (selectedSession?.unreadCount ?? 0) > 0 else {
            return .none
        }

        return .run { [workspaceID = state.workspace.id] _ in
            do {
                _ = try await desktopClient.setWorkspaceUnread(
                    workspaceID: workspaceID,
                    isUnread: false
                )
            } catch {
                Logger.chat.error("Failed to mark workspace as read: \(error)")
                return
            }

            do {
                try await database.write { db in
                    try Workspace
                        .find(workspaceID)
                        .update { $0.unread = #bind(0) }
                        .execute(db)
                    try Session
                        .where {
                            $0.workspaceID.eq(workspaceID)
                                && !$0.isHidden
                                && $0.unreadCount.gt(0)
                        }
                        .update { $0.unreadCount = 0 }
                        .execute(db)
                }
            } catch {
                Logger.chat.error("Failed to update cached unread state: \(error)")
            }
        }
    }
}

extension WorkspaceChat.Destination.State: Equatable { }

private extension MessageOutbox.Attempt.State {
    var acceptedMessageID: Message.ID? {
        guard case .accepted(let messageID) = self else {
            return nil
        }
        return messageID
    }

    var isAccepted: Bool {
        acceptedMessageID != nil
    }
}

extension AlertState where Action == WorkspaceChat.Destination.Alert {
    static func creationPromptFailed(message: String) -> Self {
        AlertState {
            TextState("Workspace created without sending message")
        } message: {
            TextState(message)
        }
    }

    static var confirmUnknownRetry: Self {
        AlertState {
            TextState("Retry message?")
        } actions: {
            ButtonState(role: .cancel) {
                TextState("Cancel")
            }
            ButtonState(action: .confirmUnknownRetry) {
                TextState("Retry")
            }
        } message: {
            TextState(
                "Delivery was not confirmed. Retrying could send the message twice."
            )
        }
    }

    static func outboxSaveFailed(message: String) -> Self {
        AlertState {
            TextState("Failed to save message outbox")
        } actions: {
            ButtonState(role: .cancel) {
                TextState("Cancel")
            }
            ButtonState(action: .retryOutboxSave) {
                TextState("Retry Saving")
            }
        } message: {
            TextState(message)
        }
    }

    static func outboxUnavailable(message: String) -> Self {
        AlertState {
            TextState("Message outbox unavailable")
        } message: {
            TextState(message)
        }
    }

    static var maximumTabsReached: Self {
        AlertState {
            TextState("Maximum of 5 tabs allowed")
        }
    }

    static func failedToLoadMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to load messages")
        } message: {
            TextState(message)
        }
    }

    static func failedToArchiveWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to archive workspace")
        } message: {
            TextState(message)
        }
    }

    static func failedToUpdateWorkspace(message: String) -> Self {
        AlertState {
            TextState("Failed to update workspace")
        } message: {
            TextState(message)
        }
    }

    static var workspaceMutationUsedSQLiteFallback: Self {
        AlertState {
            TextState("Workspace change saved")
        } message: {
            TextState(
                "The change was saved to Conductor's database, but the open Conductor window "
                    + "may remain stale until Conductor reloads. Reconnect the Workspace UI hook "
                    + "for live updates."
            )
        }
    }

    static func failedToCreateSession(message: String) -> Self {
        AlertState {
            TextState("Failed to create session")
        } message: {
            TextState(message)
        }
    }

    static func failedToLoadSessions(message: String) -> Self {
        AlertState {
            TextState("Failed to load sessions")
        } message: {
            TextState(message)
        }
    }

    static func failedToRenameBranch(message: String) -> Self {
        AlertState {
            TextState("Failed to rename branch")
        } message: {
            TextState(message)
        }
    }

    static func failedToStopSession(message: String) -> Self {
        AlertState {
            TextState("Failed to stop agent")
        } message: {
            TextState(message)
        }
    }
}

public struct WorkspaceChatView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var store: StoreOf<WorkspaceChat>
    @ScaledMetric(relativeTo: .body) private var menuIconSize = 20
    @ScaledMetric(relativeTo: .body) private var sessionPickerHeight = 52

    public init(store: StoreOf<WorkspaceChat>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let chatStore = store.scope(state: \.chat, action: \.chat) {
                ChatView(
                    store: chatStore,
                    directoryName: store.workspace.emptyChatDirectoryName
                )
                    // Treat each session as distinct content so view-local scroll state resets.
                    .id(chatStore.sessionID)
            } else {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .themedNavigationTitle(
            verbatim: store.workspace.displayName,
            alignment: .leading
        ) {
            Label {
                Text(verbatim: store.workspaceWithRepository.repositoryDisplayName)
                    .lineLimit(1)
            } icon: {
                RepositoryIcon(
                    repository: store.workspaceWithRepository.repository,
                    size: 13,
                    relativeTo: .footnote
                )
                .foregroundStyle(.theme(.textSecondary))
            }
            .labelStyle(.conductorExtraSmall)
        }
        .toolbar {
            toolbarMenu
        }
        .safeAreaBar(edge: .top) {
            SessionPicker(
                sessions: store.activeSessions,
                selectedSessionID: store.chat?.sessionID,
                isCreatingSession: store.isCreatingSession,
                animatesSessionChanges: store.hasPersistedInitialSessionSnapshot,
                height: sessionPickerHeight
            ) { session in
                store.send(.sessionButtonTapped(session))
            } createSession: {
                store.send(.createSessionButtonTapped)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if store.isLoadingSessions {
                ProgressView()
                    .progressViewStyle(.network)
                    .tint(.theme(.textSecondary))
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(.theme(.background))
            }
        }
        .background(.theme(.background))
        .alert(
            "Rename branch",
            isPresented: Binding(
                get: { store.destination == .renameBranch },
                set: { isPresented in
                    if !isPresented {
                        store.send(.destination(.dismiss))
                    }
                }
            )
        ) {
            TextField("Branch name", text: $store.branchNameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .tint(.theme(.accent))

            Button("Rename", role: .confirm) {
                store.send(.renameBranchSubmitted)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!store.canRenameBranch)

            Button("Cancel", role: .cancel) { }
        }
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .sensoryFeedback(.error, trigger: store.destination) { _, destination in
            destination?.alert.map { $0 != .confirmUnknownRetry } ?? false
        }
        .sheet(
            item: $store.scope(
                state: \.destination?.archivedSessions,
                action: \.destination.archivedSessions
            )
        ) { archivedSessionsStore in
            ArchivedSessionsView(store: archivedSessionsStore)
                .presentationDetents([.medium, .large])
        }
        .task {
            await store.send(.task).finish()
        }
    }

    private var toolbarMenu: some View {
        Menu {
            Section {
                Button {
                    store.send(.workspaceUnreadButtonTapped)
                } label: {
                    Label {
                        Text(isUnread ? "Mark as read" : "Mark as unread")
                    } icon: {
                        ColoredMenuImage(isUnread ? Lucide.mailOpen : Lucide.mail)
                    }
                }

                Button {
                    store.send(.workspacePinnedButtonTapped)
                } label: {
                    Label {
                        Text(isPinned ? "Unpin" : "Pin")
                    } icon: {
                        ColoredMenuImage(isPinned ? Lucide.pinOff : Lucide.pin)
                    }
                }

                Menu {
                    Picker(
                        "Status",
                        selection: Binding(
                            get: { store.workspace.status },
                            set: { store.send(.workspaceStatusButtonTapped($0)) }
                        )
                    ) {
                        ForEach(statuses) { status in
                            Label {
                                Text(status.title)
                            } icon: {
                                LinearStatusIcon(
                                    status: status,
                                    size: menuIconSize,
                                    preservesColor: true
                                )
                            }
                            .tag(status)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } label: {
                    Label {
                        Text("Set status")
                    } icon: {
                        LinearStatusIcon(
                            status: store.workspace.status,
                            size: menuIconSize,
                            preservesColor: true
                        )
                    }

                    Text(store.workspace.status.title)
                }
            }

            Section {
                Button {
                    store.send(.renameBranchButtonTapped)
                } label: {
                    Label {
                        Text("Rename branch")
                    } icon: {
                        ColoredMenuImage(Lucide.pencil, color: .theme(.textPrimary))
                    }

                    if let branch = store.workspace.branch {
                        Text(verbatim: branch)
                    }
                }
                .disabled(store.isRenamingBranch)

                if !store.isLoadingSessions, !store.archivedSessions.isEmpty {
                    Button {
                        store.send(.archivedSessionsButtonTapped)
                    } label: {
                        Label {
                            Text("Chat history")
                        } icon: {
                            ColoredMenuImage(Lucide.history, color: .theme(.textPrimary))
                        }
                    }
                }

                if let pullRequestURL = store.workspaceWithRepository.pullRequestURL {
                    Button {
                        openURL(pullRequestURL)
                    } label: {
                        Label {
                            Text("Open PR in GitHub")
                        } icon: {
                            ScaledImage.gitHub(size: 16, relativeTo: .body)
                        }
                    }
                    .accessibilityLabel("Pull request")
                }
            }

            Section {
                Button(role: .destructive) {
                    store.send(.archiveWorkspaceButtonTapped)
                } label: {
                    Label {
                        Text("Archive")
                    } icon: {
                        ColoredMenuImage(
                            Lucide.archive,
                            color: .theme(.destructive)
                        )
                    }
                }
            }
        } label: {
            Label {
                Text("More")
            } icon: {
                LucideIcon(Lucide.ellipsis, size: 20, relativeTo: .body)
                    .foregroundStyle(.theme(.textPrimary))
            }
            .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Workspace actions")
    }

    private var statuses: [Workspace.Status] {
        [.backlog, .inProgress, .inReview, .done, .canceled]
    }

    private var isPinned: Bool {
        store.workspace.pinnedAt != nil
    }

    private var isUnread: Bool {
        (store.workspace.unread ?? 0) > 0
    }

    private struct SessionPicker: View {
        let sessions: [Session]
        let selectedSessionID: Session.ID?
        let isCreatingSession: Bool
        let animatesSessionChanges: Bool
        let height: CGFloat
        let action: @MainActor (Session) -> Void
        let createSession: @MainActor () -> Void
        @State private var scrollPosition = ScrollPosition(idType: Session.ID.self)

        var body: some View {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(sessions) { session in
                            SessionButton(
                                session: session,
                                isSelected: session.id == selectedSessionID
                            ) {
                                action(session)
                            }
                            // This padding originally lived on the GlassEffectContainer, but
                            // applying it directly to the edge buttons keeps them from touching
                            // the screen edge when ScrollPosition scrolls to them.
                            .padding(.leading, session.id == sessions.first?.id ? 16 : 0)
                        }

                        NewSessionButton(
                            isCreatingSession: isCreatingSession,
                            action: createSession
                        )
                        .padding(.leading, sessions.isEmpty ? 16 : 0)
                        .padding(.trailing, 16)
                    }
                    .scrollTargetLayout()
                    .animation(
                        animatesSessionChanges ? .default : nil,
                        value: sessions.map(\.id)
                    )
                }
                .padding(.vertical, 8)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("workspace-chat.session-picker")
            .frame(height: height)
            // Run initially for the cached active session, then follow active or user selections.
            .onChange(of: selectedSessionID, initial: true) { _, sessionID in
                selectedSessionChanged(sessionID)
            }
            .onChange(of: sessions.map(\.id)) {
                selectedSessionChanged(selectedSessionID)
            }
        }

        private func selectedSessionChanged(_ sessionID: Session.ID?) {
            guard let sessionID else {
                return
            }

            if animatesSessionChanges {
                withAnimation {
                    scrollPosition.scrollTo(id: sessionID, anchor: .center)
                }
            } else {
                scrollPosition.scrollTo(id: sessionID, anchor: .center)
            }
        }
    }

    private struct NewSessionButton: View {
        let isCreatingSession: Bool
        let action: @MainActor () -> Void
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var iconSize = ThemeFontStyle.small.size
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var buttonSize = ThemeFontStyle.small.size + 12

        var body: some View {
            Button(action: action) {
                Group {
                    if isCreatingSession {
                        ProgressView()
                            .progressViewStyle(.network)
                            .tint(.theme(.textSecondary))
                            .controlSize(.mini)
                    } else {
                        LucideIcon(Lucide.plus, size: iconSize, relativeTo: .footnote)
                            .foregroundStyle(.theme(.textSecondary))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .frame(width: buttonSize, height: buttonSize)
            }
            .glassEffect(.clear.interactive(), in: .circle)
            .disabled(isCreatingSession)
            .accessibilityLabel("New session")
            .accessibilityIdentifier("workspace-chat.new-session")
        }
    }

    private struct SessionButton: View {
        let session: Session
        let isSelected: Bool
        let action: @MainActor () -> Void
        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var iconSize = ThemeFontStyle.small.size

        @ScaledMetric(relativeTo: ThemeFontStyle.small.textStyle)
        private var unreadIndicatorSize = 6 // kinda a magic number just got it by tweaking

        var body: some View {
            Button(action: action) {
                Label {
                    Text(session.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.theme(isSelected ? .textPrimary : .textSecondary))
                } icon: {
                    if session.status == .working {
                        ProgressView()
                            .progressViewStyle(.conductor(phaseSeed: session.id))
                            .tint(.theme(.textSecondary))
                            .frame(width: iconSize, height: iconSize)
                    } else if session.unreadCount > 0 {
                        UnreadIcon(size: unreadIndicatorSize)
                    }
                }
                .labelStyle(.conductorExtraSmall)
                .font(.theme(.small))
                .frame(maxWidth: 120)
                .padding(EdgeInsets(vertical: 4, horizontal: 12))
            }
            .glassEffect(
                .clear
                    .tint(isSelected ? .theme(.highlight) : Color.clear)
                    .interactive()
            )
            .tint(isSelected ? .theme(.highlight) : .clear)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

#if DEBUG
#Preview("Realistic workspace") {
    let content = try! WorkspaceChatPreviewContent()
    let _ = try! prepareDependencies {
        try $0.bootstrapDatabase()
        try $0.defaultDatabase.write { db in
            try Workspace.upsert { content.workspace }.execute(db)
            try Repository.upsert { content.repository }.execute(db)
            try MobileWorkspaceState.upsert { content.mobileState }.execute(db)
            try Session.upsert { content.sessions }.execute(db)
            try Message.upsert { content.messages }.execute(db)
        }
        $0.desktopClient.observeSessions = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(content.sessions)
            }
        }
        $0.desktopClient.observeMessages = { _, sessionID in
            AsyncThrowingStream { continuation in
                continuation.yield(
                    content.messages.filter { $0.sessionID == sessionID }
                )
            }
        }
    }

    NavigationStack {
        WorkspaceChatView(
            store: Store(
                initialState: WorkspaceChat.State(
                    workspaceWithRepository: content.workspaceWithRepository
                )
            ) {
                WorkspaceChat()
            }
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // mimic a back button
                Button {
                } label: {
                    Image(systemName: "chevron.left")
                        .imageScale(.medium)
                        .foregroundStyle(.theme(.textPrimary))
                }
            }
        }
    }
    .preferredColorScheme(.dark)
}
#endif
