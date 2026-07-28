//
//  CloudAPIClient.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct CloudAPIClient: Sendable {
    public var archiveSession: @Sendable (
        _ expectedAccountID: String,
        _ sessionID: String
    ) async throws -> CloudArchiveSessionResponse
    public var archiveWorkspace: @Sendable (
        _ expectedAccountID: String,
        _ workspaceID: String
    ) async throws -> CloudArchiveWorkspaceResponse
    public var cancelSession: @Sendable (
        _ expectedAccountID: String,
        _ sessionID: String
    ) async throws -> CloudCancelSessionResponse
    public var createSession: @Sendable (
        _ expectedAccountID: String,
        _ request: CloudCreateSessionRequest
    ) async throws -> CloudSession
    public var createWorkspace: @Sendable (
        _ expectedAccountID: String,
        _ request: CloudCreateWorkspaceRequest
    ) async throws -> CloudCreateWorkspaceResponse
    public var createWorkspaceAfterPreflight: @Sendable (
        _ expectedAccountID: String,
        _ request: CloudCreateWorkspaceRequest,
        _ persistBaseline: @escaping @Sendable (CloudWorkspaceSnapshot) async throws -> Void
    ) async throws -> CloudCreateWorkspaceResponse
    /// `GET /me`
    public var getIdentity: @Sendable () async throws -> CloudIdentity
    public var observeSessions: @Sendable (
        _ workspaceID: String
    ) -> AsyncThrowingStream<CloudWorkspaceSessionSnapshot, any Error> = { _ in
        .finished()
    }
    public var observeTranscript: @Sendable (
        _ sessionID: String,
        _ checkpoint: CloudTranscriptCheckpoint?
    ) -> AsyncThrowingStream<CloudTranscriptUpdate, any Error> = { _, _ in
        .finished()
    }
    public var observeWorkspaces: @Sendable () -> AsyncThrowingStream<
        CloudWorkspaceSnapshot,
        any Error
    > = {
        .finished()
    }
    public var renameSession: @Sendable (
        _ expectedAccountID: String,
        _ sessionID: String,
        _ request: CloudRenameSessionRequest
    ) async throws -> CloudSession
    public var sendMessage: @Sendable (
        _ expectedAccountID: String,
        _ sessionID: String,
        _ request: CloudSendMessageRequest
    ) async throws -> CloudSendMessageResponse
    /// `GET /me` with an unsaved Settings candidate.
    public var validateIdentity: @Sendable (
        _ apiKey: String
    ) async throws -> CloudIdentity
}

public enum CloudAPIClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case missingCredential
    case unexpectedAccount
    case requestFailed(statusCode: Int, error: CloudStructuredError?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Conductor Cloud returned an invalid response."

        case .missingCredential:
            "Enter a Conductor API key in Settings."

        case .unexpectedAccount:
            "The Conductor Cloud credential belongs to a different account."

        case let .requestFailed(statusCode, error):
            error?.userMessage ?? "Conductor Cloud returned HTTP \(statusCode)."
        }
    }

    public var isAuthenticationFailure: Bool {
        guard case let .requestFailed(statusCode, _) = self else {
            return self == .missingCredential
        }
        return statusCode == 401 || statusCode == 403
    }

    public var isRetryableObservationFailure: Bool {
        switch self {
        case .invalidResponse, .missingCredential, .unexpectedAccount:
            return false

        case let .requestFailed(statusCode, error):
            if error?.retryable == false {
                return false
            }
            return error?.retryable == true || (500..<600).contains(statusCode)
        }
    }

    public static func shouldRetryObservation(after error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let apiError = error as? Self {
            return apiError.isRetryableObservationFailure
        }
        return false
    }

    public static func isRequestCancellation(_ error: any Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    fileprivate var isInvalidCursorFailure: Bool {
        guard case let .requestFailed(statusCode, error) = self else {
            return false
        }
        return statusCode == 400 && error?.code == "invalid_cursor"
    }
}

extension CloudAPIClient: DependencyKey {
    public static let productionBaseURL: URL = {
        guard let url = URL(string: "https://api.conductor.build") else {
            preconditionFailure("The fixed Conductor Cloud base URL must be valid.")
        }
        return url
    }()

    public static let userAgent = "ConductorMobileUnofficial/0.1 (iOS)"

    public static var liveValue: Self {
        live(baseURL: productionBaseURL) {
            @Dependency(\.cloudCredentialClient) var credentials
            guard let apiKey = try await credentials.loadAPIKey() else {
                throw CloudAPIClientError.missingCredential
            }
            return apiKey
        }
    }

    public static func live(
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> Self {
        Self(
            archiveSession: { expectedAccountID, sessionID in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudArchiveSessionResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions", sessionID, "archive"],
                    method: "POST",
                    apiKey: key
                )
            },
            archiveWorkspace: { expectedAccountID, workspaceID in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudArchiveWorkspaceResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "workspaces", workspaceID, "archive"],
                    method: "POST",
                    apiKey: key
                )
            },
            cancelSession: { expectedAccountID, sessionID in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudCancelSessionResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions", sessionID, "cancel"],
                    method: "POST",
                    apiKey: key
                )
            },
            createSession: { expectedAccountID, requestBody in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudSession.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions"],
                    method: "POST",
                    body: try JSONEncoder().encode(requestBody),
                    apiKey: key
                )
            },
            createWorkspace: { expectedAccountID, requestBody in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudCreateWorkspaceResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "workspaces"],
                    method: "POST",
                    body: try JSONEncoder().encode(requestBody),
                    apiKey: key
                )
            },
            createWorkspaceAfterPreflight: {
                expectedAccountID,
                requestBody,
                persistBaseline in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                let snapshot = try await loadWorkspaceInventory(
                    accountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: key
                )
                try await persistBaseline(snapshot)
                return try await request(
                    CloudCreateWorkspaceResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "workspaces"],
                    method: "POST",
                    body: try JSONEncoder().encode(requestBody),
                    apiKey: key
                )
            },
            getIdentity: {
                try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: try await requiredAPIKey(from: apiKey)
            )
            },
            observeSessions: { workspaceID in
                sessionStream(
                    workspaceID: workspaceID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            },
            observeTranscript: { sessionID, checkpoint in
                transcriptStream(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            },
            observeWorkspaces: {
                workspaceStream(baseURL: baseURL, apiKey: apiKey)
            },
            renameSession: { expectedAccountID, sessionID, requestBody in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudSession.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions", sessionID, "rename"],
                    method: "POST",
                    body: try JSONEncoder().encode(requestBody),
                    apiKey: key
                )
            },
            sendMessage: { expectedAccountID, sessionID, requestBody in
                let key = try await verifiedAPIKey(
                    expectedAccountID: expectedAccountID,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return try await request(
                    CloudSendMessageResponse.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions", sessionID, "messages"],
                    method: "POST",
                    body: try JSONEncoder().encode(requestBody),
                    apiKey: key
                )
            },
            validateIdentity: { candidateAPIKey in
                try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: candidateAPIKey
            )
            }
        )
    }

    private static func sessionStream(
        workspaceID: String,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudWorkspaceSessionSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                @Dependency(\.continuousClock) var clock

                var cachedAPIKey: String?
                var identity: CloudIdentity?
                var previousSnapshot: CloudWorkspaceSessionSnapshot?
                var retryDelay = Duration.seconds(1)
                var statuses: [CloudSession.ID: CloudSessionStatusResponse] = [:]

                do {
                    while !Task.isCancelled {
                        do {
                            let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                            if cycleAPIKey != cachedAPIKey {
                                cachedAPIKey = cycleAPIKey
                                identity = nil
                                previousSnapshot = nil
                                statuses.removeAll()
                            }

                            let cycleIdentity = try await loadIdentity(
                                identity: &identity,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                            let workspace = try await request(
                                CloudWorkspace.self,
                                baseURL: baseURL,
                                path: ["v0", "workspaces", workspaceID],
                                apiKey: cycleAPIKey
                            )
                            guard workspace.id == workspaceID else {
                                throw CloudAPIClientError.invalidResponse
                            }

                            let sessions = try await allPages(pageSize: 100) { limit, offset in
                                try await request(
                                    CloudPage<CloudSession>.self,
                                    baseURL: baseURL,
                                    path: [
                                        "v0",
                                        "workspaces",
                                        workspaceID,
                                        "sessions",
                                    ],
                                    queryItems: [
                                        URLQueryItem(name: "limit", value: String(limit)),
                                        URLQueryItem(name: "offset", value: String(offset)),
                                    ],
                                    apiKey: cycleAPIKey
                                )
                            }
                            let sessionIDs = Set(sessions.map(\.id))
                            statuses = statuses.filter { sessionIDs.contains($0.key) }
                            let refreshedStatuses = try await fetchSessionStatuses(
                                sessionIDs: sessions.map(\.id),
                                workspaceID: workspaceID,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                            statuses.merge(refreshedStatuses) { _, refreshed in refreshed }
                            for session in sessions where statuses[session.id] == nil {
                                statuses[session.id] = CloudSessionStatusResponse(
                                    workspaceID: workspaceID,
                                    sessionID: session.id,
                                    status: .unknown,
                                    updatedAt: workspace.lastActivityAt ?? workspace.createdAt
                                )
                            }

                            let snapshot = CloudWorkspaceSessionSnapshot(
                                accountID: cycleIdentity.cacheID,
                                workspace: workspace,
                                sessions: sessions,
                                statuses: statuses
                            )
                            if snapshot != previousSnapshot {
                                continuation.yield(snapshot)
                                previousSnapshot = snapshot
                            }
                            retryDelay = .seconds(1)
                            let requiresFrequentRefresh = statuses.values.contains {
                                $0.status.requiresFrequentRefresh
                            }
                            try await clock.sleep(
                                for: requiresFrequentRefresh
                                    ? .milliseconds(2_500)
                                    : .seconds(10)
                            )
                        } catch {
                            guard CloudAPIClientError.shouldRetryObservation(after: error) else {
                                throw error
                            }
                            try await clock.sleep(for: retryDelay)
                            retryDelay = min(retryDelay * 2, .seconds(30))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    private static func transcriptStream(
        sessionID: String,
        checkpoint: CloudTranscriptCheckpoint?,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudTranscriptUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                @Dependency(\.continuousClock) var clock
                @Dependency(\.date.now) var now

                var cachedAPIKey: String?
                let ownsCheckpoint = checkpoint?.remoteSessionID == sessionID
                var cursor = ownsCheckpoint ? checkpoint?.rawCursor : nil
                var cursorAccountID = ownsCheckpoint ? checkpoint?.accountID : nil
                var lastFullTranscriptRefreshAt = ownsCheckpoint
                    ? checkpoint?.lastFullTranscriptRefreshAt
                    : nil
                var identity: CloudIdentity?
                var retryDelay = Duration.seconds(1)
                var status: CloudSessionStatusResponse?

                do {
                    while !Task.isCancelled {
                        do {
                            let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                            if cycleAPIKey != cachedAPIKey {
                                cachedAPIKey = cycleAPIKey
                                identity = nil
                                status = nil
                            }

                            let cycleIdentity = try await loadIdentity(
                                identity: &identity,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                            if cursorAccountID != cycleIdentity.cacheID {
                                cursor = nil
                                cursorAccountID = cycleIdentity.cacheID
                                lastFullTranscriptRefreshAt = nil
                            }
                            do {
                                let refreshedStatus = try await request(
                                    CloudSessionStatusResponse.self,
                                    baseURL: baseURL,
                                    path: ["v0", "sessions", sessionID, "status"],
                                    apiKey: cycleAPIKey
                                )
                                guard refreshedStatus.sessionID == sessionID else {
                                    throw CloudAPIClientError.invalidResponse
                                }
                                status = refreshedStatus
                            } catch let error as CloudAPIClientError
                                where error == .invalidResponse
                                    || error.isAuthenticationFailure {
                                throw error
                            } catch {
                                try Task.checkCancellation()
                            }

                            let requiresPeriodicRefresh =
                                lastFullTranscriptRefreshAt.map {
                                    now.timeIntervalSince($0) >= 15 * 60
                                } ?? true
                            let isComplete = cursor == nil || requiresPeriodicRefresh
                            let messages: [CloudTranscriptMessage]
                            do {
                                messages = try await transcriptPages(
                                    sessionID: sessionID,
                                    after: isComplete ? nil : cursor,
                                    baseURL: baseURL,
                                    apiKey: cycleAPIKey
                                )
                            } catch let error as CloudAPIClientError
                                where !isComplete && error.isInvalidCursorFailure {
                                cursor = nil
                                lastFullTranscriptRefreshAt = nil
                                continue
                            }
                            guard messages.allSatisfy({ $0.sessionID == sessionID }) else {
                                throw CloudAPIClientError.invalidResponse
                            }

                            if isComplete {
                                let completedAt = now
                                cursor = messages.last?.id
                                lastFullTranscriptRefreshAt = completedAt
                                continuation.yield(
                                    CloudTranscriptUpdate(
                                        accountID: cycleIdentity.cacheID,
                                        sessionID: sessionID,
                                        messages: messages,
                                        kind: .complete,
                                        rawCursor: cursor,
                                        completedAt: completedAt
                                    )
                                )
                            } else if !messages.isEmpty {
                                cursor = messages.last?.id
                                continuation.yield(
                                    CloudTranscriptUpdate(
                                        accountID: cycleIdentity.cacheID,
                                        sessionID: sessionID,
                                        messages: messages,
                                        kind: .incremental,
                                        rawCursor: cursor
                                    )
                                )
                            }

                            retryDelay = .seconds(1)
                            let pollDelay: Duration =
                                status?.status.requiresFrequentRefresh != false
                                    ? .milliseconds(2_500)
                                    : .seconds(10)
                            try await clock.sleep(for: pollDelay)
                        } catch {
                            guard CloudAPIClientError.shouldRetryObservation(after: error) else {
                                throw error
                            }
                            try await clock.sleep(for: retryDelay)
                            retryDelay = min(retryDelay * 2, .seconds(30))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    private static func transcriptPages(
        sessionID: String,
        after: String?,
        baseURL: URL,
        apiKey: String
    ) async throws -> [CloudTranscriptMessage] {
        guard let after else {
            return try await allPages(pageSize: 100) { limit, offset in
                try await request(
                    CloudPage<CloudTranscriptMessage>.self,
                    baseURL: baseURL,
                    path: ["v0", "sessions", sessionID, "messages"],
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "offset", value: String(offset)),
                    ],
                    apiKey: apiKey
                )
            }
        }

        var cursor = after
        var messages: [CloudTranscriptMessage] = []
        while true {
            try Task.checkCancellation()
            let response = try await request(
                CloudPage<CloudTranscriptMessage>.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "messages"],
                queryItems: [
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "after", value: cursor),
                ],
                apiKey: apiKey
            )
            messages.append(contentsOf: response.data)
            guard response.hasMore else {
                return messages
            }
            guard let nextCursor = response.data.last?.id,
                  nextCursor != cursor else {
                throw CloudAPIClientError.invalidResponse
            }
            cursor = nextCursor
        }
    }

    private static func loadIdentity(
        identity: inout CloudIdentity?,
        baseURL: URL,
        apiKey: String
    ) async throws -> CloudIdentity {
        if let identity {
            return identity
        }
        let loadedIdentity = try await request(
            CloudIdentity.self,
            baseURL: baseURL,
            path: ["me"],
            apiKey: apiKey
        )
        identity = loadedIdentity
        return loadedIdentity
    }

    private static func fetchSessionStatuses(
        sessionIDs: [CloudSession.ID],
        workspaceID: CloudWorkspace.ID,
        baseURL: URL,
        apiKey: String
    ) async throws -> [CloudSession.ID: CloudSessionStatusResponse] {
        var statuses: [CloudSession.ID: CloudSessionStatusResponse] = [:]

        for batchStart in stride(from: 0, to: sessionIDs.count, by: 8) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + 8, sessionIDs.count)
            let batch = sessionIDs[batchStart..<batchEnd]
            let results = try await withThrowingTaskGroup(
                of: (CloudSession.ID, CloudSessionStatusResponse)?.self
            ) { group in
                for sessionID in batch {
                    group.addTask {
                        do {
                            let response = try await request(
                                CloudSessionStatusResponse.self,
                                baseURL: baseURL,
                                path: ["v0", "sessions", sessionID, "status"],
                                apiKey: apiKey
                            )
                            guard response.sessionID == sessionID,
                                  response.workspaceID == workspaceID else {
                                throw CloudAPIClientError.invalidResponse
                            }
                            return (sessionID, response)
                        } catch let error as CloudAPIClientError
                            where error == .invalidResponse
                                || error.isAuthenticationFailure {
                            throw error
                        } catch {
                            try Task.checkCancellation()
                            return nil
                        }
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            for case let (sessionID, response)? in results {
                statuses[sessionID] = response
            }
        }

        return statuses
    }

    private static func workspaceStream(
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudWorkspaceSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                do {
                    @Dependency(\.continuousClock) var clock

                    var cachedAPIKey: String?
                    var identity: CloudIdentity?
                    var cycleIndex = 0
                    var previousSnapshot: CloudWorkspaceSnapshot?
                    var statuses: [
                        CloudWorkspace.ID: CloudWorkspaceStatusResponse
                    ] = [:]
                    var failedStatusIDs: Set<CloudWorkspace.ID> = []

                    while !Task.isCancelled {
                        // Keychain is the source of truth. Load once per cycle so every request in
                        // one snapshot is coherent while replacements take effect on the next.
                        let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                        if cycleAPIKey != cachedAPIKey {
                            cachedAPIKey = cycleAPIKey
                            identity = nil
                            previousSnapshot = nil
                            statuses.removeAll()
                            failedStatusIDs.removeAll()
                            cycleIndex = 0
                        }
                        let cycleIdentity: CloudIdentity
                        if let identity {
                            cycleIdentity = identity
                        } else {
                            let loadedIdentity = try await request(
                                CloudIdentity.self,
                                baseURL: baseURL,
                                path: ["me"],
                                apiKey: cycleAPIKey
                            )
                            identity = loadedIdentity
                            cycleIdentity = loadedIdentity
                        }
                        let projects = try await allPages(
                            pageSize: 100
                        ) { limit, offset in
                            try await request(
                                CloudPage<CloudProject>.self,
                                baseURL: baseURL,
                                path: ["v0", "projects"],
                                queryItems: [
                                    URLQueryItem(
                                        name: "limit",
                                        value: String(limit)
                                    ),
                                    URLQueryItem(
                                        name: "offset",
                                        value: String(offset)
                                    ),
                                ],
                                apiKey: cycleAPIKey
                            )
                        }
                        var workspaces: [CloudProjectWorkspace] = []
                        for project in projects {
                            let projectWorkspaces = try await allPages(
                                pageSize: 100
                            ) { limit, offset in
                                try await request(
                                    CloudPage<CloudWorkspace>.self,
                                    baseURL: baseURL,
                                    path: [
                                        "v0",
                                        "projects",
                                        project.id,
                                        "workspaces",
                                    ],
                                    queryItems: [
                                        URLQueryItem(
                                            name: "limit",
                                            value: String(limit)
                                        ),
                                        URLQueryItem(
                                            name: "offset",
                                            value: String(offset)
                                        ),
                                    ],
                                    apiKey: cycleAPIKey
                                )
                            }
                            workspaces.append(
                                contentsOf: projectWorkspaces.map {
                                    CloudProjectWorkspace(
                                        project: project,
                                        workspace: $0
                                    )
                                }
                            )
                        }

                        let workspaceIDs = Set(workspaces.map(\.id))
                        statuses = statuses.filter {
                            workspaceIDs.contains($0.key)
                        }
                        failedStatusIDs.formIntersection(workspaceIDs)
                        let shouldRefreshStableStatuses = cycleIndex >= 4
                        let statusIDs = workspaces.compactMap { item in
                            if failedStatusIDs.contains(item.id) {
                                return shouldRefreshStableStatuses
                                    ? item.id
                                    : nil
                            }
                            guard let status = statuses[item.id] else {
                                return item.id
                            }
                            return status.status.requiresFrequentRefresh
                                || shouldRefreshStableStatuses
                                ? item.id
                                : nil
                        }
                        let refreshedStatuses = try await fetchStatuses(
                            workspaceIDs: statusIDs,
                            baseURL: baseURL,
                            apiKey: cycleAPIKey
                        )
                        statuses.merge(refreshedStatuses) { _, refreshed in
                            refreshed
                        }
                        failedStatusIDs.subtract(refreshedStatuses.keys)
                        failedStatusIDs.formUnion(
                            statusIDs.filter {
                                refreshedStatuses[$0] == nil
                            }
                        )

                        let snapshot = CloudWorkspaceSnapshot(
                            accountID: cycleIdentity.cacheID,
                            projects: projects,
                            statuses: statuses,
                            workspaces: workspaces
                        )
                        if snapshot != previousSnapshot {
                            continuation.yield(snapshot)
                            previousSnapshot = snapshot
                        }

                        cycleIndex = shouldRefreshStableStatuses
                            ? 0
                            : cycleIndex + 1
                        try await clock.sleep(for: .milliseconds(2_500))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                observation.cancel()
            }
        }
    }

    private static func loadWorkspaceInventory(
        accountID: String,
        baseURL: URL,
        apiKey: String
    ) async throws -> CloudWorkspaceSnapshot {
        let projects = try await allPages(pageSize: 100) { limit, offset in
            try await request(
                CloudPage<CloudProject>.self,
                baseURL: baseURL,
                path: ["v0", "projects"],
                queryItems: [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ],
                apiKey: apiKey
            )
        }
        var workspaces: [CloudProjectWorkspace] = []
        for project in projects {
            let projectWorkspaces = try await allPages(
                pageSize: 100
            ) { limit, offset in
                try await request(
                    CloudPage<CloudWorkspace>.self,
                    baseURL: baseURL,
                    path: [
                        "v0",
                        "projects",
                        project.id,
                        "workspaces",
                    ],
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "offset", value: String(offset)),
                    ],
                    apiKey: apiKey
                )
            }
            workspaces.append(
                contentsOf: projectWorkspaces.map {
                    CloudProjectWorkspace(project: project, workspace: $0)
                }
            )
        }
        return CloudWorkspaceSnapshot(
            accountID: accountID,
            projects: projects,
            statuses: [:],
            workspaces: workspaces
        )
    }

    private static func fetchStatuses(
        workspaceIDs: [CloudWorkspace.ID],
        baseURL: URL,
        apiKey: String
    ) async throws -> [CloudWorkspace.ID: CloudWorkspaceStatusResponse] {
        var statuses: [CloudWorkspace.ID: CloudWorkspaceStatusResponse] = [:]

        for batchStart in stride(from: 0, to: workspaceIDs.count, by: 8) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + 8, workspaceIDs.count)
            let batch = workspaceIDs[batchStart..<batchEnd]
            let batchStatuses = try await withThrowingTaskGroup(
                of: (
                    CloudWorkspace.ID,
                    CloudWorkspaceStatusResponse
                )?.self
            ) { group in
                for workspaceID in batch {
                    group.addTask {
                        do {
                            let status = try await request(
                                CloudWorkspaceStatusResponse.self,
                                baseURL: baseURL,
                                path: [
                                    "v0",
                                    "workspaces",
                                    workspaceID,
                                    "status",
                                ],
                                apiKey: apiKey
                            )
                            guard status.workspaceID == workspaceID else {
                                throw CloudAPIClientError.invalidResponse
                            }
                            return (workspaceID, status)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as CloudAPIClientError
                            where error.isAuthenticationFailure {
                            throw error
                        } catch {
                            try Task.checkCancellation()
                            return nil
                        }
                    }
                }

                var batchStatuses: [
                    CloudWorkspace.ID: CloudWorkspaceStatusResponse
                ] = [:]
                for try await result in group {
                    guard let (workspaceID, status) = result else {
                        continue
                    }
                    batchStatuses[workspaceID] = status
                }
                return batchStatuses
            }
            statuses.merge(batchStatuses) { _, refreshed in refreshed }
        }

        return statuses
    }

    private static func requiredAPIKey(
        from loadAPIKey: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let apiKey = try await loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw CloudAPIClientError.missingCredential
        }
        return apiKey
    }

    private static func verifiedAPIKey(
        expectedAccountID: String,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let key = try await requiredAPIKey(from: apiKey)
        let identity = try await request(
            CloudIdentity.self,
            baseURL: baseURL,
            path: ["me"],
            apiKey: key
        )
        guard identity.cacheID == expectedAccountID else {
            throw CloudAPIClientError.unexpectedAccount
        }
        return key
    }

    private static func request<Response: Decodable>(
        _ responseType: Response.Type,
        baseURL: URL,
        path: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        apiKey: String
    ) async throws -> Response {
        @Dependency(\.cloudAPITransport) var transport

        let url = path.reduce(baseURL) { url, component in
            url.appending(component: component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CloudAPIClientError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let requestURL = components.url else {
            throw CloudAPIClientError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.data(request: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CloudAPIClientError.requestFailed(
                statusCode: response.statusCode,
                error: try? JSONDecoder().decode(CloudStructuredError.self, from: data)
            )
        }
        return try JSONDecoder.cloud.decode(responseType, from: data)
    }
}

private extension CloudAPIClient {
    static func allPages<Element: Decodable & Equatable & Sendable>(
        pageSize: Int,
        page: (_ limit: Int, _ offset: Int) async throws -> CloudPage<Element>
    ) async throws -> [Element] {
        var offset = 0
        var results: [Element] = []

        while true {
            try Task.checkCancellation()
            let response = try await page(pageSize, offset)
            guard response.offset == offset else {
                throw CloudAPIClientError.invalidResponse
            }
            results.append(contentsOf: response.data)
            guard response.hasMore else {
                return results
            }
            guard !response.data.isEmpty else {
                throw CloudAPIClientError.invalidResponse
            }

            let nextOffset = offset + response.data.count
            guard nextOffset > offset else {
                throw CloudAPIClientError.invalidResponse
            }
            offset = nextOffset
        }
    }
}

private extension CloudWorkspaceStatusResponse.Status {
    var requiresFrequentRefresh: Bool {
        switch self {
        case .ready, .sleeping, .archived, .deleted:
            false

        case .initializing, .updating:
            true

        default:
            true
        }
    }
}

private extension CloudSessionStatusResponse.Status {
    var requiresFrequentRefresh: Bool {
        switch self {
        case .idle, .error:
            false

        case .working, .unknown:
            true

        default:
            true
        }
    }
}

@DependencyClient
struct CloudAPITransport: Sendable {
    var data: @Sendable (
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)
}

extension CloudAPITransport: DependencyKey {
    static var liveValue: Self {
        Self { request in
            @Dependency(\.urlSession) var urlSession
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw CloudAPIClientError.invalidResponse
            }
            return (data, response)
        }
    }
}

public extension DependencyValues {
    var cloudAPIClient: CloudAPIClient {
        get { self[CloudAPIClient.self] }
        set { self[CloudAPIClient.self] = newValue }
    }
}

extension DependencyValues {
    var cloudAPITransport: CloudAPITransport {
        get { self[CloudAPITransport.self] }
        set { self[CloudAPITransport.self] = newValue }
    }
}

extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            var normalizedValue = value
            if normalizedValue.count > 10 {
                let separator = normalizedValue.index(
                    normalizedValue.startIndex,
                    offsetBy: 10
                )
                if normalizedValue[separator] == " " {
                    normalizedValue.replaceSubrange(separator...separator, with: "T")
                }
            }
            if let timeZoneSign = normalizedValue.lastIndex(where: {
                $0 == "+" || $0 == "-"
            }),
               normalizedValue.distance(from: timeZoneSign, to: normalizedValue.endIndex) == 3 {
                normalizedValue.append(":00")
            }
            if let date = try? Date(normalizedValue, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected an ISO-8601 date."
            )
        }
        return decoder
    }
}
