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

        // TODO: Ideally this would be non-nil but couldn't figure out a good way to achieve it
        var chat: Chat.State?
        var mutationRoute: WorkspaceMutationRoute?
        var source: WorkspaceSource

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
        var conciseTranscript = ""
        var transcriptCopyCount = 0
        var initialPromptConflictHandoffID: UUID?
        var renamingSession: Session?
        var sessionTitleDraft = ""

        @FetchAll public var activeSessions: [Session]
        @FetchAll public var archivedSessions: [Session]
        @FetchAll var mutationOutcomes: [CloudMutationOutcome]
        @FetchOne public var workspaceWithRepository: WorkspaceWithRepository

        public init(
            workspaceWithRepository: WorkspaceWithRepository,
            selectedSessionID: Session.ID? = nil,
            selectedModel: Session.Model? = nil,
            selectedReasoningEffort: Session.ReasoningEffort? = nil,
            shouldFocusMessageField: Bool = false
        ) {
            let workspace = workspaceWithRepository.workspace
            @Shared(.cloudConfiguration) var cloudConfiguration
            self.source = workspaceWithRepository.source
            self.mutationRoute = workspaceWithRepository.mutationRoute(
                cloudConfiguration: cloudConfiguration
            )
            self._workspaceWithRepository = FetchOne(
                wrappedValue: workspaceWithRepository,
                WorkspaceWithRepository.all(workspaceID: workspace.id),
                animation: .default
            )

            self.chat = nil

            self._archivedSessions = if source == .cloud {
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

            let activeSessions = if source == .cloud {
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
            self._mutationOutcomes = FetchAll(
                wrappedValue: [],
                CloudMutationOutcome
                    .where {
                        $0.owningFeature.eq(
                            CloudMutationOutcome.OwningFeature
                                .workspaceChat(workspaceID: workspace.id)
                                .rawValue
                        )
                            && $0.consumedAt.is(nil)
                    }
                    .order(by: \.createdAt)
            )

            let session = self.activeSessions.first {
                $0.id == selectedSessionID
            } ?? self.activeSessions.first {
                $0.id == workspace.activeSessionID
            } ?? self.activeSessions.first

            self.chat = session.map {
                Chat.State(
                    session: $0,
                    isCloudHosted: source == .cloud,
                    mutationRoute: $0.status.rawValue == "creating"
                        ? nil
                        : mutationRoute,
                    selectedModel: selectedModel,
                    selectedReasoningEffort: selectedReasoningEffort,
                    shouldFocusMessageField: shouldFocusMessageField
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

        var canRenameSession: Bool {
            let title = sessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && title != renamingSession?.title
        }

        var sessionObservationWorkspaceID: Workspace.ID {
            workspaceWithRepository.cloudMetadata?.remoteWorkspaceID
                ?? workspace.id
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
            case appendInitialPrompt
            case discardInitialPrompt
            case openSettings
            case replaceInitialPrompt
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
        case copyConciseTranscriptButtonTapped(Session)
        case copyConciseTranscriptResponse(Result<String, any Error>)
        case createSessionButtonTapped
        case createSessionResponse(
            Result<WorkspaceSessionCreationResult, any Error>
        )
        case destination(PresentationAction<Destination.Action>)
        case loadSessionsResponse(Result<[Session], any Error>)
        case mutationOutcomesUpdated([CloudMutationOutcome])
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

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date.now) var now
    @Dependency(\.cloudAPIClient) var cloudAPIClient
    @Dependency(\.desktopClient) var desktopClient
    @Dependency(\.workspaceMutationClient) var workspaceMutationClient

    public init() { }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                let workspace = state.$workspaceWithRepository
                // The workspace and sessions arrive through independent sockets. Reconcile when
                // either one changes so an active-session-only update cannot leave chat stale.
                var observations: [Effect<Action>] = [
                    .publisher {
                        workspace.publisher
                            .map(\.workspace.activeSessionID)
                            .removeDuplicates()
                            .dropFirst()
                            .map(Action.activeSessionIDChanged)
                    },
                    observeSessions(
                        workspaceID: state.sessionObservationWorkspaceID,
                        isCloudHosted: state.source == .cloud
                    ),
                ]
                if state.source == .cloud {
                    observations.append(observeMutationOutcomes(state))
                }
                return .merge(observations)

            case let .activeSessionIDChanged(activeSessionID):
                // The workspace and session snapshots are persisted independently. Do not let a
                // workspace update clear or replace the chat while SQLite is still catching up.
                guard !state.hasUserSelectedSession,
                      !state.isQueuedMessageEditLocked,
                      let activeSessionID,
                      let activeSession = state.activeSessions.first(where: {
                          $0.id == activeSessionID
                      }),
                      state.chat?.sessionID != activeSessionID else {
                    return .none
                }
                state.chat = Chat.State(
                    session: activeSession,
                    isCloudHosted: state.source == .cloud,
                    mutationRoute: state.mutationRoute
                )
                return .none

            case .archiveWorkspaceButtonTapped:
                guard let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canArchiveWorkspace else {
                    return .none
                }
                return .run {
                    [mutationRoute, workspaceID = state.workspace.id] send in
                    await send(
                        .archiveWorkspaceResponse(
                            Result {
                                _ = try await workspaceMutationClient
                                    .archiveWorkspace(
                                        route: mutationRoute,
                                        canonicalWorkspaceID: workspaceID
                                    )
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
                        sessions: state.archivedSessions,
                        activeSessions: state.activeSessions,
                        mutationRoute: state.mutationRoute
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

            case let .closeSessionButtonTapped(session):
                guard let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canArchiveSession else {
                    return .none
                }
                return .run { [mutationRoute, session] send in
                    await send(
                        .closeSessionResponse(
                            Result {
                                _ = try await workspaceMutationClient
                                    .archiveSession(
                                        route: mutationRoute,
                                        session: session
                                    )
                            }
                        )
                    )
                }

            case let .closeSessionResponse(.failure(error)):
                Logger.chat.error("Failed to close session: \(error)")
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
                guard let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canCreateSession else {
                    return .none
                }

                state.isCreatingSession = true
                state.sessionIDsBeforeCreation = Set(state.activeSessions.map(\.id))
                return .run {
                    [
                        fallbackAgent = state.chat?.session.agentType ?? .claude,
                        mutationRoute,
                        workspaceID = state.workspace.id,
                    ] send in
                    await send(
                        .createSessionResponse(
                            Result {
                                try await workspaceMutationClient.createSession(
                                    route: mutationRoute,
                                    canonicalWorkspaceID: workspaceID,
                                    fallbackAgent: fallbackAgent
                                )
                            }
                        )
                    )
                }

            case let .createSessionResponse(.success(result)):
                let session = result.session
                let hasObservedSession = state.sessionIDsBeforeCreation == nil
                state.hasUserSelectedSession = true
                state.isCreatingSession = false
                state.sessionIDAwaitingObservation =
                    result.attemptID == nil && !hasObservedSession
                        ? session.id
                        : nil
                state.sessionIDsBeforeCreation = nil
                if !state.isQueuedMessageEditLocked,
                   state.chat?.sessionID != session.id {
                    state.chat = Chat.State(
                        session: session,
                        isCloudHosted: state.source == .cloud,
                        mutationRoute: result.attemptID == nil
                            ? state.mutationRoute
                            : nil,
                        shouldFocusMessageField: true
                    )
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
                            isCloudHosted: state.source == .cloud,
                            mutationRoute: state.mutationRoute,
                            shouldFocusMessageField: true
                        )
                    }
                }
                if sessions.contains(where: { $0.id == state.sessionIDAwaitingObservation }) {
                    state.sessionIDAwaitingObservation = nil
                }
                state.chat = Self.selectedChat(
                    afterReceiving: sessions,
                    currentChat: state.chat,
                    workspaceActiveSessionID: state.workspace.activeSessionID,
                    hasUserSelectedSession: state.hasUserSelectedSession,
                    sessionIDAwaitingObservation: state.sessionIDAwaitingObservation,
                    isCloudHosted: state.source == .cloud,
                    mutationRoute: state.mutationRoute
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

            case let .mutationOutcomesUpdated(outcomes):
                guard let outcome = outcomes.first,
                      outcome.kind
                        == CloudMutationOutcome.Kind.rejectedMutation.rawValue,
                      let rejection = try? outcome.decodedPayload(
                        as: CloudMutationRejectionPayload.self
                      ) else {
                    return .none
                }
                state.destination = .alert(
                    .failedToUpdateWorkspace(message: rejection.message)
                )
                return .run { [outcomeID = outcome.outcomeID] _ in
                    try await database.write { database in
                        try CloudMutationOutcome
                            .find(outcomeID)
                            .update {
                                $0.consumedAt = #bind(Date())
                            }
                            .execute(database)
                    }
                }

            case let .renameSessionButtonTapped(session):
                guard state.mutationRoute?.capabilities.canRenameSession
                    == true else {
                    return .none
                }
                state.renamingSession = session
                state.sessionTitleDraft = session.title ?? ""
                state.destination = .renameSession
                return .none

            case .renameSessionSubmitted:
                guard state.canRenameSession,
                      let session = state.renamingSession,
                      let mutationRoute = state.mutationRoute,
                      mutationRoute.capabilities.canRenameSession else {
                    return .none
                }
                let title = state.sessionTitleDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                state.sessionTitleDraft = title
                state.renamingSession = nil
                state.destination = nil
                return .run { [mutationRoute, session, title] send in
                    await send(
                        .renameSessionResponse(
                            Result {
                                _ = try await workspaceMutationClient
                                    .renameSession(
                                        route: mutationRoute,
                                        session: session,
                                        title: title
                                    )
                            }
                        )
                    )
                }

            case let .renameSessionResponse(.failure(error)):
                Logger.chat.error("Failed to rename session: \(error)")
                state.destination = .alert(
                    .failedToRenameSession(message: error.localizedDescription)
                )
                return .none

            case .sessionSnapshotPersisted:
                state.hasPersistedInitialSessionSnapshot = true
                return .none

            case let .chat(.initialMessagesResponse(sessionID, _)):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }
                return markWorkspaceReadIfNeeded(
                    state,
                    selectedSession: state.chat?.session
                )

            case let .chat(.loadMessagesFailed(error)):
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

            case let .chat(.cloudMutationRejected(rejection)):
                state.destination = .alert(
                    .failedToUpdateWorkspace(message: rejection.message)
                )
                return .none

            case let .chat(.sendMessageResponse(sessionID, _, .failure(error))):
                guard state.chat?.sessionID == sessionID else {
                    return .none
                }

                Logger.chat.error("Failed to send message: \(error)")
                state.destination = .alert(
                    .failedToSendMessage(message: error.localizedDescription)
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

            case let .chat(.initialPromptConflictDetected(handoffID)):
                state.initialPromptConflictHandoffID = handoffID
                state.destination = .alert(.initialPromptConflict)
                return .none

            case let .chat(
                .initialPromptRejectionConflictDetected(handoffID)
            ):
                state.initialPromptConflictHandoffID = handoffID
                state.destination = .alert(.initialPromptRejectionConflict)
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
                    isCloudHosted: state.source == .cloud,
                    mutationRoute: state.mutationRoute
                )
                return .none

            case .destination(.presented(.alert(.openSettings))):
                return .send(.delegate(.openSettings))

            case .destination(.presented(.alert(.replaceInitialPrompt))):
                return resolveInitialPromptConflict(
                    choice: .replace,
                    state: &state
                )

            case .destination(.presented(.alert(.appendInitialPrompt))):
                return resolveInitialPromptConflict(
                    choice: .append,
                    state: &state
                )

            case .destination(.presented(.alert(.discardInitialPrompt))):
                return resolveInitialPromptConflict(
                    choice: .discard,
                    state: &state
                )

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

            case .binding,
                 .chat,
                 .closeSessionResponse,
                 .delegate,
                 .destination,
                 .renameSessionResponse:
                return .none

            }
        }
        .ifLet(\.chat, action: \.chat) {
            Chat()
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func resolveInitialPromptConflict(
        choice: InitialPromptConflictChoice,
        state: inout State
    ) -> Effect<Action> {
        guard let handoffID = state.initialPromptConflictHandoffID else {
            return .none
        }
        state.initialPromptConflictHandoffID = nil
        state.destination = nil
        return .send(
            .chat(.resolveInitialPromptConflict(handoffID, choice))
        )
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
        mutationRoute: WorkspaceMutationRoute?
    ) -> Chat.State? {
        if currentChat?.queuedMessages.isEditStartInFlight == true
            || currentChat?.queuedMessages.isEditing == true {
            return currentChat
        }

        let activeSessions = sessions.filter { !$0.isHidden } // Archived sessions are displayed separately and cannot remain selected in the chat.
        if let sessionIDAwaitingObservation,
           currentChat?.sessionID == sessionIDAwaitingObservation {
            return currentChat
        } else if hasUserSelectedSession,
           let currentChat,
           let selectedSession = activeSessions.first(where: {
               $0.id == currentChat.sessionID
           }) {
            // Preserve a reconciled or explicit selection instead of resetting it on every snapshot.
            if currentChat.mutationRoute == nil,
               selectedSession.status.rawValue != "creating" {
                return Chat.State(
                    session: selectedSession,
                    isCloudHosted: isCloudHosted,
                    mutationRoute: mutationRoute
                )
            }
            return currentChat
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
            // Avoid rebuilding the current chat when the selected session has not changed.
            let canReuseCurrentChat = session?.id == currentChat?.sessionID
            guard !canReuseCurrentChat else {
                return currentChat
            }
            return session.map {
                Chat.State(
                    session: $0,
                    isCloudHosted: isCloudHosted,
                    mutationRoute: mutationRoute
                )
            }
        }
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

    private func observeCloudSessions(
        workspaceID: String
    ) -> Effect<Action> {
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
            } catch is CancellationError {
                return
            } catch {
                await send(.loadSessionsResponse(.failure(error)))
            }
        }
    }

    private func observeMutationOutcomes(
        _ state: State
    ) -> Effect<Action> {
        .publisher {
            state.$mutationOutcomes.publisher
                .removeDuplicates()
                .map(Action.mutationOutcomesUpdated)
        }
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
    static var initialPromptConflict: Self {
        AlertState {
            TextState("Use the workspace prompt?")
        } actions: {
            ButtonState(action: .replaceInitialPrompt) {
                TextState("Replace and send")
            }
            ButtonState(action: .appendInitialPrompt) {
                TextState("Append and send")
            }
            ButtonState(
                role: .destructive,
                action: .discardInitialPrompt
            ) {
                TextState("Discard")
            }
        } message: {
            TextState(
                "This chat already has a draft. Choose how to handle the prompt used to create the workspace."
            )
        }
    }

    static var initialPromptRejectionConflict: Self {
        AlertState {
            TextState("Restore the rejected prompt?")
        } actions: {
            ButtonState(action: .replaceInitialPrompt) {
                TextState("Replace draft")
            }
            ButtonState(action: .appendInitialPrompt) {
                TextState("Append to draft")
            }
            ButtonState(action: .discardInitialPrompt) {
                TextState("Keep current")
            }
        } message: {
            TextState(
                "Cloud rejected the initial message after the draft changed. Choose which text to keep."
            )
        }
    }

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
                canCreateSession: store.mutationRoute.capabilities.canCreateSession,
                canRenameSession: store.mutationRoute.capabilities.canRenameSession,
                canArchiveSession: store.mutationRoute.capabilities.canArchiveSession,
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
        let canCreateSession: Bool
        let canRenameSession: Bool
        let canArchiveSession: Bool
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
                            isSelected: session.id == selectedSessionID,
                            canRename: canRenameSession,
                            canArchive: canArchiveSession
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

                    if canCreateSession {
                        NewSessionButton(
                            isCreatingSession: isCreatingSession,
                            action: createSession
                        )
                        .padding(.leading, sessions.isEmpty ? 16 : 0)
                        .padding(.trailing, 16)
                    }
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
        let canRename: Bool
        let canArchive: Bool
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
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .disabled(session.status.rawValue == "creating")
            .contextMenu {
                if canRename {
                    Button {
                        rename()
                    } label: {
                        Label {
                            Text("Rename chat")
                        } icon: {
                            ColoredMenuImage(Lucide.pencil)
                        }
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

                if canArchive {
                    Button(role: .destructive) {
                        close()
                    } label: {
                        Label {
                            Text("Close tab")
                        } icon: {
                            ColoredMenuImage(
                                Lucide.x,
                                color: .theme(.destructive)
                            )
                        }
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
                    .snapshot(
                        content.messages.filter { $0.sessionID == sessionID }
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
