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
