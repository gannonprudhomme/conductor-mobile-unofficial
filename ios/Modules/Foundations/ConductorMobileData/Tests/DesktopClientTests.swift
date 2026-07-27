//
//  DesktopClientTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

@testable import ConductorMobileData
import CustomDump
import Dependencies
import Foundation
import Sharing
import SharedConductorData
import Testing

@Suite(.serialized)
struct DesktopClientTests {
    @Test("Connection failures are distinguished from server and application errors")
    func connectionFailures() {
        let connectionErrors = [
            URLError(.cannotConnectToHost),
            URLError(.networkConnectionLost),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
        ]

        expectNoDifference(
            connectionErrors.map(DesktopClientError.isConnectionFailure),
            [true, true, true, true]
        )
        expectNoDifference(
            DesktopClientError.isConnectionFailure(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ECANCELED.rawValue)
                )
            ),
            true
        )
        expectNoDifference(
            DesktopClientError.isConnectionFailure(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ENOTCONN.rawValue)
                )
            ),
            true
        )
        expectNoDifference(
            DesktopClientError.isConnectionFailure(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ECONNABORTED.rawValue)
                )
            ),
            true
        )
        expectNoDifference(
            DesktopClientError.isConnectionFailure(
                DesktopClientError.requestFailed(statusCode: 503, message: "Unavailable")
            ),
            false
        )
    }

    @Test("Heartbeat requests update connection status while preserving their errors")
    func requestConnectionStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let client = DesktopClient.liveValue
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            @Shared(.desktopServerAddress) var desktopServerAddress
            $connectionStatus.withLock { $0 = .disconnected }
            $desktopServerAddress.withLock { $0 = "my-mac" }
            let requestedPaths = LockIsolated<[String]>([])
            DesktopClientURLProtocol.handler.setValue { request in
                requestedPaths.withValue { $0.append(request.url?.path ?? "") }
                return (
                    HTTPURLResponse(
                        url: try #require(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            defer { DesktopClientURLProtocol.handler.setValue(nil) }

            try await client.ping()
            expectNoDifference(connectionStatus, .connected)
            expectNoDifference(requestedPaths.value, ["/ping"])

            DesktopClientURLProtocol.handler.setValue { _ in
                throw URLError(.networkConnectionLost)
            }
            await #expect(throws: URLError.self) {
                try await client.ping()
            }
            expectNoDifference(connectionStatus, .disconnected)
        }
    }

    @Test("Heartbeat waits for a desktop server address")
    func requestConnectionStatusWithoutServerAddress() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.desktopConnectionStatus) var connectionStatus
            $connectionStatus.withLock { $0 = .disconnected }

            try await DesktopClient.liveValue.ping()

            expectNoDifference(connectionStatus, .disconnected)
        }
    }

    @Test("Default model is fetched from the desktop settings endpoint")
    func defaultModel() async throws {
        let requestedPath = LockIsolated<String?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            requestedPath.setValue(request.url?.path)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"defaultModel":"gpt-5.6-sol"}"#.utf8)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let model = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.fetchDefaultModel()
        }

        expectNoDifference(model, .gpt_5_6_sol)
        expectNoDifference(requestedPath.value, "/settings")
    }

    @Test("Commands reject a missing desktop server address")
    func commandsWithoutServerAddress() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await DesktopClient.liveValue.sendMessage(
                    workspaceID: "workspace-1",
                    sessionID: "session-1",
                    message: "Run the tests.",
                    model: .gpt_5_6_terra,
                    isFastModeEnabled: false,
                    reasoningEffort: .medium
                )
            }
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await DesktopClient.liveValue.createSession(workspaceID: "workspace-1")
            }
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await DesktopClient.liveValue.archiveWorkspace(workspaceID: "workspace-1")
            }
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await DesktopClient.liveValue.renameWorkspaceBranch(
                    workspaceID: "workspace-1",
                    branch: "renamed-branch"
                )
            }
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                try await DesktopClient.liveValue.setWorkspacePinned(
                    workspaceID: "workspace-1",
                    isPinned: true
                )
            }
            await #expect(throws: DesktopClientError.invalidServerAddress) {
                _ = try await DesktopClient.liveValue.createWorkspace(
                    workspaceID: "00000000-0000-0000-0000-000000000000",
                    repositoryID: "repository-1",
                    agentType: .codex,
                    model: .gpt_5_6_sol,
                    isFastModeEnabled: false
                )
            }
        }
    }

    @Test("Creating a session returns the canonical database row")
    func createSession() async throws {
        let session = Session.preview(id: "created", workspaceID: "workspace-1")
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(session)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.createSession(
                workspaceID: "workspace-1"
            )
        }

        expectNoDifference(response, session)
        let request = try #require(recordedRequest.value)
        expectNoDifference(request.url?.path, "/workspaces/workspace-1/sessions")
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        expectNoDifference(object, [:])
    }

    @Test("Sending a message returns the canonical database row")
    func sendMessage() async throws {
        let message = Message(
            id: "message-1",
            sessionID: "session-1",
            role: .user,
            content: "Run the tests.",
            createdAt: Date(timeIntervalSince1970: 1_783_555_200),
            turnID: "turn-1"
        )
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(message)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.sendMessage(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                message: "Run the tests.",
                model: .gpt_5_6_terra,
                isFastModeEnabled: true,
                reasoningEffort: .max
            )
        }

        expectNoDifference(response, message)
        let request = try #require(recordedRequest.value)
        expectNoDifference(
            request.url?.path,
            "/workspaces/workspace-1/sessions/session-1/messages"
        )
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["message"] as? String == "Run the tests.")
        #expect(object["model"] as? String == "gpt-5.6-terra")
        #expect(object["fast_mode"] as? Bool == true)
        #expect(object["reasoning_effort"] as? String == "max")
        #expect(object.count == 4)
    }

    @Test("Sending supports a legacy no-content response")
    func sendMessageLegacyResponse() async throws {
        DesktopClientURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.sendMessage(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                message: "Run the tests.",
                model: .gpt_5_6_terra,
                isFastModeEnabled: false,
                reasoningEffort: nil
            )
        }

        #expect(response == nil)
    }

    @Test("Stopping a session returns its canonical database row")
    func stopSession() async throws {
        let session = Session.preview(
            updatedAt: "2026-07-09T00:00:01Z",
            status: .idle
        )
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(session)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.stopSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
        }

        expectNoDifference(response, session)
        let request = try #require(recordedRequest.value)
        expectNoDifference(
            request.url?.path,
            "/workspaces/workspace-1/sessions/session-1/stop"
        )
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        expectNoDifference(object, [:])
    }

    @Test("Stopping supports a legacy no-content response")
    func stopSessionLegacyResponse() async throws {
        DesktopClientURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let response = try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            return try await DesktopClient.liveValue.stopSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
        }

        #expect(response == nil)
    }

    @Test("Creating a workspace matches the desktop API contract")
    func createWorkspace() async throws {
        let createdWorkspace = CreatedWorkspace(
            workspace: .preview(activeSessionID: "session-1"),
            session: .preview(id: "session-1")
        )
        let recordedRequest = LockIsolated<URLRequest?>(nil)
        DesktopClientURLProtocol.handler.setValue { request in
            recordedRequest.setValue(request)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder.conductor.encode(createdWorkspace)
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            let response = try await DesktopClient.liveValue.createWorkspace(
                workspaceID: "00000000-0000-0000-0000-000000000000",
                repositoryID: "repository-1",
                agentType: .codex,
                model: .gpt_5_6_terra,
                isFastModeEnabled: true
            )
            expectNoDifference(response, createdWorkspace)
        }

        let request = try #require(recordedRequest.value)
        expectNoDifference(request.url?.path, "/workspaces")
        expectNoDifference(request.httpMethod, "POST")
        expectNoDifference(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        let body = try #require(request.bodyData)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["agent_type"] as? String == "codex")
        #expect(object["fast_mode"] as? Bool == true)
        #expect(object["model"] as? String == "gpt-5.6-terra")
        #expect(object["repository_id"] as? String == "repository-1")
        #expect(
            object["workspace_id"] as? String
                == "00000000-0000-0000-0000-000000000000"
        )
        #expect(object.count == 5)
    }

    @Test("Creating a workspace requires a canonical response")
    func createWorkspaceRequiresResponse() async throws {
        DesktopClientURLProtocol.handler.setValue { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        await #expect(
            throws: DesktopClientError.invalidResponse
        ) {
            try await withDependencies {
                $0.defaultFileStorage = .inMemory
                $0.urlSession = urlSession
            } operation: {
                @Shared(.desktopServerAddress) var desktopServerAddress
                $desktopServerAddress.withLock { $0 = "my-mac" }
                _ = try await DesktopClient.liveValue.createWorkspace(
                    workspaceID: "00000000-0000-0000-0000-000000000000",
                    repositoryID: "repository-1",
                    agentType: .codex,
                    model: .gpt_5_6_sol,
                    isFastModeEnabled: false
                )
            }
        }
    }

    @Test("Desktop client errors include response details")
    func errorDescriptions() {
        #expect(
            DesktopClientError.requestFailed(statusCode: 500, message: "boom").localizedDescription
                == "The desktop service returned HTTP 500: boom"
        )

        #expect(
            DesktopClientError.requestFailed(statusCode: 404, message: "").localizedDescription
                == "The desktop service returned HTTP 404."
        )
    }

    @Test("Desktop display configuration defaults to nil and persists in file storage")
    func displayConfiguration() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.desktopDisplayConfiguration) var displayConfiguration

            expectNoDifference(displayConfiguration, nil)

            $displayConfiguration.withLock {
                $0 = DesktopClient.DisplayConfiguration(
                    name: "Office desktop",
                    icon: .desktop
                )
            }

            @Shared(.desktopDisplayConfiguration) var reloadedDisplayConfiguration
            expectNoDifference(
                reloadedDisplayConfiguration,
                Optional(
                    DesktopClient.DisplayConfiguration(
                        name: "Office desktop",
                        icon: .desktop
                    )
                )
            )
        }
    }

    @Test("Desktop client extracts Hummingbird error messages")
    func errorResponseMessage() {
        #expect(
            DesktopClient.errorMessage(
                from: Data(#"{"error":{"message":"Repository not found"}}"#.utf8)
            ) == "Repository not found"
        )
        #expect(
            DesktopClient.errorMessage(from: Data("Plain text error".utf8))
                == "Plain text error"
        )
    }

    @Test("Conductor decoder accepts SQLite and ISO 8601 dates")
    func dateDecoding() throws {
        let dates = try JSONDecoder.conductor.decode(
            [Date].self,
            from: Data(
                """
                [
                  "2026-07-09 00:00:00",
                  "2026-07-09T00:00:00Z",
                  "2026-07-09T00:00:00.000Z"
                ]
                """.utf8
            )
        )

        expectNoDifference(
            dates,
            Array(repeating: Date(timeIntervalSince1970: 1_783_555_200), count: 3)
        )
    }

    @Test("Repository icon URLs use the desktop icon endpoint")
    func repositoryIconURL() {
        withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            let repository = Repository(
                id: "repository-1",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository),
                nil
            )

            $desktopServerAddress.withLock { $0 = "my-mac" }

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository)?.absoluteString,
                "http://my-mac:3768/repositories/repository-1/icon"
            )

            $desktopServerAddress.withLock { $0 = "my-mac:4000" }

            expectNoDifference(
                DesktopClient.repositoryIconURL(for: repository)?.absoluteString,
                "http://my-mac:4000/repositories/repository-1/icon"
            )
        }
    }

    @Test("Session menu requests use the session endpoint")
    func sessionMenuRequests() async throws {
        let requests = LockIsolated<[URLRequest]>([])
        DesktopClientURLProtocol.handler.setValue { request in
            requests.withValue { $0.append(request) }
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { DesktopClientURLProtocol.handler.setValue(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopClientURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        try await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.urlSession = urlSession
        } operation: {
            @Shared(.desktopServerAddress) var desktopServerAddress
            $desktopServerAddress.withLock { $0 = "my-mac" }
            let client = DesktopClient.liveValue
            try await client.renameSession(
                workspaceID: "workspace-1",
                sessionID: "session-1",
                title: "Renamed chat"
            )
            try await client.closeSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
            try await client.restoreSession(
                workspaceID: "workspace-1",
                sessionID: "session-1"
            )
        }

        expectNoDifference(
            requests.value.map {
                "\($0.httpMethod ?? "") \($0.url?.path ?? "")"
            },
            [
                "PATCH /workspaces/workspace-1/sessions/session-1",
                "PATCH /workspaces/workspace-1/sessions/session-1",
                "PATCH /workspaces/workspace-1/sessions/session-1",
            ]
        )
        let bodies = try requests.value.map { request in
            let body = try #require(request.bodyData)
            return try #require(
                JSONSerialization.jsonObject(
                    with: body
                ) as? [String: AnyHashable]
            )
        }
        #expect(bodies[0] == ["title": AnyHashable("Renamed chat")])
        #expect(bodies[1] == ["hidden": AnyHashable(true)])
        #expect(bodies[2] == ["hidden": AnyHashable(false)])
    }

    @Test("UI-hook mutations map only exact 204 and 202 responses")
    func uiHookMutationResponses() throws {
        for (statusCode, expectedPath) in [
            (204, UIHookMutationPath.hook),
            (202, .sqliteFallback),
        ] {
            #expect(
                try DesktopClient.getUIHookMutationPathFromStatusCode(statusCode: statusCode)
                    == expectedPath
            )
        }
        for statusCode in [200, 201, 206, 400, 409, 500] {
            #expect(
                throws: DesktopClientError.requestFailed(
                    statusCode: statusCode,
                    message: "error"
                )
            ) {
                try DesktopClient.getUIHookMutationPathFromStatusCode(
                    statusCode: statusCode,
                    data: Data("error".utf8)
                )
            }
        }
    }

    @Test("Workspace mutation bodies encode exactly one absolute field")
    func workspaceMutationBodies() throws {
        let status = Workspace.Status.inReview.rawValue
        for (body, expectedJSON) in [
            (WorkspacePatchBody(shouldArchive: true), #"{"archive":true}"#),
            (WorkspacePatchBody(branch: "renamed-branch"), #"{"branch":"renamed-branch"}"#),
            (WorkspacePatchBody(isPinned: true), #"{"pinned":true}"#),
            (WorkspacePatchBody(status: status), #"{"status":"in-review"}"#),
            (WorkspacePatchBody(isUnread: false), #"{"unread":false}"#),
        ] {
            #expect(String(decoding: try JSONEncoder().encode(body), as: UTF8.self) == expectedJSON)
        }
    }
}

private final class DesktopClientURLProtocol: URLProtocol, @unchecked Sendable {
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
