//
//  CloudUITestScenario.swift
//  ConductorMain
//
//  Created by Gannon Prudomme on 7/27/26.
//

#if DEBUG
import ConductorCloud
import ConductorMobileData
import Dependencies
import Foundation
import SharedConductorData
import Sharing
import SQLiteData

public enum CloudUITestScenario: String, Sendable {
    case cloudAuthenticationFailure = "cloud-authentication-failure"
    case cloudConnectAndBrowse = "cloud-connect-and-browse"
    case cloudOnlyLoading = "cloud-only-loading"
    case localOnly = "local-only"

    public func install(in dependencies: inout DependencyValues) throws {
        let credential = LockIsolated<String?>(
            self == .localOnly ? nil : "fixture-api-key"
        )
        dependencies.cloudCredentialClient.loadAPIKey = {
            credential.value
        }
        dependencies.cloudCredentialClient.saveAPIKey = { apiKey in
            credential.withValue { $0 = apiKey }
        }
        dependencies.cloudCredentialClient.deleteAPIKey = {
            credential.withValue { $0 = nil }
        }
        let fixtureIdentity = self.fixtureIdentity
        dependencies.cloudAPIClient.getIdentity = {
            fixtureIdentity
        }
        dependencies.cloudAPIClient.validateIdentity = { apiKey in
            guard apiKey == "fixture-api-key" else {
                throw CloudAPIClientError.requestFailed(
                    statusCode: 401,
                    error: nil
                )
            }
            return fixtureIdentity
        }
        dependencies.cloudAPIClient.observeWorkspaces = {
            self.cloudObservation
        }
        dependencies.cloudAPIClient.observeSessions = { workspaceID in
            self.cloudSessionObservation(workspaceID: workspaceID)
        }
        dependencies.cloudAPIClient.observeTranscript = { sessionID in
            self.cloudTranscriptObservation(sessionID: sessionID)
        }
        dependencies.desktopClient.checkConnection = { _ in }
        dependencies.desktopClient.fetchModelSettings = {
            DesktopClient.ModelSettings(
                defaultModel: .gpt_5_6_sol,
                defaultReasoningEffort: .low,
                isFastModeEnabled: false
            )
        }
        dependencies.desktopClient.observeMessages = { workspaceID, sessionID in
            self.desktopMessageObservation(
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        }
        dependencies.desktopClient.observeSessions = { workspaceID in
            self.desktopSessionObservation(workspaceID: workspaceID)
        }
        dependencies.desktopClient.observeWorkspaces = {
            self.desktopObservation
        }
        dependencies.desktopClient.ping = { }

        @Shared(.cloudConfiguration) var cloudConfiguration
        @Shared(.desktopConnectionStatus) var desktopConnectionStatus
        @Shared(.desktopDisplayConfiguration) var desktopDisplayConfiguration
        @Shared(.desktopServerAddress) var desktopServerAddress
        $cloudConfiguration.withLock {
            $0 = self == .localOnly
                ? nil
                : CloudConfiguration(accountID: fixtureIdentity.cacheID)
        }
        $desktopConnectionStatus.withLock {
            $0 = hasLocalConnection ? .connected : .disconnected
        }
        $desktopDisplayConfiguration.withLock {
            $0 = hasLocalConnection
                ? DesktopClient.DisplayConfiguration(
                    name: "MacBook Pro",
                    icon: .laptop
                )
                : nil
        }
        $desktopServerAddress.withLock {
            $0 = hasLocalConnection ? "fixture-mac" : nil
        }

        let rows = fixtureRows
        try dependencies.defaultDatabase.write { database in
            try Repository.upsert { rows.repositories }.execute(database)
            try Workspace.upsert { rows.workspaces }.execute(database)
            if !rows.cloudMetadata.isEmpty {
                try CloudWorkspaceMetadata
                    .upsert { rows.cloudMetadata }
                    .execute(database)
            }
            if !rows.mobileStates.isEmpty {
                try MobileWorkspaceState
                    .upsert { rows.mobileStates }
                    .execute(database)
            }
        }
    }

    private var cloudObservation: AsyncThrowingStream<
        CloudWorkspaceSnapshot,
        any Error
    > {
        AsyncThrowingStream { continuation in
            switch self {
            case .cloudAuthenticationFailure:
                continuation.finish(
                    throwing: CloudAPIClientError.requestFailed(
                        statusCode: 401,
                        error: nil
                    )
                )

            case .cloudConnectAndBrowse:
                continuation.yield(fixtureCloudSnapshot)

            case .cloudOnlyLoading, .localOnly:
                break
            }
        }
    }

    private var desktopObservation: AsyncThrowingStream<
        WorkspaceListSnapshot,
        any Error
    > {
        AsyncThrowingStream { continuation in
            guard hasLocalConnection else {
                return
            }
            let rows = fixtureRows
            let mobileStates = Dictionary(
                uniqueKeysWithValues: rows.mobileStates.map {
                    ($0.workspaceID, $0)
                }
            )
            continuation.yield(
                WorkspaceListSnapshot(
                    repositories: rows.repositories,
                    workspaces: rows.workspaces.compactMap { workspace in
                        guard let mobileState = mobileStates[workspace.id] else {
                            return nil
                        }
                        return WorkspaceSnapshot(
                            workspace: workspace,
                            isWorking: mobileState.isWorking
                        )
                    },
                    pullRequests: Dictionary(
                        uniqueKeysWithValues: rows.mobileStates.compactMap {
                            mobileState in
                            guard let url = mobileState.pullRequestURL else {
                                return nil
                            }
                            return (
                                mobileState.workspaceID,
                                PullRequestSnapshot(
                                    url: url,
                                    isDraft: mobileState.isPullRequestDraft,
                                    isMerged: mobileState.isPullRequestMerged,
                                    mergeStateStatus: mobileState
                                        .pullRequestMergeStateStatus,
                                    checksStatus: mobileState
                                        .pullRequestChecksStatus
                                )
                            )
                        }
                    )
                )
            )
        }
    }

    private func cloudSessionObservation(
        workspaceID: Workspace.ID
    ) -> AsyncThrowingStream<CloudSessionSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            guard let workspace = fixtureCloudSnapshot.workspaces.first(where: {
                $0.id == workspaceID
            })?.workspace else {
                continuation.finish(throwing: FixtureError.unexpectedCloudWorkspace)
                return
            }
            let sessions = cloudSessions(workspaceID: workspaceID)
            continuation.yield(
                CloudSessionSnapshot(
                    accountID: fixtureIdentity.cacheID,
                    workspace: workspace,
                    sessions: sessions,
                    statuses: Dictionary(
                        uniqueKeysWithValues: sessions.map {
                            (
                                $0.id,
                                cloudSessionStatus(
                                    sessionID: $0.id,
                                    workspaceID: workspaceID
                                )
                            )
                        }
                    )
                )
            )
        }
    }

    private func cloudTranscriptObservation(
        sessionID: Session.ID
    ) -> AsyncThrowingStream<CloudTranscriptSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            guard let workspaceID = cloudWorkspaceID(sessionID: sessionID) else {
                continuation.finish(throwing: FixtureError.unexpectedCloudSession)
                return
            }
            continuation.yield(
                CloudTranscriptSnapshot(
                    accountID: fixtureIdentity.cacheID,
                    sessionID: sessionID,
                    status: cloudSessionStatus(
                        sessionID: sessionID,
                        workspaceID: workspaceID
                    ),
                    messages: cloudTranscript(sessionID: sessionID),
                    isFullSnapshot: true
                )
            )
        }
    }

    private func desktopSessionObservation(
        workspaceID: Workspace.ID
    ) -> AsyncThrowingStream<[Session], any Error> {
        AsyncThrowingStream { continuation in
            guard let workspace = fixtureWorkspace(workspaceID),
                  !workspace.isCloudHosted else {
                continuation.finish(throwing: FixtureError.desktopCloudFallback)
                return
            }
            continuation.yield([localSession(workspaceID: workspaceID)])
        }
    }

    private func desktopMessageObservation(
        workspaceID: Workspace.ID,
        sessionID: Session.ID
    ) -> AsyncThrowingStream<MessageSyncEvent, any Error> {
        AsyncThrowingStream { continuation in
            guard let workspace = fixtureWorkspace(workspaceID),
                  !workspace.isCloudHosted,
                  sessionID == localSession(workspaceID: workspaceID).id else {
                continuation.finish(throwing: FixtureError.desktopCloudFallback)
                return
            }
            continuation.yield(
                .snapshot([
                    Message(
                        id: "local-user-message",
                        sessionID: sessionID,
                        role: .user,
                        content: "Local controls remain available.",
                        createdAt: fixtureDate,
                        sentAt: fixtureDate
                    ),
                ])
            )
        }
    }

    private var fixtureRows: FixtureRows {
        let date = Date(timeIntervalSince1970: 1_783_555_200)
        let repository = Repository(
            id: "fixture-repository",
            createdAt: date,
            name: "Cloud fixtures",
            remoteURL: "https://github.com/example/fixtures.git",
            rootPath: "/tmp/cloud-fixtures",
            updatedAt: date
        )
        let cloudOnlyWorkspace = Workspace(
            id: "cloud-only",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: Workspace.conductorCloudHostingServerURL,
            repositoryID: repository.id,
            state: .initializing,
            updatedAt: date.addingTimeInterval(3),
            workspaceName: "Cloud only fixture"
        )
        let localDraftWorkspace = Workspace(
            id: "local-draft",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            hostingServerURL: hasCloudConnection
                ? Workspace.conductorCloudHostingServerURL
                : nil,
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(2),
            workspaceName: "Local draft fixture"
        )
        let localWorkingWorkspace = Workspace(
            id: "local-working",
            createdAt: date,
            derivedStatus: Workspace.Status.inProgress.rawValue,
            repositoryID: repository.id,
            state: .ready,
            updatedAt: date.addingTimeInterval(1),
            workspaceName: "Local working fixture"
        )
        let workspaces = hasLocalConnection
            ? hasCloudConnection
                ? [
                    cloudOnlyWorkspace,
                    localDraftWorkspace,
                    localWorkingWorkspace,
                ]
                : [localDraftWorkspace, localWorkingWorkspace]
            : [cloudOnlyWorkspace]
        let cloudMetadata = hasCloudConnection
            ? workspaces.filter(\.isCloudHosted).map {
                CloudWorkspaceMetadata(
                    workspaceID: $0.id,
                    accountID: fixtureIdentity.cacheID,
                    lastSeenGeneration: "fixture-generation"
                )
            }
            : []
        let mobileStates = hasLocalConnection
            ? [
                MobileWorkspaceState(
                    workspaceID: localDraftWorkspace.id,
                    isWorking: false,
                    pullRequest: PullRequestSnapshot(
                        url: "https://github.com/example/fixtures/pull/1",
                        isDraft: true,
                        isMerged: false
                    )
                ),
                MobileWorkspaceState(
                    workspaceID: localWorkingWorkspace.id,
                    isWorking: true
                ),
            ]
            : []
        return FixtureRows(
            cloudMetadata: cloudMetadata,
            mobileStates: mobileStates,
            repositories: [repository],
            workspaces: workspaces
        )
    }

    private var hasCloudConnection: Bool {
        self != .localOnly
    }

    private var hasLocalConnection: Bool {
        self == .cloudConnectAndBrowse || self == .localOnly
    }

    private var fixtureDate: Date {
        Date(timeIntervalSince1970: 1_783_555_200)
    }

    private func localSession(
        workspaceID: Workspace.ID
    ) -> Session {
        Session(
            id: "local-session-\(workspaceID)",
            workspaceID: workspaceID,
            title: "Local session",
            agentType: .codex,
            isHidden: false,
            createdAt: fixtureDate.ISO8601Format(),
            updatedAt: fixtureDate.ISO8601Format(),
            lastUserMessageAt: fixtureDate.ISO8601Format(),
            status: .idle,
            model: .gpt_5_6_sol,
            unreadCount: 0,
            freshlyCompacted: 0,
            contextTokenCount: 0
        )
    }

    private func fixtureWorkspace(
        _ workspaceID: Workspace.ID
    ) -> Workspace? {
        fixtureRows.workspaces.first { $0.id == workspaceID }
    }

    private func cloudSessions(
        workspaceID: Workspace.ID
    ) -> [CloudSession] {
        let sessionIDs: [Session.ID]
        switch workspaceID {
        case "cloud-only":
            sessionIDs = ["cloud-session-working", "cloud-session-idle"]
        case "local-draft":
            sessionIDs = ["enriched-cloud-session"]
        default:
            sessionIDs = []
        }

        return sessionIDs.map { sessionID in
            CloudSession(
                id: sessionID,
                deepLink: URL(
                    string: "https://conductor.build/sessions/\(sessionID)"
                ) ?? CloudAPIClient.productionBaseURL,
                name: sessionID == "cloud-session-working"
                    ? "Working session"
                    : sessionID == "cloud-session-idle"
                        ? "Idle session"
                        : "Cloud-enriched session",
                model: Session.Model.gpt_5_6_sol.rawValue,
                effort: Session.ReasoningEffort.low.rawValue,
                fastMode: false
            )
        }
    }

    private func cloudWorkspaceID(
        sessionID: Session.ID
    ) -> Workspace.ID? {
        fixtureCloudSnapshot.workspaces.first { item in
            cloudSessions(workspaceID: item.id).contains {
                $0.id == sessionID
            }
        }?.id
    }

    private func cloudSessionStatus(
        sessionID: Session.ID,
        workspaceID: Workspace.ID
    ) -> CloudSessionStatusResponse {
        CloudSessionStatusResponse(
            workspaceID: workspaceID,
            sessionID: sessionID,
            status: sessionID == "cloud-session-working"
                ? .working
                : .idle,
            updatedAt: fixtureDate
        )
    }

    private func cloudTranscript(
        sessionID: Session.ID
    ) -> [CloudTranscriptMessage] {
        guard sessionID == "cloud-session-working" else {
            return [
                CloudTranscriptMessage(
                    id: "\(sessionID)-user",
                    sessionID: sessionID,
                    sessionIndex: 1,
                    type: .init(rawValue: "event"),
                    content: .object([
                        "type": .string("userMessage"),
                        "message": .string("Cached Cloud transcript"),
                        "turnId": .string("\(sessionID)-turn"),
                    ]),
                    receivedAt: fixtureDate
                ),
                agentTranscriptMessage(
                    id: "\(sessionID)-assistant",
                    sessionID: sessionID,
                    sessionIndex: 2,
                    event: [
                        "type": .string("item.completed"),
                        "item": .object([
                            "id": .string("\(sessionID)-assistant-item"),
                            "type": .string("agentMessage"),
                            "text": .string("This session came from the Cloud API."),
                        ]),
                    ]
                ),
            ]
        }

        return [
            CloudTranscriptMessage(
                id: "cloud-user",
                sessionID: sessionID,
                sessionIndex: 1,
                type: .init(rawValue: "event"),
                content: .object([
                    "type": .string("userMessage"),
                    "message": .string("Inspect the Cloud workspace."),
                    "turnId": .string("cloud-turn"),
                ]),
                receivedAt: fixtureDate
            ),
            agentTranscriptMessage(
                id: "cloud-assistant",
                sessionID: sessionID,
                sessionIndex: 2,
                event: [
                    "type": .string("item.completed"),
                    "item": .object([
                        "id": .string("assistant-item"),
                        "type": .string("agentMessage"),
                        "text": .string("I will inspect it now."),
                    ]),
                ]
            ),
            agentTranscriptMessage(
                id: "cloud-command-start",
                sessionID: sessionID,
                sessionIndex: 3,
                event: [
                    "type": .string("item.started"),
                    "item": .object([
                        "id": .string("command-item"),
                        "type": .string("commandExecution"),
                        "command": .string("git status --short"),
                    ]),
                ]
            ),
            agentTranscriptMessage(
                id: "cloud-command-result",
                sessionID: sessionID,
                sessionIndex: 4,
                event: [
                    "type": .string("item.completed"),
                    "item": .object([
                        "id": .string("command-item"),
                        "type": .string("commandExecution"),
                        "status": .string("completed"),
                        "exitCode": .integer(0),
                        "aggregatedOutput": .string("Working tree clean"),
                    ]),
                ]
            ),
            agentTranscriptMessage(
                id: "cloud-error",
                sessionID: sessionID,
                sessionIndex: 5,
                event: [
                    "type": .string("turn.failed"),
                    "message": .string("Synthetic Cloud fixture error"),
                ]
            ),
        ]
    }

    private func agentTranscriptMessage(
        id: CloudTranscriptMessage.ID,
        sessionID: Session.ID,
        sessionIndex: Double,
        event: [String: CloudJSONValue]
    ) -> CloudTranscriptMessage {
        CloudTranscriptMessage(
            id: id,
            sessionID: sessionID,
            sessionIndex: sessionIndex,
            type: .init(rawValue: "event"),
            content: .object([
                "type": .string("agent"),
                "turnId": .string("cloud-turn"),
                "rawPayload": .object([
                    "event": .object(event),
                ]),
            ]),
            receivedAt: fixtureDate.addingTimeInterval(sessionIndex)
        )
    }

    private var fixtureCloudSnapshot: CloudWorkspaceSnapshot {
        let project = CloudProject(
            id: "fixture-project",
            name: "Cloud fixtures",
            gitRemote: "https://github.com/example/fixtures.git"
        )
        let workspaces = fixtureRows.workspaces
            .filter(\.isCloudHosted)
            .map {
            CloudWorkspace(
                id: $0.id,
                name: $0.workspaceName ?? $0.id,
                createdAt: $0.createdAt,
                lastActivityAt: $0.updatedAt
            )
            }
        return CloudWorkspaceSnapshot(
            accountID: fixtureIdentity.cacheID,
            projects: [project],
            statuses: Dictionary(
                uniqueKeysWithValues: workspaces.map {
                    (
                        $0.id,
                        CloudWorkspaceStatusResponse(
                            workspaceID: $0.id,
                            status: $0.id == "cloud-only"
                                ? .initializing
                                : .ready
                        )
                    )
                }
            ),
            workspaces: workspaces.map {
                CloudProjectWorkspace(project: project, workspace: $0)
            }
        )
    }

    private var fixtureIdentity: CloudIdentity {
        CloudIdentity(
            userID: "fixture-account",
            authMethod: .apiKey
        )
    }

    private struct FixtureRows {
        var cloudMetadata: [CloudWorkspaceMetadata]
        var mobileStates: [MobileWorkspaceState]
        var repositories: [Repository]
        var workspaces: [Workspace]
    }

    private enum FixtureError: Error {
        case desktopCloudFallback
        case unexpectedCloudSession
        case unexpectedCloudWorkspace
    }
}
#endif
