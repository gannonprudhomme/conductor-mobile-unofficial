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

@Suite(.serialized)
struct CloudAPIClientTests {
    @Test("Requests include bearer authorization and the app User-Agent")
    func requestHeaders() async throws {
        let request = try await performRequest(
            response: #"""
                {
                  "userId": "user-1",
                  "authMethod": "api-key"
                }
                """#
        ) { client in
            _ = try await client.testConnection(apiKey: "synthetic-api-key")
        }

        #expect(request.url?.path == "/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == CloudAPIClient.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("Pagination endpoints construct stable paths and offsets")
    func paginationRequests() async throws {
        let requests = LockIsolated<[URLRequest]>([])
        let page = #"{"data":[],"offset":50,"hasMore":false}"#

        _ = try await performRequests(responses: [page, page]) { request in
            requests.withValue { $0.append(request) }
        } operation: { client in
            _ = try await client.projects(limit: 50, offset: 0)
            _ = try await client.workspaces(
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
                .queryItems?.last == URLQueryItem(name: "offset", value: "50")
        )
    }

    @Test("Pagination follows server offsets until all project pages are loaded")
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

    @Test("Incremental transcript requests use after without combining offset")
    func incrementalMessages() async throws {
        let request = try await performRequest(
            response: #"{"data":[],"offset":0,"hasMore":false}"#
        ) { client in
            _ = try await client.messages(
                sessionID: "session-1",
                limit: 100,
                offset: 400,
                after: "message-9"
            )
        }
        let queryItems = URLComponents(
            url: try #require(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems

        #expect(request.url?.path == "/v0/sessions/session-1/messages")
        #expect(queryItems?.contains(URLQueryItem(name: "after", value: "message-9")) == true)
        #expect(queryItems?.contains { $0.name == "offset" } == false)
    }

    @Test("Sending a prompt uses the documented body and returns its server identifier")
    func sendMessage() async throws {
        let response = #"{"messageId":"server-message-1","state":"queued"}"#
        var result: CloudSendMessageResponse?
        let request = try await performRequest(response: response) { client in
            result = try await client.sendMessage(
                sessionID: "session-1",
                messageID: "client-message-1",
                message: "Run the tests."
            )
        }
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )

        #expect(request.httpMethod == "POST")
        #expect(
            object == [
                "messageId": "client-message-1",
                "message": "Run the tests.",
            ]
        )
        #expect(result?.messageID == "server-message-1")
        #expect(result?.state == .queued)
    }

    @Test("Creating a cloud workspace uses the documented project request")
    func createWorkspace() async throws {
        let response = #"""
            {
              "workspaceId": "workspace-1",
              "sessionId": "session-1",
              "deepLink": "conductor://workspace/workspace-1"
            }
            """#
        var result: CloudCreateWorkspaceResponse?
        let request = try await performRequest(response: response) { client in
            result = try await client.createWorkspace(
                request: CloudCreateWorkspaceRequest(
                    projectID: "project-1",
                    agent: "codex",
                    model: "gpt-5.6-sol",
                    effort: "high"
                )
            )
        }
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v0/workspaces")
        #expect(
            object == [
                "projectId": "project-1",
                "agent": "codex",
                "model": "gpt-5.6-sol",
                "effort": "high",
            ]
        )
        #expect(result?.workspaceID == "workspace-1")
        #expect(result?.sessionID == "session-1")
    }

    @Test("Creating a cloud session uses the selected chat settings")
    func createSession() async throws {
        let response = #"""
            {
              "id": "session-2",
              "deepLink": "conductor://workspace/workspace-1/session/session-2",
              "name": "Untitled",
              "model": "gpt-5.6-sol",
              "fastMode": true
            }
            """#
        var result: CloudSession?
        let request = try await performRequest(response: response) { client in
            result = try await client.createSession(
                request: CloudCreateSessionRequest(
                    workspaceID: "workspace-1",
                    agent: "codex",
                    model: "gpt-5.6-sol",
                    fastMode: true
                )
            )
        }
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v0/sessions")
        #expect(object["workspaceId"] as? String == "workspace-1")
        #expect(object["agent"] as? String == "codex")
        #expect(object["model"] as? String == "gpt-5.6-sol")
        #expect(object["fastMode"] as? Bool == true)
        #expect(result?.id == "session-2")
    }

    @Test("Structured server errors preserve the human-readable message")
    func structuredError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        CloudAPIURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"""
                    {
                      "code": "invalid_api_key",
                      "userMessage": "That API key is not valid.",
                      "retryable": false,
                      "source": "ui"
                    }
                    """#.utf8
                )
            )
        }
        defer { CloudAPIURLProtocol.handler.setValue(nil) }

        do {
            _ = try await withDependencies {
                $0.urlSession = urlSession
            } operation: {
                try await testClient.testConnection(apiKey: "synthetic-api-key")
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

    private var testClient: CloudAPIClient {
        guard let baseURL = URL(string: "https://cloud.test") else {
            preconditionFailure("The synthetic test URL must be valid.")
        }
        return CloudAPIClient.live(
            baseURL: baseURL
        ) {
            "stored-synthetic-api-key"
        }
    }

    private func performRequest(
        response: String,
        operation: (CloudAPIClient) async throws -> Void
    ) async throws -> URLRequest {
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        _ = try await performRequests(responses: [response]) { request in
            recordedRequest.setValue(request)
        } operation: { client in
            try await operation(client)
        }
        return try #require(recordedRequest.value)
    }

    private func performRequests(
        responses: [String],
        request: @escaping @Sendable (URLRequest) -> Void,
        operation: (CloudAPIClient) async throws -> Void
    ) async throws {
        let pendingResponses = LockIsolated(responses)
        CloudAPIURLProtocol.handler.setValue { urlRequest in
            request(urlRequest)
            let response = try #require(
                pendingResponses.withValue {
                    $0.isEmpty ? nil : $0.removeFirst()
                }
            )
            return (
                HTTPURLResponse(
                    url: try #require(urlRequest.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(response.utf8)
            )
        }
        defer { CloudAPIURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        try await withDependencies {
            $0.urlSession = urlSession
        } operation: {
            try await operation(testClient)
        }
    }
}

private final class CloudAPIURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = LockIsolated<
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    >(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler.value)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else {
            return nil
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        var count: Int
        repeat {
            count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            body.append(contentsOf: buffer[..<count])
        } while count > 0
        return body
    }
}
