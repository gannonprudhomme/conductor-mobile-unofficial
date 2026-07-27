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
            _ = try await client.getIdentity(apiKey: "synthetic-api-key")
        }

        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CloudAPIClient.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Pagination requests encode stable paths and query parameters")
    func paginationRequests() async throws {
        let requests = LockIsolated<[URLRequest]>([])
        let page = #"{"data":[],"offset":50,"hasMore":false}"#

        try await performRequests(responses: [page, page]) { request in
            requests.withValue { $0.append(request) }
        } operation: { client in
            _ = try await client.getProjects(limit: 50, offset: 0)
            _ = try await client.getWorkspaces(
                projectID: "project/with slash",
                limit: 50,
                offset: 50
            )
        }

        #expect(requests.value[0].url?.path == "/v0/projects")
        #expect(
            URLComponents(url: try #require(requests.value[0].url), resolvingAgainstBaseURL: false)?
                .queryItems == [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "offset", value: "0"),
                ]
        )
        #expect(
            requests.value[1].url?.absoluteString
                .hasPrefix("https://cloud.test/v0/projects/project%2Fwith%20slash/workspaces")
                == true
        )
        #expect(
            URLComponents(url: try #require(requests.value[1].url), resolvingAgainstBaseURL: false)?
                .queryItems == [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "offset", value: "50"),
                ]
        )
    }

    @Test("Pagination follows server offsets until every project page is loaded")
    func followsPagination() async throws {
        let requests = LockIsolated<[URLRequest]>([])
        let pages = [
            #"""
            {
              "data": [
                {"id":"project-1","name":"One","gitRemote":"https://example.test/one.git"},
                {"id":"project-2","name":"Two","gitRemote":"https://example.test/two.git"}
              ],
              "offset": 0,
              "hasMore": true
            }
            """#,
            #"""
            {
              "data": [
                {"id":"project-3","name":"Three","gitRemote":"https://example.test/three.git"}
              ],
              "offset": 2,
              "hasMore": false
            }
            """#,
        ]

        var projects: [CloudProject] = []
        try await performRequests(responses: pages) { request in
            requests.withValue { $0.append(request) }
        } operation: { client in
            projects = try await client.allProjects(pageSize: 2)
        }

        #expect(projects.map(\.id) == ["project-1", "project-2", "project-3"])
        #expect(
            URLComponents(
                url: try #require(requests.value[1].url),
                resolvingAgainstBaseURL: false
            )?
            .queryItems?
            .contains(URLQueryItem(name: "offset", value: "2")) == true
        )
    }

    @Test("A non-advancing pagination response fails instead of looping")
    func nonAdvancingPagination() async throws {
        let page = #"""
            {
              "data": [
                {"id":"project-1","name":"One","gitRemote":"https://example.test/one.git"}
              ],
              "offset": -1,
              "hasMore": true
            }
            """#

        await #expect(throws: CloudAPIClientError.invalidResponse) {
            try await performRequests(responses: [page]) { _ in
            } operation: { client in
                _ = try await client.allProjects(pageSize: 1)
            }
        }
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
                _ = try await client.getIdentity(apiKey: "synthetic-api-key")
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

    @Test("The injected transport surfaces offline errors unchanged")
    func offlineTransport() async {
        await #expect(throws: URLError.self) {
            try await withDependencies {
                $0.cloudAPITransport.data = { _ in
                    throw URLError(.notConnectedToInternet)
                }
            } operation: {
                _ = try await testClient.getProjects(limit: 1, offset: 0)
            }
        }
    }

    private var testClient: CloudAPIClient {
        guard let baseURL = URL(string: "https://cloud.test") else {
            preconditionFailure("The synthetic test URL must be valid.")
        }
        return CloudAPIClient.live(baseURL: baseURL) {
            "stored-synthetic-api-key"
        }
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
