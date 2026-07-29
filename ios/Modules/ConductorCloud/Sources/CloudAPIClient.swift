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
    /// `GET /me`
    public var getIdentity: @Sendable () async throws -> CloudIdentity
    public var observeSessions: @Sendable (
        _ workspaceID: String
    ) -> AsyncThrowingStream<CloudWorkspaceSessionSnapshot, any Error> = { _ in
        .finished()
    }
    public var observeTranscript: @Sendable (
        _ sessionID: String,
        _ workspaceID: String,
        _ checkpoint: CloudTranscriptCheckpoint?
    ) -> AsyncThrowingStream<CloudTranscriptUpdate, any Error> = { _, _, _ in
        .finished()
    }
    public var observeWorkspaces: @Sendable () -> AsyncThrowingStream<
        CloudWorkspaceSnapshot,
        any Error
    > = {
        .finished()
    }
    /// `GET /me` with an unsaved Settings candidate.
    public var validateIdentity: @Sendable (
        _ apiKey: String
    ) async throws -> CloudIdentity
}

public enum CloudAPIClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case missingCredential
    case requestFailed(statusCode: Int, error: CloudStructuredError?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Conductor Cloud returned an invalid response."

        case .missingCredential:
            "Enter a Conductor API key in Settings."

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
        case .invalidResponse, .missingCredential:
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
        live(
            baseURL: productionBaseURL,
            identityCache: liveIdentityCache
        ) {
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
        live(
            baseURL: baseURL,
            identityCache: CloudIdentityCache(),
            apiKey: apiKey
        )
    }

    private static func live(
        baseURL: URL,
        identityCache: CloudIdentityCache,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> Self {
        return Self {
            try await identityCache.identity(
                apiKey: try await requiredAPIKey(from: apiKey)
            ) { apiKey in
                try await request(
                    CloudIdentity.self,
                    baseURL: baseURL,
                    path: ["me"],
                    apiKey: apiKey
                )
            }
        } observeSessions: { workspaceID in
            sessionStream(
                workspaceID: workspaceID,
                baseURL: baseURL,
                apiKey: apiKey,
                identityCache: identityCache
            )
        } observeTranscript: { sessionID, workspaceID, checkpoint in
            transcriptStream(
                sessionID: sessionID,
                workspaceID: workspaceID,
                checkpoint: checkpoint,
                baseURL: baseURL,
                apiKey: apiKey,
                identityCache: identityCache
            )
        } observeWorkspaces: {
            workspaceStream(
                baseURL: baseURL,
                apiKey: apiKey,
                identityCache: identityCache
            )
        } validateIdentity: { candidateAPIKey in
            try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: candidateAPIKey
            )
        }
    }

    private static let liveIdentityCache = CloudIdentityCache()

    private static func sessionStream(
        workspaceID: String,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String,
        identityCache: CloudIdentityCache
    ) -> AsyncThrowingStream<CloudWorkspaceSessionSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                @Dependency(\.continuousClock) var clock

                var cachedAPIKey: String?
                var previousSnapshot: CloudWorkspaceSessionSnapshot?
                var retryDelay = Duration.seconds(1)
                var statuses: [CloudSession.ID: CloudSessionStatusResponse] = [:]
                var statusRefreshDeadlines: [
                    CloudSession.ID: @Sendable () -> Bool
                ] = [:]

                do {
                    while !Task.isCancelled {
                        do {
                            let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                            if cycleAPIKey != cachedAPIKey {
                                cachedAPIKey = cycleAPIKey
                                previousSnapshot = nil
                                statuses.removeAll()
                                statusRefreshDeadlines.removeAll()
                            }

                            async let cycleIdentityRequest = identityCache.identity(
                                apiKey: cycleAPIKey
                            ) { apiKey in
                                try await request(
                                    CloudIdentity.self,
                                    baseURL: baseURL,
                                    path: ["me"],
                                    apiKey: apiKey
                                )
                            }
                            async let workspaceRequest = request(
                                CloudWorkspace.self,
                                baseURL: baseURL,
                                path: ["v0", "workspaces", workspaceID],
                                apiKey: cycleAPIKey
                            )
                            async let sessionsRequest = allPages(pageSize: 100) {
                                limit,
                                offset in
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
                            let (cycleIdentity, workspace, sessions) = try await (
                                cycleIdentityRequest,
                                workspaceRequest,
                                sessionsRequest
                            )
                            guard workspace.id == workspaceID else {
                                throw CloudAPIClientError.invalidResponse
                            }

                            let sessionIDs = Set(sessions.map(\.id))
                            statuses = statuses.filter { sessionIDs.contains($0.key) }
                            statusRefreshDeadlines = statusRefreshDeadlines.filter {
                                sessionIDs.contains($0.key)
                            }
                            let membershipSnapshot = CloudWorkspaceSessionSnapshot(
                                accountID: cycleIdentity.cacheID,
                                workspace: workspace,
                                sessions: sessions,
                                statuses: statuses
                            )
                            if membershipSnapshot != previousSnapshot {
                                continuation.yield(membershipSnapshot)
                                previousSnapshot = membershipSnapshot
                            }

                            let statusIDs = sessions.compactMap { session in
                                guard let hasReachedDeadline =
                                    statusRefreshDeadlines[session.id] else {
                                    return session.id
                                }
                                return hasReachedDeadline()
                                    ? session.id
                                    : nil
                            }
                            let refreshedStatuses = try await fetchSessionStatuses(
                                sessionIDs: statusIDs,
                                workspaceID: workspaceID,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                            statuses.merge(refreshedStatuses) { _, refreshed in refreshed }
                            for sessionID in statusIDs {
                                let refreshInterval = refreshedStatuses[sessionID]?
                                    .status.requiresFrequentRefresh != false
                                    ? Duration.milliseconds(2_500)
                                    : .seconds(10)
                                statusRefreshDeadlines[sessionID] = deadline(
                                    after: refreshInterval,
                                    on: clock
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
                            let requiresFrequentRefresh = sessions.contains { session in
                                statuses[session.id]?.status.requiresFrequentRefresh
                                    != false
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
                } catch {
                    if CloudAPIClientError.isRequestCancellation(error) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    private static func transcriptStream(
        sessionID: String,
        workspaceID: String,
        checkpoint: CloudTranscriptCheckpoint?,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String,
        identityCache: CloudIdentityCache
    ) -> AsyncThrowingStream<CloudTranscriptUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                @Dependency(\.continuousClock) var clock

                var cachedAPIKey: String?
                var cursor = checkpoint?.remoteSessionID == sessionID
                    ? checkpoint?.rawCursor
                    : nil
                var cursorAccountID = checkpoint?.remoteSessionID == sessionID
                    ? checkpoint?.accountID
                    : nil
                var retryDelay = Duration.seconds(1)
                var status: CloudSessionStatusResponse?

                do {
                    while !Task.isCancelled {
                        let requestCursor = cursor
                        do {
                            let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                            if cycleAPIKey != cachedAPIKey {
                                cachedAPIKey = cycleAPIKey
                                status = nil
                            }

                            let cycle = try await withThrowingTaskGroup(
                                of: TranscriptCycleEvent.self
                            ) { group in
                                let checkpointAccountID = cursorAccountID
                                group.addTask {
                                    .status(
                                        try await transcriptStatus(
                                            sessionID: sessionID,
                                            workspaceID: workspaceID,
                                            baseURL: baseURL,
                                            apiKey: cycleAPIKey
                                        )
                                    )
                                }
                                group.addTask {
                                    async let cycleIdentityRequest =
                                        identityCache.identity(
                                            apiKey: cycleAPIKey
                                        ) { apiKey in
                                            try await request(
                                                CloudIdentity.self,
                                                baseURL: baseURL,
                                                path: ["me"],
                                                apiKey: apiKey
                                            )
                                        }
                                    async let messagesRequest = transcriptPages(
                                        sessionID: sessionID,
                                        after: requestCursor,
                                        baseURL: baseURL,
                                        apiKey: cycleAPIKey
                                    )
                                    let cycleIdentity = try await cycleIdentityRequest
                                    let requestedMessages = try await messagesRequest
                                    let didChangeAccount =
                                        checkpointAccountID != nil
                                        && checkpointAccountID != cycleIdentity.cacheID
                                    let messages =
                                        if didChangeAccount, requestCursor != nil {
                                            try await transcriptPages(
                                                sessionID: sessionID,
                                                after: nil,
                                                baseURL: baseURL,
                                                apiKey: cycleAPIKey
                                            )
                                        } else {
                                            requestedMessages
                                        }
                                    return .primary(
                                        TranscriptPrimaryResult(
                                            identity: cycleIdentity,
                                            isComplete: requestCursor == nil
                                                || didChangeAccount,
                                            messages: messages
                                        )
                                    )
                                }

                                var refreshedStatus: CloudSessionStatusResponse?
                                while let event = try await group.next() {
                                    switch event {
                                    case let .status(response):
                                        refreshedStatus = response

                                    case let .primary(primary):
                                        group.cancelAll()
                                        return (
                                            primary: primary,
                                            refreshedStatus: refreshedStatus
                                        )
                                    }
                                }
                                throw CloudAPIClientError.invalidResponse
                            }
                            let cycleIdentity = cycle.primary.identity
                            let isComplete = cycle.primary.isComplete
                            let messages = cycle.primary.messages
                            cursorAccountID = cycleIdentity.cacheID
                            guard messages.allSatisfy({ $0.sessionID == sessionID }) else {
                                throw CloudAPIClientError.invalidResponse
                            }

                            if isComplete {
                                let nextCursor = messages.last?.id
                                continuation.yield(
                                    CloudTranscriptUpdate(
                                        accountID: cycleIdentity.cacheID,
                                        sessionID: sessionID,
                                        messages: messages,
                                        kind: .complete,
                                        rawCursor: nextCursor
                                    )
                                )
                                cursor = nextCursor
                            } else if !messages.isEmpty {
                                let nextCursor = messages.last?.id
                                continuation.yield(
                                    CloudTranscriptUpdate(
                                        accountID: cycleIdentity.cacheID,
                                        sessionID: sessionID,
                                        messages: messages,
                                        kind: .incremental,
                                        rawCursor: nextCursor
                                    )
                                )
                                cursor = nextCursor
                            }

                            if let refreshedStatus = cycle.refreshedStatus {
                                status = refreshedStatus
                            }

                            retryDelay = .seconds(1)
                            let pollDelay: Duration =
                                status?.status.requiresFrequentRefresh != false
                                    ? .milliseconds(2_500)
                                    : .seconds(10)
                            try await clock.sleep(for: pollDelay)
                        } catch {
                            if requestCursor != nil,
                               case let CloudAPIClientError.requestFailed(
                                   statusCode,
                                   _
                               ) = error,
                               statusCode == 400 {
                                throw error
                            }
                            guard CloudAPIClientError.shouldRetryObservation(after: error) else {
                                throw error
                            }
                            try await clock.sleep(for: retryDelay)
                            retryDelay = min(retryDelay * 2, .seconds(30))
                        }
                    }
                    continuation.finish()
                } catch {
                    if CloudAPIClientError.isRequestCancellation(error) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
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
            // Offset pages are independent, so the first two can share one
            // network round trip. Starting with the full 50-request window
            // would make short chats faster by no more, while issuing dozens
            // of requests beyond their end. Page size 100 and a later window
            // of 50 were the fastest combination for the measured p90/p99
            // transcripts without that penalty for the common short case.
            return try await allPagesInConcurrentWindows(
                pageSize: 100,
                initialWindowPageCount: 2,
                maximumWindowPageCount: 50
            ) { limit, offset in
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

        // Incremental pages cannot use offsets: each response supplies the
        // cursor required by the next request. Keep this path serial and reject
        // repeated cursors so a malformed response cannot poll forever.
        var cursor = after
        var visitedCursors: Set<String> = [after]
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
            let nextCursor = response.data.last?.id
            if let nextCursor,
               visitedCursors.contains(nextCursor) {
                throw CloudAPIClientError.invalidResponse
            }
            guard response.hasMore else {
                return messages
            }
            guard let nextCursor else {
                throw CloudAPIClientError.invalidResponse
            }
            visitedCursors.insert(nextCursor)
            cursor = nextCursor
        }
    }

    private static func transcriptStatus(
        sessionID: String,
        workspaceID: String,
        baseURL: URL,
        apiKey: String
    ) async throws -> CloudSessionStatusResponse? {
        do {
            let status = try await request(
                CloudSessionStatusResponse.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "status"],
                apiKey: apiKey
            )
            guard status.sessionID == sessionID,
                  status.workspaceID == workspaceID else {
                throw CloudAPIClientError.invalidResponse
            }
            return status
        } catch let error as CloudAPIClientError
            where error == .invalidResponse {
            throw error
        } catch {
            if CloudAPIClientError.isRequestCancellation(error) {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return nil
        }
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
                            if CloudAPIClientError.isRequestCancellation(error) {
                                throw CancellationError()
                            }
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
        apiKey: @escaping @Sendable () async throws -> String,
        identityCache: CloudIdentityCache
    ) -> AsyncThrowingStream<CloudWorkspaceSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                do {
                    @Dependency(\.continuousClock) var clock

                    var cachedAPIKey: String?
                    var previousSnapshot: CloudWorkspaceSnapshot?
                    var statuses: [
                        CloudWorkspace.ID: CloudWorkspaceStatusResponse
                    ] = [:]
                    var statusRefreshCountdowns: [CloudWorkspace.ID: Int] = [:]

                    while !Task.isCancelled {
                        // Keychain is the source of truth. Load once per cycle so every request in
                        // one snapshot is coherent while replacements take effect on the next.
                        let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                        if cycleAPIKey != cachedAPIKey {
                            cachedAPIKey = cycleAPIKey
                            previousSnapshot = nil
                            statuses.removeAll()
                            statusRefreshCountdowns.removeAll()
                        }
                        async let cycleIdentityRequest = identityCache.identity(
                            apiKey: cycleAPIKey
                        ) { apiKey in
                            try await request(
                                CloudIdentity.self,
                                baseURL: baseURL,
                                path: ["me"],
                                apiKey: apiKey
                            )
                        }
                        async let projectsRequest = allPages(
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
                        let (cycleIdentity, projects) = try await (
                            cycleIdentityRequest,
                            projectsRequest
                        )
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
                        statusRefreshCountdowns = statusRefreshCountdowns.filter {
                            workspaceIDs.contains($0.key)
                        }
                        let statusIDs = workspaces.compactMap { item in
                            guard let countdown = statusRefreshCountdowns[item.id] else {
                                return item.id
                            }
                            return countdown <= 0
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
                        for workspaceID in statusIDs {
                            statusRefreshCountdowns[workspaceID] =
                                refreshedStatuses[workspaceID]?
                                .status.requiresFrequentRefresh != false
                                    ? 1
                                    : 4
                        }

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

                        statusRefreshCountdowns = statusRefreshCountdowns.mapValues {
                            max(0, $0 - 1)
                        }
                        try await clock.sleep(for: .milliseconds(2_500))
                    }
                    continuation.finish()
                } catch {
                    if CloudAPIClientError.isRequestCancellation(error) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                observation.cancel()
            }
        }
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
                        } catch let error as CloudAPIClientError
                            where error.isAuthenticationFailure {
                            throw error
                        } catch {
                            if CloudAPIClientError.isRequestCancellation(error) {
                                throw CancellationError()
                            }
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

    private static func deadline<C: Clock>(
        after duration: Duration,
        on clock: C
    ) -> @Sendable () -> Bool where C.Instant.Duration == Duration {
        let deadline = clock.now.advanced(by: duration)
        return { clock.now >= deadline }
    }

    private static func request<Response: Decodable>(
        _ responseType: Response.Type,
        baseURL: URL,
        path: [String],
        queryItems: [URLQueryItem] = [],
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
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        startingAt initialOffset: Int = 0,
        page: (_ limit: Int, _ offset: Int) async throws -> CloudPage<Element>
    ) async throws -> [Element] {
        var offset = initialOffset
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

            // Advance by what the API actually returned, not by the requested
            // size, so a short nonterminal page cannot create a gap.
            let nextOffset = offset + response.data.count
            guard nextOffset > offset else {
                throw CloudAPIClientError.invalidResponse
            }
            offset = nextOffset
        }
    }

    /// Fetches fixed-offset pages in ordered concurrent windows.
    ///
    /// The API exposes `hasMore`, but not a total count or reverse pagination.
    /// A small first window avoids flooding short transcripts; later windows
    /// trade bounded speculative requests for substantially lower tail latency.
    static func allPagesInConcurrentWindows<
        Element: Decodable & Equatable & Sendable
    >(
        pageSize: Int,
        initialWindowPageCount: Int,
        maximumWindowPageCount: Int,
        page: @escaping @Sendable (
            _ limit: Int,
            _ offset: Int
        ) async throws -> CloudPage<Element>
    ) async throws -> [Element] {
        guard pageSize > 0,
              initialWindowPageCount > 0,
              maximumWindowPageCount > 0 else {
            throw CloudAPIClientError.invalidResponse
        }

        var windowPageCount = initialWindowPageCount
        var nextOffset = 0
        var results: [Element] = []

        // The first window is intentionally small. Reaching the bottom of that
        // window proves the transcript is large enough to benefit from the
        // caller's maximum concurrency on every subsequent pass.
        while true {
            try Task.checkCancellation()
            let offsets = (0..<windowPageCount).map {
                nextOffset + ($0 * pageSize)
            }
            let pages: [CloudPage<Element>]
            do {
                // Task groups return in completion order. Fetch every fixed
                // offset concurrently, then restore API order below.
                pages = try await withThrowingTaskGroup(
                    of: CloudPage<Element>.self
                ) { group in
                    for offset in offsets {
                        group.addTask {
                            try await page(pageSize, offset)
                        }
                    }
                    return try await group.reduce(into: []) {
                        $0.append($1)
                    }
                }
            } catch {
                try Task.checkCancellation()
                // A failed speculative window has not committed any of its
                // pages to results. Retrying serially from nextOffset avoids
                // discarding an otherwise usable transcript just because the
                // server or connection could not sustain the parallel burst.
                results.append(
                    contentsOf: try await allPages(
                        pageSize: pageSize,
                        startingAt: nextOffset
                    ) { limit, offset in
                        try await page(limit, offset)
                    }
                )
                return results
            }
            try Task.checkCancellation()

            for response in pages.sorted(by: { $0.offset < $1.offset }) {
                // The API provides hasMore but no total count. Walking the
                // sorted responses contiguously lets the first hasMore=false
                // page define the real end while ignoring speculative pages
                // that were requested beyond it.
                guard response.offset == nextOffset else {
                    throw CloudAPIClientError.invalidResponse
                }
                results.append(contentsOf: response.data)
                guard response.hasMore else {
                    return results
                }
                guard response.data.count == pageSize else {
                    // Fixed offsets assume every nonterminal page is full. If
                    // the API returns a short page with hasMore=true, continue
                    // from its actual length serially to avoid a gap or overlap.
                    results.append(
                        contentsOf: try await allPages(
                            pageSize: pageSize,
                            startingAt: response.offset + response.data.count
                        ) { limit, offset in
                            try await page(limit, offset)
                        }
                    )
                    return results
                }
                nextOffset += response.data.count
            }
            // Both initial pages (or the previous large window) were full and
            // nonterminal, so latency now matters more than speculative work.
            windowPageCount = maximumWindowPageCount
        }
    }
}

private struct TranscriptPrimaryResult: Sendable {
    let identity: CloudIdentity
    let isComplete: Bool
    let messages: [CloudTranscriptMessage]
}

private enum TranscriptCycleEvent: Sendable {
    case primary(TranscriptPrimaryResult)
    case status(CloudSessionStatusResponse?)
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

private actor CloudIdentityCache {
    private struct InFlightRequest {
        let apiKey: String
        let id: UUID
        let task: Task<CloudIdentity, any Error>
    }

    private var cachedAPIKey: String?
    private var cachedIdentity: CloudIdentity?
    private var inFlightRequest: InFlightRequest?

    func identity(
        apiKey: String,
        load: @escaping @Sendable (_ apiKey: String) async throws -> CloudIdentity
    ) async throws -> CloudIdentity {
        if cachedAPIKey == apiKey, let cachedIdentity {
            return cachedIdentity
        }

        let request: InFlightRequest
        if let inFlightRequest, inFlightRequest.apiKey == apiKey {
            request = inFlightRequest
        } else {
            inFlightRequest?.task.cancel()
            cachedAPIKey = nil
            cachedIdentity = nil

            let id = UUID()
            let task = Task {
                try await load(apiKey)
            }
            request = InFlightRequest(
                apiKey: apiKey,
                id: id,
                task: task
            )
            inFlightRequest = request
        }

        do {
            let identity = try await request.task.value
            if inFlightRequest?.id == request.id {
                cachedAPIKey = apiKey
                cachedIdentity = identity
                inFlightRequest = nil
            }
            return identity
        } catch {
            if inFlightRequest?.id == request.id {
                inFlightRequest = nil
            }
            throw error
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
