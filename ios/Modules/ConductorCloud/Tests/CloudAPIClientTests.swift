//
//  CloudAPIClientTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

@testable import ConductorCloud
import Dependencies
import Foundation
import Testing

@MainActor
struct CloudAPIClientTests {
    @Test("Production requests use the fixed Conductor Cloud origin")
    func productionOrigin() {
        #expect(CloudAPIClient.productionBaseURL.absoluteString == "https://api.conductor.build")
    }

    @Test("Authentication requests include the path, bearer header, and app User-Agent")
    func authenticationRequest() async throws {
        let request = try await performRequest(
            response: #"""
                {
                  "userId": "user-1",
                  "authMethod": "api-key"
                }
                """#
        ) { client in
            _ = try await client.validateIdentity(apiKey: "synthetic-api-key")
        }

        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CloudAPIClient.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Structured server errors preserve authentication details")
    func structuredError() async throws {
        do {
            try await performRequests(
                responses: [
                    #"""
                    {
                      "code": "invalid_api_key",
                      "userMessage": "That API key is not valid.",
                      "retryable": false,
                      "source": "ui"
                    }
                    """#,
                ],
                statusCode: 401
            ) { _ in
            } operation: { client in
                _ = try await client.validateIdentity(apiKey: "synthetic-api-key")
            }
            Issue.record("Expected the request to fail.")
        } catch let error as CloudAPIClientError {
            #expect(
                error == .requestFailed(
                    statusCode: 401,
                    error: CloudStructuredError(
                        code: "invalid_api_key",
                        userMessage: "That API key is not valid.",
                        debugMessage: nil,
                        retryable: false,
                        source: "ui",
                        details: nil,
                        underlying: nil
                    )
                )
            )
            #expect(error.isAuthenticationFailure)
            #expect(error.localizedDescription == "That API key is not valid.")
        }
    }

    @Test("Client errors never retain the bearer credential")
    func errorsDoNotRetainCredential() {
        let apiKey = "synthetic-secret-api-key"
        let errors: [CloudAPIClientError] = [
            .invalidResponse,
            .missingCredential,
            .requestFailed(statusCode: 500, error: nil),
        ]

        #expect(errors.allSatisfy { !String(reflecting: $0).contains(apiKey) })
        #expect(errors.allSatisfy { !$0.localizedDescription.contains(apiKey) })
    }

    @Test("Request cancellation recognizes task and URL cancellation errors")
    func requestCancellation() {
        #expect(
            CloudAPIClientError.isRequestCancellation(
                CancellationError()
            )
        )
        #expect(
            CloudAPIClientError.isRequestCancellation(
                URLError(.cancelled)
            )
        )
        #expect(
            !CloudAPIClientError.isRequestCancellation(
                URLError(.notConnectedToInternet)
            )
        )
    }

    @Test("Stored and candidate identity checks use separate credentials")
    func identityCredentialOwnership() async throws {
        let credentialLoads = LockIsolated(0)
        let authorizationHeaders = LockIsolated<[String]>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            credentialLoads.withValue { $0 += 1 }
            return "stored-api-key"
        }

        try await withDependencies {
            $0.cloudAPITransport.data = { request in
                authorizationHeaders.withValue {
                    $0.append(
                        request.value(
                            forHTTPHeaderField: "Authorization"
                        ) ?? ""
                    )
                }
                return try testResponse(
                    #"""
                    {
                      "userId": "user-1",
                      "authMethod": "api-key"
                    }
                    """#,
                    for: request
                )
            }
        } operation: {
            _ = try await client.getIdentity()
            _ = try await client.validateIdentity(apiKey: "candidate-api-key")
        }

        #expect(credentialLoads.value == 1)
        #expect(
            authorizationHeaders.value
                == ["Bearer stored-api-key", "Bearer candidate-api-key"]
        )
    }

    @Test(
        "Polling paginates, deduplicates snapshots, and refreshes status cadences"
    )
    func pollingCadencePaginationAndDeduplication() async throws {
        let clock = TestClock()
        let fixture = PollingTransportFixture()
        let credentialLoads = LockIsolated(0)
        let snapshots = LockIsolated<[CloudWorkspaceSnapshot]>([])
        let errors = LockIsolated<[String]>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            credentialLoads.withValue { $0 += 1 }
            return "stored-api-key"
        }

        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                try await fixture.response(for: request)
            }
            $0.continuousClock = clock
        } operation: {
            Task {
                do {
                    for try await snapshot in client.observeWorkspaces() {
                        snapshots.withValue { $0.append(snapshot) }
                    }
                } catch {
                    errors.withValue {
                        $0.append(error.localizedDescription)
                    }
                }
            }
        }

        await waitForCloudCondition { snapshots.value.count == 1 }
        let firstSnapshot = try #require(snapshots.value.first)
        #expect(firstSnapshot.accountID == "user-1:organization-1:workspace-1")
        #expect(firstSnapshot.projects.map(\.id) == ["project-1", "project-2"])
        #expect(
            firstSnapshot.workspaces.map(\.id)
                == ["stable", "dynamic", "unknown"]
        )
        #expect(
            firstSnapshot.statuses["unknown"]?.status.rawValue
                == "future-status"
        )
        #expect(await fixture.projectOffsets() == [0, 1])
        #expect(await fixture.workspaceOffsets(projectID: "project-1") == [0, 1])
        #expect(credentialLoads.value == 1)

        for expectedCycleCount in 2...5 {
            for _ in 0..<10 {
                guard await fixture.cycleCount() < expectedCycleCount else {
                    break
                }
                await clock.advance(by: .milliseconds(2_500))
                await Task.yield()
            }
            #expect(await fixture.cycleCount() == expectedCycleCount)
        }

        await waitForCloudCondition {
            let stableCount = await fixture.statusRequestCount(
                workspaceID: "stable"
            )
            let dynamicCount = await fixture.statusRequestCount(
                workspaceID: "dynamic"
            )
            let unknownCount = await fixture.statusRequestCount(
                workspaceID: "unknown"
            )
            return stableCount == 2
                && dynamicCount == 5
                && unknownCount == 5
        }
        #expect(await fixture.statusRequestCount(workspaceID: "stable") == 2)
        #expect(await fixture.statusRequestCount(workspaceID: "dynamic") == 5)
        #expect(await fixture.statusRequestCount(workspaceID: "unknown") == 5)
        #expect(snapshots.value.count == 1)
        #expect(credentialLoads.value == 5)

        await fixture.updateDynamicStatus()
        for _ in 0..<10 {
            guard snapshots.value.count < 2 else {
                break
            }
            await clock.advance(by: .milliseconds(2_500))
            await Task.yield()
        }
        await waitForCloudCondition { snapshots.value.count == 2 }
        #expect(snapshots.value.last?.statuses["dynamic"]?.status == .ready)

        observation.cancel()
        await observation.value
        #expect(errors.value.isEmpty)
    }

    @Test("A later polling cycle uses a same-account replacement key")
    func pollingReloadsReplacementKey() async throws {
        let clock = TestClock()
        let storedAPIKey = LockIsolated("original-key")
        let requests = LockIsolated<[(String, String)]>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            storedAPIKey.value
        }

        let observation = withDependencies {
            $0.continuousClock = clock
            $0.cloudAPITransport.data = { request in
                requests.withValue {
                    $0.append(
                        (
                            request.url?.path ?? "",
                            request.value(forHTTPHeaderField: "Authorization")
                                ?? ""
                        )
                    )
                }
                let body = request.url?.path == "/me"
                    ? #"{"userId":"same-user","authMethod":"api-key"}"#
                    : #"{"data":[],"offset":0,"hasMore":false}"#
                return try testResponse(body, for: request)
            }
        } operation: {
            Task {
                for try await _ in client.observeWorkspaces() { }
            }
        }

        await waitForCloudCondition {
            requests.value.contains {
                $0.0 == "/v0/projects"
                    && $0.1 == "Bearer original-key"
            }
        }
        storedAPIKey.withValue { $0 = "replacement-key" }
        await clock.advance(by: .milliseconds(2_500))
        await waitForCloudCondition {
            requests.value.contains {
                $0.0 == "/v0/projects"
                    && $0.1 == "Bearer replacement-key"
            }
        }

        observation.cancel()
        try await observation.value
    }

    @Test("A failed status request does not discard healthy Cloud workspaces")
    func partialStatusFailure() async throws {
        let clock = TestClock()
        let snapshots = LockIsolated<[CloudWorkspaceSnapshot]>([])
        let errors = LockIsolated<[String]>([])
        let statusPaths = LockIsolated<Set<String>>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }

        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                let path = request.url?.path ?? ""
                switch path {
                case "/me":
                    return try testResponse(
                        #"{"userId":"user-1","authMethod":"api-key"}"#,
                        for: request
                    )

                case "/v0/projects":
                    return try testResponse(
                        page(
                            data: #"""
                            {
                              "id": "project-1",
                              "name": "One",
                              "gitRemote": "https://example.test/one.git"
                            }
                            """#,
                            offset: 0,
                            hasMore: false
                        ),
                        for: request
                    )

                case "/v0/projects/project-1/workspaces":
                    return try testResponse(
                        page(
                            data: [
                                workspaceJSON(id: "healthy"),
                                workspaceJSON(id: "server-rejected"),
                            ]
                            .joined(separator: ","),
                            offset: 0,
                            hasMore: false
                        ),
                        for: request
                    )

                case "/v0/workspaces/healthy/status":
                    _ = statusPaths.withValue { $0.insert(path) }
                    return try testResponse(
                        statusJSON(
                            workspaceID: "healthy",
                            status: "ready"
                        ),
                        for: request
                    )

                case "/v0/workspaces/server-rejected/status":
                    _ = statusPaths.withValue { $0.insert(path) }
                    return try testResponse(
                        #"""
                        {
                          "userMessage": "Invalid input",
                          "retryable": true
                        }
                        """#,
                        for: request,
                        statusCode: 500
                    )

                default:
                    throw CloudAPIClientError.invalidResponse
                }
            }
            $0.continuousClock = clock
        } operation: {
            Task {
                do {
                    for try await snapshot in client.observeWorkspaces() {
                        snapshots.withValue { $0.append(snapshot) }
                    }
                } catch {
                    errors.withValue { $0.append(error.localizedDescription) }
                }
            }
        }

        await waitForCloudCondition { snapshots.value.count == 1 }
        let snapshot = try #require(snapshots.value.first)
        #expect(
            snapshot.workspaces.map(\.id)
                == ["healthy", "server-rejected"]
        )
        #expect(Set(snapshot.statuses.keys) == ["healthy"])
        #expect(
            statusPaths.value == [
                "/v0/workspaces/healthy/status",
                "/v0/workspaces/server-rejected/status",
            ]
        )

        observation.cancel()
        await observation.value
        #expect(errors.value.isEmpty)
    }

    @Test("Polling limits concurrent status requests to eight")
    func pollingStatusConcurrency() async throws {
        let fixture = StatusConcurrencyTransportFixture()
        let snapshots = LockIsolated<[CloudWorkspaceSnapshot]>([])
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }
        let clock = TestClock()
        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                try await fixture.response(for: request)
            }
            $0.continuousClock = clock
        } operation: {
            Task {
                for try await snapshot in client.observeWorkspaces() {
                    snapshots.withValue { $0.append(snapshot) }
                }
            }
        }

        await waitForCloudCondition {
            await fixture.statusRequestCount() == 8
        }
        #expect(await fixture.maximumConcurrentStatusRequests() == 8)
        await fixture.releaseStatusRequests()
        await waitForCloudCondition {
            await fixture.statusRequestCount() == 9
        }
        #expect(await fixture.maximumConcurrentStatusRequests() == 8)
        await fixture.releaseStatusRequests()
        await waitForCloudCondition { snapshots.value.count == 1 }

        observation.cancel()
        _ = try? await observation.value
    }

    @Test("Ending stream consumption cancels an in-flight poll")
    func pollingCancellation() async {
        let pollStarted = LockIsolated(false)
        let pollCancelled = LockIsolated(false)
        let client = CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-api-key"
        }
        let observation = withDependencies {
            $0.cloudAPITransport.data = { request in
                if request.url?.path == "/me" {
                    return try testResponse(
                        #"{"userId":"user-1","authMethod":"api-key"}"#,
                        for: request
                    )
                }
                pollStarted.setValue(true)
                return try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(3_600))
                    throw CloudAPIClientError.invalidResponse
                } onCancel: {
                    pollCancelled.setValue(true)
                }
            }
        } operation: {
            Task {
                for try await _ in client.observeWorkspaces() {
                }
            }
        }

        await waitForCloudCondition { pollStarted.value }
        observation.cancel()
        _ = try? await observation.value
        await waitForCloudCondition { pollCancelled.value }
    }

    @Test("Observation retry classification honors authentication and API hints")
    func observationRetryClassification() {
        let authenticationError = CloudAPIClientError.requestFailed(
            statusCode: 401,
            error: nil
        )
        let explicitNonRetryable = CloudAPIClientError.requestFailed(
            statusCode: 503,
            error: CloudStructuredError(
                code: "maintenance",
                userMessage: "Unavailable",
                debugMessage: nil,
                retryable: false,
                source: nil,
                details: nil,
                underlying: nil
            )
        )
        let explicitRetryable = CloudAPIClientError.requestFailed(
            statusCode: 429,
            error: CloudStructuredError(
                code: "rate_limited",
                userMessage: "Try again",
                debugMessage: nil,
                retryable: true,
                source: nil,
                details: nil,
                underlying: nil
            )
        )

        #expect(
            !CloudAPIClientError.shouldRetryObservation(
                after: authenticationError
            )
        )
        #expect(
            !CloudAPIClientError.shouldRetryObservation(
                after: explicitNonRetryable
            )
        )
        #expect(
            CloudAPIClientError.shouldRetryObservation(
                after: explicitRetryable
            )
        )
        #expect(
            CloudAPIClientError.shouldRetryObservation(
                after: URLError(.notConnectedToInternet)
            )
        )
    }

    private var testClient: CloudAPIClient {
        CloudAPIClient.live(baseURL: testBaseURL) {
            "stored-synthetic-api-key"
        }
    }

    private var testBaseURL: URL {
        guard let baseURL = URL(string: "https://cloud.test") else {
            preconditionFailure("The synthetic test URL must be valid.")
        }
        return baseURL
    }

    private func performRequest(
        response: String,
        operation: (CloudAPIClient) async throws -> Void
    ) async throws -> URLRequest {
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        try await performRequests(responses: [response]) { request in
            recordedRequest.setValue(request)
        } operation: { client in
            try await operation(client)
        }
        return try #require(recordedRequest.value)
    }

    private func performRequests(
        responses: [String],
        statusCode: Int = 200,
        request: @escaping @Sendable (URLRequest) -> Void,
        operation: (CloudAPIClient) async throws -> Void
    ) async throws {
        let pendingResponses = LockIsolated(responses)

        try await withDependencies {
            $0.cloudAPITransport.data = { urlRequest in
                request(urlRequest)
                let body = try #require(
                    pendingResponses.withValue {
                        $0.isEmpty ? nil : $0.removeFirst()
                    }
                )
                let requestURL = try #require(urlRequest.url)
                let response = try #require(
                    HTTPURLResponse(
                        url: requestURL,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                return (Data(body.utf8), response)
            }
        } operation: {
            try await operation(testClient)
        }
    }
}

private actor PollingTransportFixture {
    private var dynamicStatusRevision = 0
    private var observedProjectOffsets: [Int] = []
    private var observedWorkspaceOffsets: [String: [Int]] = [:]
    private var observedStatusRequestCounts: [String: Int] = [:]
    private var observedCycleCount = 0

    func response(
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let offset = requestOffset(request)

        switch path {
        case "/me":
            return try testResponse(
                #"""
                {
                  "userId": "user-1",
                  "organizationId": "organization-1",
                  "workspaceId": "workspace-1",
                  "authMethod": "api-key"
                }
                """#,
                for: request
            )

        case "/v0/projects":
            observedProjectOffsets.append(offset)
            if offset == 0 {
                observedCycleCount += 1
                return try testResponse(
                    page(
                        data: #"""
                        {
                          "id": "project-1",
                          "name": "One",
                          "gitRemote": "https://example.test/one.git"
                        }
                        """#,
                        offset: 0,
                        hasMore: true
                    ),
                    for: request
                )
            }
            return try testResponse(
                page(
                    data: #"""
                    {
                      "id": "project-2",
                      "name": "Two",
                      "gitRemote": "https://example.test/two.git"
                    }
                    """#,
                    offset: 1,
                    hasMore: false
                ),
                for: request
            )

        case "/v0/projects/project-1/workspaces":
            observedWorkspaceOffsets["project-1", default: []].append(offset)
            let workspaceID = offset == 0 ? "stable" : "dynamic"
            return try testResponse(
                page(
                    data: workspaceJSON(id: workspaceID),
                    offset: offset,
                    hasMore: offset == 0
                ),
                for: request
            )

        case "/v0/projects/project-2/workspaces":
            observedWorkspaceOffsets["project-2", default: []].append(offset)
            return try testResponse(
                page(
                    data: workspaceJSON(id: "unknown"),
                    offset: 0,
                    hasMore: false
                ),
                for: request
            )

        default:
            guard path.hasPrefix("/v0/workspaces/"),
                  path.hasSuffix("/status")
            else {
                throw CloudAPIClientError.invalidResponse
            }
            let workspaceID = path
                .split(separator: "/")
                .dropFirst(2)
                .first
                .map(String.init) ?? ""
            observedStatusRequestCounts[workspaceID, default: 0] += 1
            let status = switch workspaceID {
            case "stable":
                "ready"

            case "dynamic":
                dynamicStatusRevision == 0 ? "initializing" : "ready"

            default:
                "future-status"
            }
            return try testResponse(
                statusJSON(
                    workspaceID: workspaceID,
                    status: status
                ),
                for: request
            )
        }
    }

    func cycleCount() -> Int {
        observedCycleCount
    }

    func projectOffsets() -> [Int] {
        observedProjectOffsets
    }

    func statusRequestCount(workspaceID: String) -> Int {
        observedStatusRequestCounts[workspaceID, default: 0]
    }

    func updateDynamicStatus() {
        dynamicStatusRevision = 1
    }

    func workspaceOffsets(projectID: String) -> [Int] {
        observedWorkspaceOffsets[projectID, default: []]
    }
}

private actor StatusConcurrencyTransportFixture {
    private var activeStatusRequestCount = 0
    private var maximumActiveStatusRequestCount = 0
    private var observedStatusRequestCount = 0
    private var statusWaiters: [CheckedContinuation<Void, Never>] = []

    func response(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        switch path {
        case "/me":
            return try testResponse(
                #"{"userId":"user-1","authMethod":"api-key"}"#,
                for: request
            )

        case "/v0/projects":
            return try testResponse(
                page(
                    data: #"""
                    {
                      "id": "project-1",
                      "name": "One",
                      "gitRemote": "https://example.test/one.git"
                    }
                    """#,
                    offset: 0,
                    hasMore: false
                ),
                for: request
            )

        case "/v0/projects/project-1/workspaces":
            let workspaces = (1...9)
                .map { workspaceJSON(id: "workspace-\($0)") }
                .joined(separator: ",")
            return try testResponse(
                page(
                    data: workspaces,
                    offset: 0,
                    hasMore: false
                ),
                for: request
            )

        default:
            guard path.hasPrefix("/v0/workspaces/"),
                  path.hasSuffix("/status")
            else {
                throw CloudAPIClientError.invalidResponse
            }
            let workspaceID = path
                .split(separator: "/")
                .dropFirst(2)
                .first
                .map(String.init) ?? ""
            observedStatusRequestCount += 1
            activeStatusRequestCount += 1
            maximumActiveStatusRequestCount = max(
                maximumActiveStatusRequestCount,
                activeStatusRequestCount
            )
            await withCheckedContinuation { continuation in
                statusWaiters.append(continuation)
            }
            activeStatusRequestCount -= 1
            return try testResponse(
                statusJSON(
                    workspaceID: workspaceID,
                    status: "ready"
                ),
                for: request
            )
        }
    }

    func maximumConcurrentStatusRequests() -> Int {
        maximumActiveStatusRequestCount
    }

    func releaseStatusRequests() {
        let waiters = statusWaiters
        statusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func statusRequestCount() -> Int {
        observedStatusRequestCount
    }
}

private func page(
    data: String,
    offset: Int,
    hasMore: Bool
) -> String {
    """
    {
      "data": [\(data)],
      "offset": \(offset),
      "hasMore": \(hasMore)
    }
    """
}

private func requestOffset(_ request: URLRequest) -> Int {
    guard let url = request.url,
          let value = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )?
          .queryItems?
          .first(where: { $0.name == "offset" })?
          .value,
          let offset = Int(value)
    else {
        return 0
    }
    return offset
}

private func statusJSON(
    workspaceID: String,
    status: String
) -> String {
    """
    {
      "workspaceId": "\(workspaceID)",
      "status": "\(status)"
    }
    """
}

private func testResponse(
    _ body: String,
    for request: URLRequest,
    statusCode: Int = 200
) throws -> (Data, HTTPURLResponse) {
    let requestURL = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )
    )
    return (Data(body.utf8), response)
}

@MainActor
private func waitForCloudCondition(
    _ condition: @escaping () async -> Bool
) async {
    for _ in 0..<10_000 {
        guard !(await condition()) else {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for an asynchronous Cloud test condition.")
}

private func workspaceJSON(id: String) -> String {
    """
    {
      "id": "\(id)",
      "name": "\(id)",
      "createdAt": "1970-01-01T00:00:00Z",
      "lastActivityAt": "1970-01-01T00:00:00Z"
    }
    """
}
