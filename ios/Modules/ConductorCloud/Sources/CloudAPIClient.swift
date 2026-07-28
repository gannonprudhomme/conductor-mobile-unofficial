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
    /// `GET /v0/workspaces/{workspaceID}`
    public var getWorkspace: @Sendable (
        _ workspaceID: CloudWorkspace.ID
    ) async throws -> CloudWorkspace
    public var observeSessions: @Sendable (
        _ workspaceID: CloudWorkspace.ID
    ) -> AsyncThrowingStream<CloudSessionSnapshot, any Error> = { _ in
        .finished()
    }
    public var observeTranscript: @Sendable (
        _ sessionID: CloudSession.ID
    ) -> AsyncThrowingStream<CloudTranscriptSnapshot, any Error> = { _ in
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
        Self {
            try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: try await requiredAPIKey(from: apiKey)
            )
        } getWorkspace: { workspaceID in
            try await request(
                CloudWorkspace.self,
                baseURL: baseURL,
                path: ["v0", "workspaces", workspaceID],
                apiKey: try await requiredAPIKey(from: apiKey)
            )
        } observeSessions: { workspaceID in
            sessionStream(
                workspaceID: workspaceID,
                baseURL: baseURL,
                apiKey: apiKey
            )
        } observeTranscript: { sessionID in
            transcriptStream(
                sessionID: sessionID,
                baseURL: baseURL,
                apiKey: apiKey
            )
        } observeWorkspaces: {
            workspaceStream(baseURL: baseURL, apiKey: apiKey)
        } validateIdentity: { candidateAPIKey in
            try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: candidateAPIKey
            )
        }
    }

    private static func sessionStream(
        workspaceID: CloudWorkspace.ID,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudSessionSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                do {
                    @Dependency(\.continuousClock) var clock

                    var cycleIndex = 0
                    var identity: CloudIdentity?
                    var previousSnapshot: CloudSessionSnapshot?
                    var sessions: [CloudSession] = []
                    var statuses: [
                        CloudSession.ID: CloudSessionStatusResponse
                    ] = [:]
                    var workspace: CloudWorkspace?

                    while !Task.isCancelled {
                        let cycleAPIKey = try await requiredAPIKey(from: apiKey)
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

                        let shouldRefreshSessionList = workspace == nil
                            || cycleIndex >= 4
                        if shouldRefreshSessionList {
                            async let loadedWorkspace = request(
                                CloudWorkspace.self,
                                baseURL: baseURL,
                                path: ["v0", "workspaces", workspaceID],
                                apiKey: cycleAPIKey
                            )
                            async let loadedSessions = allPages(
                                pageSize: 100
                            ) { limit, offset in
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
                            workspace = try await loadedWorkspace
                            sessions = try await loadedSessions
                            let sessionIDs = Set(sessions.map(\.id))
                            statuses = statuses.filter {
                                sessionIDs.contains($0.key)
                            }
                        }

                        let statusIDs = sessions.compactMap { session in
                            guard let status = statuses[session.id] else {
                                return session.id
                            }
                            return status.status.requiresFrequentRefresh
                                || shouldRefreshSessionList
                                ? session.id
                                : nil
                        }
                        let refreshedStatuses = try await fetchSessionStatuses(
                            sessionIDs: statusIDs,
                            workspaceID: workspaceID,
                            baseURL: baseURL,
                            apiKey: cycleAPIKey
                        )
                        statuses.merge(refreshedStatuses) { _, refreshed in
                            refreshed
                        }

                        guard let workspace else {
                            throw CloudAPIClientError.invalidResponse
                        }
                        let snapshot = CloudSessionSnapshot(
                            accountID: cycleIdentity.cacheID,
                            workspace: workspace,
                            sessions: sessions,
                            statuses: statuses
                        )
                        if snapshot != previousSnapshot {
                            continuation.yield(snapshot)
                            previousSnapshot = snapshot
                        }

                        cycleIndex = shouldRefreshSessionList
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

    private static func transcriptStream(
        sessionID: CloudSession.ID,
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudTranscriptSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                do {
                    @Dependency(\.continuousClock) var clock

                    let initialAPIKey = try await requiredAPIKey(from: apiKey)
                    let identity = try await request(
                        CloudIdentity.self,
                        baseURL: baseURL,
                        path: ["me"],
                        apiKey: initialAPIKey
                    )
                    async let initialStatus = sessionStatus(
                        sessionID: sessionID,
                        baseURL: baseURL,
                        apiKey: initialAPIKey
                    )
                    async let initialMessages = allTranscriptPages(
                        sessionID: sessionID,
                        baseURL: baseURL,
                        apiKey: initialAPIKey
                    )
                    var status = try await initialStatus
                    var previouslyYieldedStatus = status
                    let normalizedInitialMessages = CloudTranscriptMessage
                        .normalized(try await initialMessages)
                    var cursor = normalizedInitialMessages.last?.id
                    continuation.yield(
                        CloudTranscriptSnapshot(
                            accountID: identity.cacheID,
                            sessionID: sessionID,
                            status: status,
                            messages: normalizedInitialMessages,
                            isFullSnapshot: true
                        )
                    )

                    var cycleIndex = 0
                    while !Task.isCancelled {
                        try await clock.sleep(
                            for: status.status.requiresFrequentRefresh
                                ? .milliseconds(2_500)
                                : .seconds(10)
                        )
                        let cycleAPIKey = try await requiredAPIKey(from: apiKey)
                        let shouldReloadFullTranscript = cycleIndex >= 12
                            || cursor == nil
                        async let refreshedStatus = sessionStatus(
                            sessionID: sessionID,
                            baseURL: baseURL,
                            apiKey: cycleAPIKey
                        )
                        let refreshedMessages: [CloudTranscriptMessage]
                        if shouldReloadFullTranscript {
                            refreshedMessages = try await allTranscriptPages(
                                sessionID: sessionID,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                        } else {
                            refreshedMessages = try await transcriptMessages(
                                after: cursor,
                                sessionID: sessionID,
                                baseURL: baseURL,
                                apiKey: cycleAPIKey
                            )
                        }
                        status = try await refreshedStatus
                        let normalizedMessages = CloudTranscriptMessage
                            .normalized(refreshedMessages)
                        cursor = normalizedMessages.last?.id ?? cursor
                        let snapshot = CloudTranscriptSnapshot(
                            accountID: identity.cacheID,
                            sessionID: sessionID,
                            status: status,
                            messages: normalizedMessages,
                            isFullSnapshot: shouldReloadFullTranscript
                        )
                        if !normalizedMessages.isEmpty
                            || shouldReloadFullTranscript
                            || status != previouslyYieldedStatus {
                            continuation.yield(snapshot)
                            previouslyYieldedStatus = status
                        }
                        cycleIndex = shouldReloadFullTranscript
                            ? 0
                            : cycleIndex + 1
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

    private static func workspaceStream(
        baseURL: URL,
        apiKey: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<CloudWorkspaceSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            let observation = Task {
                do {
                    @Dependency(\.continuousClock) var clock

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

    private static func fetchSessionStatuses(
        sessionIDs: [CloudSession.ID],
        workspaceID: CloudWorkspace.ID,
        baseURL: URL,
        apiKey: String
    ) async throws -> [
        CloudSession.ID: CloudSessionStatusResponse
    ] {
        var statuses: [
            CloudSession.ID: CloudSessionStatusResponse
        ] = [:]

        for batchStart in stride(from: 0, to: sessionIDs.count, by: 8) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + 8, sessionIDs.count)
            let batch = sessionIDs[batchStart..<batchEnd]
            let batchStatuses = try await withThrowingTaskGroup(
                of: (
                    CloudSession.ID,
                    CloudSessionStatusResponse
                )?.self
            ) { group in
                for sessionID in batch {
                    group.addTask {
                        do {
                            let status = try await sessionStatus(
                                sessionID: sessionID,
                                baseURL: baseURL,
                                apiKey: apiKey
                            )
                            guard status.workspaceID == workspaceID else {
                                throw CloudAPIClientError.invalidResponse
                            }
                            return (sessionID, status)
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
                    CloudSession.ID: CloudSessionStatusResponse
                ] = [:]
                for try await result in group {
                    guard let (sessionID, status) = result else {
                        continue
                    }
                    batchStatuses[sessionID] = status
                }
                return batchStatuses
            }
            statuses.merge(batchStatuses) { _, refreshed in refreshed }
        }

        return statuses
    }

    private static func sessionStatus(
        sessionID: CloudSession.ID,
        baseURL: URL,
        apiKey: String
    ) async throws -> CloudSessionStatusResponse {
        let status = try await request(
            CloudSessionStatusResponse.self,
            baseURL: baseURL,
            path: ["v0", "sessions", sessionID, "status"],
            apiKey: apiKey
        )
        guard status.sessionID == sessionID else {
            throw CloudAPIClientError.invalidResponse
        }
        return status
    }

    private static func allTranscriptPages(
        sessionID: CloudSession.ID,
        baseURL: URL,
        apiKey: String
    ) async throws -> [CloudTranscriptMessage] {
        try await allPages(pageSize: 100) { limit, offset in
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

    private static func transcriptMessages(
        after cursor: CloudTranscriptMessage.ID?,
        sessionID: CloudSession.ID,
        baseURL: URL,
        apiKey: String
    ) async throws -> [CloudTranscriptMessage] {
        guard var cursor else {
            return try await allTranscriptPages(
                sessionID: sessionID,
                baseURL: baseURL,
                apiKey: apiKey
            )
        }
        var messages: [CloudTranscriptMessage] = []

        while true {
            try Task.checkCancellation()
            let page = try await request(
                CloudPage<CloudTranscriptMessage>.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "messages"],
                queryItems: [
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "after", value: cursor),
                ],
                apiKey: apiKey
            )
            messages.append(contentsOf: page.data)
            guard page.hasMore else {
                return messages
            }
            guard let nextCursor = page.data.last?.id,
                  nextCursor != cursor else {
                throw CloudAPIClientError.invalidResponse
            }
            cursor = nextCursor
        }
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
        page: (_ limit: Int, _ offset: Int) async throws -> CloudPage<Element>
    ) async throws -> [Element] {
        var offset = 0
        var results: [Element] = []

        while true {
            try Task.checkCancellation()
            let response = try await page(pageSize, offset)
            results.append(contentsOf: response.data)
            guard response.hasMore else {
                return results
            }
            guard !response.data.isEmpty else {
                throw CloudAPIClientError.invalidResponse
            }

            let nextOffset = response.offset + response.data.count
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

        case .working:
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
