//
//  WorkspaceChat.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/11/26.
//

import Combine
import ComposableArchitecture
import ConductorCloud
import SharedConductorData
import ConductorDesign
import ConductorMobileData
import Foundation
import LucideIcons
import Logging
import SQLiteData
import SwiftUI
import UIKit

/// A wrapper over ``Chat`` which enables switch between sessions for this workspace
@Reducer
public struct WorkspaceChat: Sendable {
    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?

        @Shared(.cloudConfiguration)
        public var cloudConfiguration

        // TODO: Ideally this would be non-nil but couldn't figure out a good way to achieve it
        var chat: Chat.State?

        /// We want to switch to the active session if our local cached data is out of date and we get
        /// and updated active_session from the remote.
        ///
        /// However we want to prevent that from overriding a local switch from the user
        var hasUserSelectedSession = false
        var isCreatingSession = false
        var isArchivingWorkspace = false
        var isClosingSession = false
        var isRenamingBranch = false
        var isRenamingSession = false
        var isLoadingSessions = true
        var isWorkspaceMutationInFlight = false
        var branchNameDraft = ""
        var hasPersistedInitialSessionSnapshot = false
        /// Cleared once observation identifies a session created after this snapshot.
        var sessionIDsBeforeCreation: Set<Session.ID>?
        var sessionIDAwaitingObservation: Session.ID?
        var conciseTranscript = ""
        var transcriptCopyCount = 0
        var renamingSession: Session?
        var sessionTitleDraft = ""
        var messageIDToBubbleID: [Message.ID: UUID] = [:]
        var optimisticMessagesBySession: [Session.ID: [OptimisticMessage]] = [:]

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]
        @FetchOne public var workspaceWithRepository: WorkspaceWithRepository

        public init(
            workspaceWithRepository: WorkspaceWithRepository,
            selectedModel: Session.Model? = nil,
            selectedReasoningEffort: Session.ReasoningEffort? = nil,
            initialMessage: InitialMessage? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            let workspace = workspaceWithRepository.workspace
            self._workspaceWithRepository = FetchOne(
                wrappedValue: workspaceWithRepository,
                WorkspaceWithRepository.all(workspaceID: workspace.id),
                animation: .default
            )

            self.chat = nil

            self._archivedSessions = if workspace.isCloudHosted {
                FetchAll(
                    CloudSessionMetadata.sessions(
                        workspaceID: workspace.id,
                        isHidden: true
                    ),
                    animation: .default
                )
            } else {
                FetchAll(
                    Session
                        .where { $0.workspaceID.eq(workspace.id).and($0.isHidden) }
                        .order { $0.updatedAt.desc() },
                    animation: .default
                )
            }

            let activeSessions = if workspace.isCloudHosted {
                FetchAll(
                    CloudSessionMetadata.sessions(
                        workspaceID: workspace.id,
                        isHidden: false
                    ),
                    animation: .default
                )
            } else {
                FetchAll(
                    Session
                        .where { $0.workspaceID.eq(workspace.id).and(!$0.isHidden) }
                        .order(by: \.createdAt),
                    animation: .default
                )
            }

            self._activeSessions = activeSessions
            if workspace.isCloudHosted,
               (!self.activeSessions.isEmpty || !self.archivedSessions.isEmpty) {
                self.isLoadingSessions = false
            }

            let session = self.activeSessions.first {
                $0.id == workspace.activeSessionID
            } ?? self.activeSessions.first

            self.chat = session.map {
                Chat.State(
                    session: $0,
                    isCloudHosted: workspace.isCloudHosted,
                    selectedModel: selectedModel,
                    selectedReasoningEffort: selectedReasoningEffort,
                    shouldFocusMessageField: shouldFocusMessageField
                )
            }
            if let session, let initialMessage {
                let status: OptimisticMessage.Status
                let canonicalMessageID: Message.ID?
                switch initialMessage.deliveryResult {
                case .accepted(let messageID):
                    status = .acceptedAwaitingObservation
                    canonicalMessageID = messageID
                case .rejected:
                    status = .rejected
                    canonicalMessageID = nil
                case .unknown:
                    status = .unconfirmed
                    canonicalMessageID = nil
                }
                let optimisticMessage = OptimisticMessage(
                    id: initialMessage.id,
                    workspaceID: workspace.id,
                    sessionID: session.id,
                    content: initialMessage.content,
                    model: selectedModel ?? session.model,
                    isFastModeEnabled: session.isFastModeEnabled ?? false,
                    mode: .sent,
                    reasoningEffort: selectedReasoningEffort ?? session.reasoningEffort,
                    status: status,
                    canonicalMessageID: canonicalMessageID,
                    deliveryDetail: initialMessage.deliveryResult.reason,
                    previousTurnID: nil
                )
                self.optimisticMessagesBySession[session.id] = [optimisticMessage]
                self.chat?.optimisticMessages = [optimisticMessage]
                self.chat?.beginSendCycle(attemptID: optimisticMessage.id)
                self.chat?.updateRows()
            }
        }

        public var workspace: Workspace {
            workspaceWithRepository.workspace
        }

        public var canRestoreWarmPresentation: Bool {
            guard let chat else {
                return false
            }
            return (!workspace.isCloudHosted || cloudConfiguration != nil)
                && !isLoadingSessions
                && chat.session.status == .idle
                && !isArchivingWorkspace
                && !isClosingSession
                && !isCreatingSession
                && !isRenamingBranch
                && !isRenamingSession
                && !isWorkspaceMutationInFlight
                && sessionIDsBeforeCreation == nil
                && sessionIDAwaitingObservation == nil
                && renamingSession == nil
                && destination == nil
                && !chat.isLoadingMessages
                && !chat.isMessageSendInFlight
                && !chat.isStopInFlight
                && chat.voiceInput.phase == .idle
                && !chat.queuedMessages.isEditStartInFlight
                && !chat.queuedMessages.isEditing
                && !chat.queuedMessages.isEditInFlight
                && chat.queuedMessages.messageActionInFlightID == nil
                && !chat.queuedMessages.isReorderInFlight
                && !chat.queuedMessages.isResumeInFlight
                && chat.queuedMessages.pendingMessageIDs == nil
                && chat.queuedMessages.isInteractionEnabled
        }

        var canRenameBranch: Bool {
            let branch = branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !isRenamingBranch && !branch.isEmpty && branch != workspace.branch
        }

        var canRenameSession: Bool {
            let title = sessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && title != renamingSession?.title
        }

        var isQueuedMessageEditLocked: Bool {
            chat?.queuedMessages.isEditStartInFlight == true
                || chat?.queuedMessages.isEditing == true
        }
    }

    @Reducer
    public enum Destination {
        case alert(AlertState<Alert>)
        case archivedSessions(ArchivedSessions)
        case renameBranch
        case renameSession

        public enum Alert: Equatable {
            case openSettings
        }
    }

    public enum Action: BindableAction {
        case activeSessionIDChanged(Session.ID?)
        case archiveWorkspaceButtonTapped
        case archiveWorkspaceResponse(Result<Void, any Error>)
        case archivedSessionsButtonTapped
        case binding(BindingAction<State>)
        case chat(Chat.Action)
        case closeSessionButtonTapped(Session)
        case closeSessionResponse(Result<Void, any Error>)
        case cloudConfigurationChanged(CloudConfiguration?)
        case copyConciseTranscriptButtonTapped(Session)
        case copyConciseTranscriptResponse(Result<String, any Error>)
        case createSessionButtonTapped
        case createSessionResponse(Result<Session, any Error>)
        case createSessionLeasedResponse(
            requestLease: DesktopRequestLease,
            session: Session
        )
        /// Clears in-flight UI when the desktop address changed during session creation.
        case createSessionDiscardedForStaleEndpoint
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsResponse(Result<[Session], any Error>)
        case hostingSourceChanged(Bool)
        case hostingSourceReloaded(
            isCloudHosted: Bool,
            result: Result<[Session], any Error>
        )
        case messageSendResponse(SendAddress, DesktopClient.MessageDeliveryResult)
        case renameBranchButtonTapped
        case renameBranchResponse(Result<Void, any Error>)
        case renameBranchSubmitted
        case renameSessionButtonTapped(Session)
        case renameSessionResponse(Result<Void, any Error>)
        case renameSessionSubmitted
        case sessionSnapshotPersisted
        case sessionButtonTapped(Session)
        case task
        case workspaceMutationFailed(any Error)
        case workspaceMutationFinished
        case workspaceMutationUsedSQLiteFallback
        case workspacePinnedButtonTapped
        case workspaceStatusButtonTapped(Workspace.Status)
        case workspaceUnreadButtonTapped

        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case openSettings
            case workspaceArchived
        }
    }

    public struct SendAddress: Equatable, Sendable {
        let workspaceID: Workspace.ID
        let sessionID: Session.ID
        let messageID: UUID
    }

    public struct InitialMessage: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let content: String
        public let deliveryResult: MessageDeliveryResult

        public init(
            id: UUID,
            content: String,
            deliveryResult: MessageDeliveryResult
        ) {
            self.id = id
            self.content = content
            self.deliveryResult = deliveryResult
        }
    }

    struct OptimisticMessage: Equatable, Identifiable, Sendable {
        let id: UUID
        let workspaceID: Workspace.ID
        let sessionID: Session.ID
        let content: String
        let model: Session.Model
        let isFastModeEnabled: Bool
        let mode: DesktopClient.MessageMode
        let reasoningEffort: Session.ReasoningEffort?
        var status: Status
        var canonicalMessageID: Message.ID? = nil
        var deliveryDetail: String? = nil
        let previousTurnID: Turn.ID?

        enum Status: Equatable, Sendable {
            case acceptedAwaitingObservation
            case rejected
            case sending
            case unconfirmed
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date.now) var now
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.uuid) var uuid

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                let workspace = state.$workspaceWithRepository
                let cloudConfiguration = state.$cloudConfiguration
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
                    .publisher {
                        workspace.publisher
                            .map(\.workspace.isCloudHosted)
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.hostingSourceChanged)
                    },
                    .publisher {
                        cloudConfiguration.publisher
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.cloudConfigurationChanged)
                    },
                    observeSessions(
                        workspaceID: state.workspace.id,
                        isCloudHosted: state.workspace.isCloudHosted
                    )
                )

            case let .cloudConfigurationChanged(configuration):
                guard configuration != nil,
                      state.workspace.isCloudHosted else {
                    return .none
                }
                if state.activeSessions.isEmpty {
                    state.isLoadingSessions = true
                }
                return observeSessions(
                    workspaceID: state.workspace.id,
                    isCloudHosted: true
                )

            case let .hostingSourceChanged(isCloudHosted):
                state.chat = nil
                state.destination = nil
                state.hasUserSelectedSession = false
                state.isLoadingSessions = true
                state.sessionIDsBeforeCreation = nil
                state.sessionIDAwaitingObservation = nil
                let activeSessions = state.$activeSessions
                let archivedSessions = state.$archivedSessions
                let workspaceID = state.workspace.id
                return .merge(
                    .cancel(id: CancelID.sessionObservation),
                    .run { send in
                        let result = await Result {
                            if isCloudHosted {
                                try await activeSessions.load(
                                    CloudSessionMetadata.sessions(
                                        workspaceID: workspaceID,
                                        isHidden: false
                                    ),
                                    animation: .default
                                )
                                try await archivedSessions.load(
                                    CloudSessionMetadata.sessions(
                                        workspaceID: workspaceID,
                                        isHidden: true
                                    ),
                                    animation: .default
                                )
                                return try await database.read { database in
                                    try CloudSessionMetadata
                                        .sessions(
                                            workspaceID: workspaceID,
                                            isHidden: false
                                        )
                                        .fetchAll(database)
                                        + CloudSessionMetadata
                                            .sessions(
                                                workspaceID: workspaceID,
                                                isHidden: true
                                            )
                                            .fetchAll(database)
                                }
                            }

                            let activeQuery = Session
                                .where {
                                    $0.workspaceID.eq(workspaceID)
                                        .and(!$0.isHidden)
                                }
                                .order(by: \.createdAt)
                            let archivedQuery = Session
                                .where {
                                    $0.workspaceID.eq(workspaceID)
                                        .and($0.isHidden)
                                }
                                .order { $0.updatedAt.desc() }
                            try await activeSessions.load(
                                activeQuery,
                                animation: .default
                            )
                            try await archivedSessions.load(
                                archivedQuery,
                                animation: .default
                            )
                            return try await database.read { database in
                                try activeQuery.fetchAll(database)
                                    + archivedQuery.fetchAll(database)
                            }
                        }
                        await send(
                            .hostingSourceReloaded(
                                isCloudHosted: isCloudHosted,
                                result: result
                            )
                        )
                    }
                )

            case let .hostingSourceReloaded(isCloudHosted, .success(sessions)):
                guard state.workspace.isCloudHosted == isCloudHosted else {
                    return .none
                }
                state.chat = Self.selectedChat(
                    afterReceiving: sessions,
                    currentChat: nil,
                    workspaceActiveSessionID: state.workspace.activeSessionID,
                    hasUserSelectedSession: false,
                    sessionIDAwaitingObservation: nil,
                    isCloudHosted: isCloudHosted,
                    optimisticMessagesBySession: state.optimisticMessagesBySession,
                    messageIDToBubbleID: state.messageIDToBubbleID
                )
                state.isLoadingSessions = sessions.isEmpty
                return observeSessions(
                    workspaceID: state.workspace.id,
                    isCloudHosted: isCloudHosted
                )

            case let .hostingSourceReloaded(_, .failure(error)):
                return .send(.loadSessionsResponse(.failure(error)))

            case let .activeSessionIDChanged(activeSessionID):
                // The workspace and session snapshots are persisted independently. Do not let a
                // workspace update clear or replace the chat while SQLite is still catching up.
                let activeSession = state.activeSessions.first {
                    $0.id == activeSessionID
                }
                guard !state.hasUserSelectedSession,
                      !state.isQueuedMessageEditLocked,
                      let activeSessionID,
                      let activeSession,
                      state.chat?.sessionID != activeSessionID else {
                    return .none
                }
                state.chat = Chat.State(
                    session: activeSession,
                    isCloudHosted: state.workspace.isCloudHosted
                )
                refreshCurrentChat(state: &state)
                return .none

            case .archiveWorkspaceButtonTapped:
                guard !state.isArchivingWorkspace else {
                    return .none
                }
                state.isArchivingWorkspace = true
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
                state.isArchivingWorkspace = false
                return .send(.delegate(.workspaceArchived))

            case let .archiveWorkspaceResponse(.failure(error)):
                Logger.chat.error("Failed to archive workspace: \(error)")
                state.isArchivingWorkspace = false
                state.destination = .alert(
                    .failedToArchiveWorkspace(message: error.localizedDescription)
                )
                return .none

            case .archivedSessionsButtonTapped:
                state.destination = .archivedSessions(
                    ArchivedSessions.State(
                        workspaceID: state.workspace.id,
                        isCloudHosted: state.workspace.isCloudHosted,
                        sessions: state.archivedSessions,
                        activeSessions: state.activeSessions
                    )
                )
                return .none

            case .destination(.dismiss):
                state.renamingSession = nil
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

            case let .closeSessionButtonTapped(session):
                guard !state.isClosingSession else {
                    return .none
                }
                state.isClosingSession = true
                return .run {
                    [
                        isCloudHosted = state.workspace.isCloudHosted,
                        workspaceID = state.workspace.id,
                    ] send in
                    await send(
                        .closeSessionResponse(
                            Result {
                                try await desktopClient.closeSession(
                                    workspaceID: workspaceID,
                                    sessionID: try await mutationSessionID(
                                        session.id,
                                        isCloudHosted: isCloudHosted
                                    )
                                )
                            }
                        )
                    )
                }

            case .closeSessionResponse(.success):
                state.isClosingSession = false
                return .none

            case let .closeSessionResponse(.failure(error)):
                Logger.chat.error("Failed to close session: \(error)")
                state.isClosingSession = false
                state.destination = .alert(
                    .failedToCloseSession(message: error.localizedDescription)
                )
                return .none

            case let .copyConciseTranscriptButtonTapped(session):
                return .run {
                    [isCloudHosted = state.workspace.isCloudHosted] send in
                    await send(
                        .copyConciseTranscriptResponse(
                            Result {
                                let messages = try await database.read { database in
                                    if isCloudHosted {
                                        try CloudMessageMetadata
                                            .messages(sessionID: session.id)
                                            .fetchAll(database)
                                    } else {
                                        try Message
                                            .where { $0.sessionID.eq(session.id) }
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
                                guard let transcript = ConciseTranscript.format(messages) else {
                                    throw ConciseTranscriptCopyError.empty
                                }
                                return transcript
                            }
                        )
                    )
                }

            case let .copyConciseTranscriptResponse(.success(transcript)):
                state.conciseTranscript = transcript
                state.transcriptCopyCount &+= 1
                return .none

            case let .copyConciseTranscriptResponse(.failure(error)):
                Logger.chat.error("Failed to copy concise transcript: \(error)")
                state.destination = .alert(
                    .failedToCopyTranscript(message: error.localizedDescription)
                )
                return .none

            case .createSessionButtonTapped:
                guard !state.isQueuedMessageEditLocked else {
                    return .none
                }
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
                    do {
                        // Session creation may finish after Settings switches desktops. Pin the
                        // request, database write, and reducer response to one endpoint epoch.
                        let requestLease = try desktopClient.acquireRequestLease()
                        let session = try await DesktopRequestLeaseContext.$current
                            .withValue(requestLease) {
                                try await desktopClient.createSession(workspaceID: workspaceID)
                            }
                        try await desktopClient.persistCreatedSession(
                            session: session,
                            requestLease: requestLease
                        )
                        await send(
                            .createSessionLeasedResponse(
                                requestLease: requestLease,
                                session: session
                            )
                        )
                    } catch DesktopClientError.staleRequestLease {
                        await send(.createSessionDiscardedForStaleEndpoint)
                    } catch {
                        await send(.createSessionResponse(.failure(error)))
                    }
                }

            case let .createSessionLeasedResponse(requestLease, session):
                guard desktopClient.isRequestLeaseValid(lease: requestLease) else {
                    state.isCreatingSession = false
                    state.sessionIDsBeforeCreation = nil
                    return .none
                }
                return .send(.createSessionResponse(.success(session)))

            case .createSessionDiscardedForStaleEndpoint:
                state.isCreatingSession = false
                state.sessionIDsBeforeCreation = nil
                return .none

            case let .createSessionResponse(.success(session)):
                if state.workspace.isCloudHosted {
                    state.isCreatingSession = false
                    return .none
                }
                let hasObservedSession = state.sessionIDsBeforeCreation == nil
                state.hasUserSelectedSession = true
                state.isCreatingSession = false
                state.sessionIDAwaitingObservation = hasObservedSession ? nil : session.id
                state.sessionIDsBeforeCreation = nil
                if !state.isQueuedMessageEditLocked,
                   state.chat?.sessionID != session.id {
                    state.chat = Chat.State(
                        session: session,
                        isCloudHosted: state.workspace.isCloudHosted,
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
                    if !state.isQueuedMessageEditLocked {
                        state.chat = Chat.State(
                            session: createdSession,
                            isCloudHosted: state.workspace.isCloudHosted,
                            shouldFocusMessageField: true
                        )
                        refreshCurrentChat(state: &state)
                    }
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
                    isCloudHosted: state.workspace.isCloudHosted,
                    optimisticMessagesBySession: state.optimisticMessagesBySession,
                    messageIDToBubbleID: state.messageIDToBubbleID
                )
                state.isLoadingSessions = false
                return .none

            case let .loadSessionsResponse(.failure(error)):
                Logger.chat.error("Failed to load sessions: \(error)")
                if let apiError = error as? CloudAPIClientError,
                   apiError.isAuthenticationFailure {
                    state.destination = .alert(
                        .cloudAuthenticationFailed(
                            message: apiError.localizedDescription
                        )
                    )
                    return .none
                }
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadSessions(message: error.localizedDescription)
                )
                return .none

            case let .renameSessionButtonTapped(session):
                state.renamingSession = session
                state.sessionTitleDraft = session.title ?? ""
                state.destination = .renameSession
                return .none

            case .renameSessionSubmitted:
                guard state.canRenameSession, let session = state.renamingSession else {
                    return .none
                }
                let title = state.sessionTitleDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                state.sessionTitleDraft = title
                state.renamingSession = nil
                state.destination = nil
                state.isRenamingSession = true
                return .run { [
                    isCloudHosted = state.workspace.isCloudHosted,
                    workspaceID = state.workspace.id,
                    sessionID = session.id,
                    title,
                ] send in
                    await send(
                        .renameSessionResponse(
                            Result {
                                try await desktopClient.renameSession(
                                    workspaceID: workspaceID,
                                    sessionID: try await mutationSessionID(
                                        sessionID,
                                        isCloudHosted: isCloudHosted
                                    ),
                                    title: title
                                )
                            }
                        )
                    )
                }

            case .renameSessionResponse(.success):
                state.isRenamingSession = false
                return .none

            case let .renameSessionResponse(.failure(error)):
                Logger.chat.error("Failed to rename session: \(error)")
                state.isRenamingSession = false
                state.destination = .alert(
                    .failedToRenameSession(message: error.localizedDescription)
                )
                return .none

            case .sessionSnapshotPersisted:
                state.hasPersistedInitialSessionSnapshot = true
                return .none

            case let .chat(.sendButtonTapped(mode)):
                guard let chat = state.chat else {
                    return .none
                }
                let rawDraft = chat.messageDraft
                let content = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty,
                      !chat.isMessageSendInFlight,
                      chat.voiceInput.phase == .idle else {
                    return .none
                }

                let messageID = uuid()
                let address = SendAddress(
                    workspaceID: chat.session.workspaceID,
                    sessionID: chat.session.id,
                    messageID: messageID
                )
                let optimisticMessage = OptimisticMessage(
                    id: messageID,
                    workspaceID: address.workspaceID,
                    sessionID: address.sessionID,
                    content: content,
                    model: chat.selectedModel,
                    isFastModeEnabled: chat.isFastModeEnabled,
                    mode: mode,
                    reasoningEffort: chat.selectedReasoningEffort,
                    status: .sending,
                    previousTurnID: chat.turns?.last?.id
                )
                state.optimisticMessagesBySession[address.sessionID, default: []]
                    .append(optimisticMessage)
                if mode == .sent {
                    state.chat?.beginSendCycle(attemptID: messageID)
                }
                if mode == .sent {
                    chat.$messageDraft.withLock { draft in
                        if draft == rawDraft {
                            draft = ""
                        }
                    }
                }
                refreshCurrentChat(state: &state)
                if mode == .sent {
                    state.chat?.scrollToBottomRequest &+= 1
                }
                return .run {
                    [isCloudHosted = state.workspace.isCloudHosted] send in
                    do {
                        let mutationSessionID = try await mutationSessionID(
                            address.sessionID,
                            isCloudHosted: isCloudHosted
                        )
                        let result = try await desktopClient.sendMessage(
                            workspaceID: address.workspaceID,
                            sessionID: mutationSessionID,
                            message: optimisticMessage.content,
                            model: optimisticMessage.model,
                            isFastModeEnabled: optimisticMessage.isFastModeEnabled,
                            mode: optimisticMessage.mode,
                            reasoningEffort: optimisticMessage.reasoningEffort,
                            attemptID: optimisticMessage.id
                        )
                        await send(.messageSendResponse(address, result))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(
                            .messageSendResponse(
                                address,
                                .unknown(reason: "Delivery could not be determined.")
                            )
                        )
                    }
                }

            case let .messageSendResponse(address, result):
                guard var messages = state.optimisticMessagesBySession[address.sessionID],
                      let messageIndex = messages.firstIndex(where: {
                          $0.id == address.messageID && $0.status == .sending
                      }) else {
                    return .none
                }
                let optimisticMessage = messages[messageIndex]
                Logger.chat.info(
                    """
                    Mobile attempt \(address.messageID.uuidString) completed as \
                    \(Self.deliveryResultName(result))
                    """
                )
                if optimisticMessage.mode == .queued {
                    messages.remove(at: messageIndex)
                    state.optimisticMessagesBySession[address.sessionID] =
                        messages.isEmpty ? nil : messages
                    switch result {
                    case .accepted:
                        @Shared(.messageDrafts) var messageDrafts
                        $messageDrafts.withLock { drafts in
                            if drafts[address.sessionID]?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                == optimisticMessage.content {
                                drafts[address.sessionID] = nil
                            }
                        }
                    case .rejected(let reason):
                        state.destination = .alert(.failedToQueueMessage(message: reason))
                    case .unknown(let reason):
                        state.destination = .alert(.messageQueueUnconfirmed(message: reason))
                    }
                    if state.chat?.sessionID == address.sessionID {
                        refreshCurrentChat(state: &state)
                    }
                    return .none
                }
                messages[messageIndex].status = switch result {
                case .accepted:
                    .acceptedAwaitingObservation
                case .rejected:
                    .rejected
                case .unknown:
                    .unconfirmed
                }
                messages[messageIndex].deliveryDetail = result.reason
                if case .accepted(let messageID) = result {
                    messages[messageIndex].canonicalMessageID = messageID
                }
                state.optimisticMessagesBySession[address.sessionID] = messages
                guard state.chat?.sessionID == address.sessionID else {
                    return .none
                }
                if case .rejected = result {
                    state.chat?.endSendCycle(attemptID: address.messageID)
                }
                reconcileCanonicalMessages(
                    Array(state.chat?.messages ?? []),
                    state: &state
                )
                refreshCurrentChat(state: &state)
                return .none

            case let .chat(.messagesUpdated(messages)):
                reconcileCanonicalMessages(messages, state: &state)
                return .none

            case let .chat(.initialMessagesResponse(sessionID, messages)):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                reconcileCanonicalMessages(messages, state: &state)
                return markWorkspaceReadIfNeeded(
                    state,
                    selectedSession: state.chat?.session
                )

            case let .chat(.loadMessagesFailed(sessionID, error)):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                if let apiError = error as? CloudAPIClientError,
                   apiError.isAuthenticationFailure {
                    state.destination = .alert(
                        .cloudAuthenticationFailed(
                            message: apiError.localizedDescription
                        )
                    )
                    return .none
                }
                guard !DesktopClientError.isConnectionFailure(error) else {
                    return .none
                }

                state.destination = .alert(
                    .failedToLoadMessages(message: error.localizedDescription)
                )
                return .none

            case let .chat(.queuedMessages(.deleteResponse(
                sessionID,
                _,
                .failure(error)
            ))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to delete queued message: \(error)")
                state.destination = .alert(
                    .failedToDeleteQueuedMessage(message: error.localizedDescription)
                )
                return .none

            case let .chat(.queuedMessages(.beginEditResponse(
                sessionID,
                _,
                .failure(error)
            ))),
                 let .chat(.queuedMessages(.cancelEditResponse(sessionID, .failure(error)))),
                 let .chat(.queuedMessages(.finishEditResponse(
                    sessionID,
                    _,
                    .failure(error)
                 ))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to edit queued message: \(error)")
                state.destination = .alert(
                    .failedToEditQueuedMessage(message: error.localizedDescription)
                )
                return .none

            case let .chat(.queuedMessages(.reorderResponse(
                sessionID,
                .failure(error)
            ))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to reorder queued messages: \(error)")
                state.destination = .alert(
                    .failedToReorderQueuedMessages(message: error.localizedDescription)
                )
                return .none

            case let .chat(.queuedMessages(.resumeResponse(
                sessionID,
                .failure(error)
            ))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to resume queue: \(error)")
                state.destination = .alert(
                    .failedToResumeQueue(message: error.localizedDescription)
                )
                return .none

            case let .chat(.queuedMessages(.steerResponse(
                sessionID,
                _,
                .failure(error)
            ))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to steer queued message: \(error)")
                state.destination = .alert(
                    .failedToSteerQueuedMessage(message: error.localizedDescription)
                )
                return .none

            case let .chat(.voiceInput(.delegate(.failed(id, error)))):
                guard state.chat?.sessionID == id else {
                    return .none
                }

                Logger.chat.error("Failed to transcribe speech: \(error)")
                state.destination = .alert(
                    .failedToTranscribeSpeech(message: error.localizedDescription)
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
                guard !state.isQueuedMessageEditLocked else {
                    return .none
                }
                /// Session button was tapped, don't let a new active session switch it for the lifetime of this
                state.hasUserSelectedSession = true
                state.sessionIDAwaitingObservation = nil
                guard state.chat?.sessionID != session.id else {
                    return .none
                }
                state.chat = Chat.State(
                    session: session,
                    isCloudHosted: state.workspace.isCloudHosted
                )
                refreshCurrentChat(state: &state)
                return .none

            case .destination(.presented(.alert(.openSettings))):
                return .send(.delegate(.openSettings))

            case let .workspaceMutationFailed(error):
                state.isWorkspaceMutationInFlight = false
                state.destination = .alert(
                    .failedToUpdateWorkspace(message: error.localizedDescription)
                )
                return .none

            case .workspaceMutationUsedSQLiteFallback:
                state.isWorkspaceMutationInFlight = false
                state.destination = .alert(.workspaceMutationUsedSQLiteFallback)
                return .none

            case .workspaceMutationFinished:
                state.isWorkspaceMutationInFlight = false
                return .none

            case .workspacePinnedButtonTapped:
                guard !state.isWorkspaceMutationInFlight else {
                    return .none
                }
                state.isWorkspaceMutationInFlight = true
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
                guard !state.isWorkspaceMutationInFlight else {
                    return .none
                }
                let item = state.workspaceWithRepository
                guard item.workspace.status != status else {
                    return .none
                }
                state.isWorkspaceMutationInFlight = true
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
                guard !state.isWorkspaceMutationInFlight else {
                    return .none
                }
                state.isWorkspaceMutationInFlight = true
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

            case .binding,
                 .chat,
                 .delegate,
                 .destination:
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
                } else {
                    await send(.workspaceMutationFinished)
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

    private func reconcileCanonicalMessages(
        _ messages: [Message],
        state: inout State
    ) {
        guard var chat = state.chat else {
            return
        }
        let messages = if chat.isCloudHosted {
            messages
        } else {
            Self.transcriptMessages(messages)
        }

        let sessionID = chat.session.id
        let userMessages = messages.filter { $0.role == .user }
        var optimisticMessages = state.optimisticMessagesBySession[sessionID, default: []]
        var aliases = state.messageIDToBubbleID

        for message in userMessages {
            guard aliases[message.id] == nil else {
                continue
            }

            guard let optimisticIndex = optimisticMessages.firstIndex(where: {
                $0.mode == .sent
                    && ($0.canonicalMessageID == message.id
                        || message.turnID.flatMap(UUID.init(uuidString:)) == $0.id)
            }) else {
                continue
            }

            let optimisticMessage = optimisticMessages.remove(at: optimisticIndex)
            Logger.chat.info(
                """
                Reconciled canonical message \(message.id) with mobile attempt \
                \(optimisticMessage.id.uuidString) using canonical identity; \
                canonical turn \(message.turnID ?? "none")
                """
            )
            aliases[message.id] = optimisticMessage.id
            if let turnID = message.turnID {
                chat.observeCorrelatedTurn(
                    turnID,
                    attemptID: optimisticMessage.id
                )
            }
        }

        if optimisticMessages.isEmpty {
            state.optimisticMessagesBySession[sessionID] = nil
        } else {
            state.optimisticMessagesBySession[sessionID] = optimisticMessages
        }

        let didChangeAliases = aliases != state.messageIDToBubbleID
        state.messageIDToBubbleID = aliases
        chat.messageIDToBubbleID = aliases
        chat.optimisticMessages = optimisticMessages
        if didChangeAliases {
            chat.turns = Turn.parse(
                messages: messages,
                reusing: chat.turns ?? [],
                messageIDToBubbleID: aliases
            )
        }
        chat.updateRows()
        state.chat = chat
    }

    private static func transcriptMessages(_ messages: [Message]) -> [Message] {
        messages
            .filter { $0.sentAt != nil || $0.queueOrder == nil }
            .sorted { lhs, rhs in
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
    }

    private static func deliveryResultName(
        _ result: MessageDeliveryResult
    ) -> String {
        switch result {
        case .accepted:
            "accepted"
        case .rejected:
            "rejected"
        case .unknown:
            "unknown"
        }
    }

    private func refreshCurrentChat(state: inout State) {
        guard var chat = state.chat else {
            return
        }
        let aliases = state.messageIDToBubbleID
        let optimisticMessages =
            state.optimisticMessagesBySession[chat.sessionID, default: []]
        chat.messageIDToBubbleID = aliases
        chat.optimisticMessages = optimisticMessages
        chat.updateRows()
        state.chat = chat
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
        isCloudHosted: Bool,
        optimisticMessagesBySession: [Session.ID: [OptimisticMessage]],
        messageIDToBubbleID: [Message.ID: UUID]
    ) -> Chat.State? {
        if currentChat?.queuedMessages.isEditStartInFlight == true
            || currentChat?.queuedMessages.isEditing == true {
            return currentChat
        }

        let activeSessions = sessions.filter { !$0.isHidden }
        let includesCurrentChat = currentChat.map { currentChat in
            activeSessions.contains { $0.id == currentChat.sessionID }
        } ?? false
        let selectedChat: Chat.State?
        if let sessionIDAwaitingObservation,
           currentChat?.sessionID == sessionIDAwaitingObservation {
            selectedChat = currentChat
        } else if hasUserSelectedSession,
                  let currentChat,
                  includesCurrentChat {
            selectedChat = currentChat
        } else {
            // Prefer Conductor's active session, then fall back to the most recently updated session.
            let session = activeSessions.first { $0.id == workspaceActiveSessionID } /// Get the active session
                ?? (
                    isCloudHosted
                        ? activeSessions.first
                        : activeSessions.max {
                            ($0.updatedDate ?? .distantPast)
                                < ($1.updatedDate ?? .distantPast)
                        }
                )
            if session?.id == currentChat?.sessionID {
                selectedChat = currentChat
            } else {
                selectedChat = session.map {
                    Chat.State(
                        session: $0,
                        isCloudHosted: isCloudHosted
                    )
                }
            }
        }

        guard var selectedChat else {
            return nil
        }
        selectedChat.messageIDToBubbleID = messageIDToBubbleID
        selectedChat.optimisticMessages =
            optimisticMessagesBySession[selectedChat.sessionID, default: []]
        selectedChat.updateRows()
        return selectedChat
    }

    private func observeSessions(
        workspaceID: String,
        isCloudHosted: Bool
    ) -> Effect<Action> {
        if isCloudHosted {
            return observeCloudSessions(workspaceID: workspaceID)
        }
        return .run { send in
            await StreamObservation.observe {
                desktopClient.observeSessions(workspaceID: workspaceID)
            } onValue: { sessions in
                try await database.write { db in
                    try Session
                        .where { $0.workspaceID.eq(workspaceID) }
                        .delete()
                        .execute(db)

                    try Session.upsert { sessions }
                        .execute(db)
                }
                await send(.sessionSnapshotPersisted)
                await send(.loadSessionsResponse(.success(sessions)))
            } onFailure: { error in
                await send(.loadSessionsResponse(.failure(error)))
            }
        }
        .cancellable(id: CancelID.sessionObservation, cancelInFlight: true)
    }

    private func observeCloudSessions(
        workspaceID: String
    ) -> Effect<Action> {
        .merge(
            .run { send in
                do {
                    for try await snapshot in cloudAPIClient.observeSessions(
                        workspaceID: workspaceID
                    ) {
                        let sessions = try await database.write { database in
                            try CloudChatPersistence.persist(snapshot, in: database)
                        }
                        await send(.loadSessionsResponse(.success(sessions)))
                        await send(.sessionSnapshotPersisted)
                    }
                } catch {
                    guard !CloudAPIClientError.isRequestCancellation(error) else {
                        return
                    }
                    await send(.loadSessionsResponse(.failure(error)))
                }
            },
            .run { send in
                await StreamObservation.observe(
                    retrying: {
                        desktopClient.observeSessions(workspaceID: workspaceID)
                    },
                    retryDelays: [.seconds(10)]
                ) { desktopSessions in
                    let sessions = try await database.write { database in
                        try CloudChatPersistence.reconcileSessionVisibility(
                            from: desktopSessions,
                            workspaceID: workspaceID,
                            in: database
                        )
                    }
                    guard !sessions.isEmpty else {
                        return
                    }
                    await send(.loadSessionsResponse(.success(sessions)))
                    await send(.sessionSnapshotPersisted)
                } onFailure: { error in
                    Logger.chat.error(
                        "Failed to reconcile Cloud session visibility: \(error)"
                    )
                }
            }
        )
        .cancellable(id: CancelID.sessionObservation, cancelInFlight: true)
    }

    private func mutationSessionID(
        _ canonicalSessionID: Session.ID,
        isCloudHosted: Bool
    ) async throws -> String {
        if !isCloudHosted {
            return canonicalSessionID
        }
        let remoteSessionID = try await database.read { database in
            try CloudChatPersistence.remoteSessionID(
                for: canonicalSessionID,
                in: database
            )
        }
        guard let remoteSessionID else {
            throw CloudChatMutationRoutingError.missingSessionMetadata
        }
        return remoteSessionID
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

    private enum CancelID: Hashable {
        case sessionObservation
    }
}

private enum CloudChatMutationRoutingError: LocalizedError {
    case missingSessionMetadata

    var errorDescription: String? {
        "This Cloud chat has not finished loading. Try again shortly."
    }
}

private enum ConciseTranscriptCopyError: LocalizedError {
    case empty

    var errorDescription: String? {
        "This chat has no locally cached transcript."
    }
}

extension WorkspaceChat.Destination.State: Equatable { }

extension AlertState where Action == WorkspaceChat.Destination.Alert {
    static func cloudAuthenticationFailed(message: String) -> Self {
        AlertState {
            TextState("Cloud authentication failed")
        } actions: {
            ButtonState(action: .openSettings) {
                TextState("Open Settings")
            }

            ButtonState(role: .cancel) {
                TextState("Dismiss")
            }
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

    static func failedToCloseSession(message: String) -> Self {
        AlertState {
            TextState("Failed to close tab")
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

    static func failedToCopyTranscript(message: String) -> Self {
        AlertState {
            TextState("Failed to copy transcript")
        } message: {
            TextState(message)
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

    static func failedToSendMessage(message: String) -> Self {
        AlertState {
            TextState("Failed to send message")
        } message: {
            TextState(message)
        }
    }

    static func failedToQueueMessage(message: String) -> Self {
        AlertState {
            TextState("Message not queued")
        } message: {
            TextState(message)
        }
    }

    static func messageQueueUnconfirmed(message: String) -> Self {
        AlertState {
            TextState("Queue delivery unconfirmed")
        } message: {
            TextState(
                message
                    + " Check Conductor before trying again so the message is not queued twice."
            )
        }
    }

    static func failedToRenameSession(message: String) -> Self {
        AlertState {
            TextState("Failed to rename chat")
        } message: {
            TextState(message)
        }
    }

    static func failedToEditQueuedMessage(message: String) -> Self {
        AlertState {
            TextState("Failed to edit queued message")
        } message: {
            TextState(message)
        }
    }

    static func failedToDeleteQueuedMessage(message: String) -> Self {
        AlertState {
            TextState("Failed to delete queued message")
        } message: {
            TextState(message)
        }
    }

    static func failedToReorderQueuedMessages(message: String) -> Self {
        AlertState {
            TextState("Failed to reorder queued messages")
        } message: {
            TextState(message)
        }
    }

    static func failedToResumeQueue(message: String) -> Self {
        AlertState {
            TextState("Failed to resume queue")
        } message: {
            TextState(message)
        }
    }

    static func failedToSteerQueuedMessage(message: String) -> Self {
        AlertState {
            TextState("Failed to steer queued message")
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

    static func failedToTranscribeSpeech(message: String) -> Self {
        AlertState {
            TextState("Failed to transcribe speech")
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
        .navigationBarBackButtonHidden(store.isQueuedMessageEditLocked)
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
            } renameSession: { session in
                store.send(.renameSessionButtonTapped(session))
            } copyConciseTranscript: { session in
                store.send(.copyConciseTranscriptButtonTapped(session))
            } closeSession: { session in
                store.send(.closeSessionButtonTapped(session))
            } createSession: {
                store.send(.createSessionButtonTapped)
            }
            .disabled(store.isQueuedMessageEditLocked)
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
            isPresented: isRenameBranchPresented
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
        .alert(
            "Rename chat",
            isPresented: isRenameSessionPresented
        ) {
            TextField("Chat name", text: $store.sessionTitleDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .tint(.theme(.accent))

            Button("Rename", role: .confirm) {
                store.send(.renameSessionSubmitted)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!store.canRenameSession)

            Button("Cancel", role: .cancel) { }
        }
        .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        .sensoryFeedback(.error, trigger: store.destination) { _, destination in
            destination?.alert != nil
        }
        .sensoryFeedback(.selection, trigger: store.transcriptCopyCount)
        .onChange(of: store.transcriptCopyCount) {
            UIPasteboard.general.string = store.conciseTranscript
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

    private var isRenameBranchPresented: Binding<Bool> {
        Binding {
            store.destination == .renameBranch
        } set: {
            dismissDestination(isPresented: $0)
        }
    }

    private var isRenameSessionPresented: Binding<Bool> {
        Binding {
            store.destination == .renameSession
        } set: {
            dismissDestination(isPresented: $0)
        }
    }

    private func dismissDestination(isPresented: Bool) {
        if !isPresented {
            store.send(.destination(.dismiss))
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
        let renameSession: @MainActor (Session) -> Void
        let copyConciseTranscript: @MainActor (Session) -> Void
        let closeSession: @MainActor (Session) -> Void
        let createSession: @MainActor () -> Void
        @State private var scrollPosition = ScrollPosition(idType: Session.ID.self)

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(sessions) { session in
                        SessionButton(
                            session: session,
                            isSelected: session.id == selectedSessionID
                        ) {
                            action(session)
                        } rename: {
                            renameSession(session)
                        } copyConciseTranscript: {
                            copyConciseTranscript(session)
                        } close: {
                            closeSession(session)
                        }
                        // Applying this to the edge button keeps it from touching the screen edge
                        // when ScrollPosition scrolls to it.
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
        let rename: @MainActor () -> Void
        let copyConciseTranscript: @MainActor () -> Void
        let close: @MainActor () -> Void
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
                .contentShape(.interaction, Capsule())
            }
            .glassEffect(
                .clear
                    .tint(isSelected ? .theme(.highlight) : Color.clear)
            )
            .accessibilityIdentifier("workspace-chat.session.\(session.id)")
            .contextMenu {
                Button {
                    rename()
                } label: {
                    Label {
                        Text("Rename chat")
                    } icon: {
                        ColoredMenuImage(Lucide.pencil)
                    }
                }

                Button {
                    copyConciseTranscript()
                } label: {
                    Label {
                        Text("Copy concise transcript")
                    } icon: {
                        ColoredMenuImage(Lucide.copy)
                    }
                }

                Button(role: .destructive) {
                    close()
                } label: {
                    Label {
                        Text("Close tab")
                    } icon: {
                        ColoredMenuImage(Lucide.x, color: .theme(.destructive))
                    }
                }
            }
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
                    .persisted(
                        .snapshot(
                            content.messages.filter { $0.sessionID == sessionID }
                        ),
                    )
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
