//
//  DesktopClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Dependencies
import DependenciesMacros
import Foundation
import Sharing

@DependencyClient
public struct DesktopClient: Sendable {
    public var checkConnection: @Sendable (_ serverAddress: String) async throws -> Void
    public var createWorkspace:
        @Sendable (_ repositoryID: String, _ prompt: String) async throws -> Void
    public var observeMessages: @Sendable (_ workspaceID: String, _ sessionID: String) -> AsyncThrowingStream<[Message], any Error> = { _, _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var observeSessions: @Sendable (_ workspaceID: String) -> AsyncThrowingStream<[Session], any Error> = { _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var observeWorkspaces: @Sendable () -> AsyncThrowingStream<WorkspaceListSnapshot, any Error> = {
        AsyncThrowingStream { $0.finish() }
    }
    public var ping: @Sendable () async throws -> Void = { }
    public var sendMessage: @Sendable (_ workspaceID: String, _ sessionID: String, _ message: String) async throws -> Message?
    public var setWorkspacePinned: @Sendable (_ workspaceID: String, _ pinned: Bool) async throws -> Void
    public var setWorkspaceStatus: @Sendable (_ workspaceID: String, _ status: Workspace.Status) async throws -> Void
    public var setWorkspaceUnread: @Sendable (_ workspaceID: String, _ unread: Bool) async throws -> Void
    public var stopSession: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Session?

    public enum ConnectionStatus: Equatable, Sendable {
        case connected
        case connecting
        case disconnected
    }

    public enum DeviceIcon: String, CaseIterable, Codable, Equatable, Sendable {
        case desktop
        case laptop
        case server
    }

    public struct DisplayConfiguration: Codable, Equatable, Sendable {
        public var name: String
        public var icon: DeviceIcon

        public init(name: String, icon: DeviceIcon) {
            self.name = name
            self.icon = icon
        }
    }
}

public extension SharedKey where Self == InMemoryKey<DesktopClient.ConnectionStatus>.Default {
    static var desktopConnectionStatus: Self {
        Self[
            .inMemory("desktopConnectionStatus"),
            default: .connecting,
        ]
    }
}

public enum DesktopClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case invalidServerAddress
    case requestFailed(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The desktop service returned an invalid response."

        case .invalidServerAddress:
            "Enter a valid desktop server address."

        case let .requestFailed(statusCode, message):
            if message.isEmpty {
                "The desktop service returned HTTP \(statusCode)."
            } else {
                "The desktop service returned HTTP \(statusCode): \(message)"
            }
        }
    }

    public static func isConnectionFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ENOTCONN.rawValue) {
            return true
        }

        guard let urlError = error as? URLError else {
            return false
        }

        return switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dataNotAllowed,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            true

        default:
            false
        }
    }
}

extension DesktopClient: DependencyKey {
    static let defaultServerPort = 3_768

    public static var liveValue: Self {
        Self { serverAddress in
            try await ping(serverAddress: serverAddress)
        } createWorkspace: { repositoryID, prompt in
            try await post(
                CreateWorkspaceBody(repositoryID: repositoryID, prompt: prompt),
                to: baseURL().appending(path: "workspaces"),
                expectedStatus: 202
            )
        } observeMessages: { workspaceID, sessionID in
            // Messages are the only unbounded observation: frames after the initial snapshot
            // contain incremental changes, so dropping one could permanently miss an update.
            // Workspace and session frames are complete snapshots and can safely keep only the
            // newest pending value.
            observe([Message].self, bufferingPolicy: .unbounded) { serverAddress in
                messagesWebSocketURL(
                    serverAddress: serverAddress,
                    workspaceID: workspaceID,
                    sessionID: sessionID
                )
            }
        } observeSessions: { workspaceID in
            observe([Session].self) { serverAddress in
                sessionsWebSocketURL(
                    serverAddress: serverAddress,
                    workspaceID: workspaceID
                )
            }
        } observeWorkspaces: {
            observe(WorkspaceListSnapshot.self) { serverAddress in
                workspacesWebSocketURL(serverAddress: serverAddress)
            }
        } ping: {
            try await ping()
        } sendMessage: { workspaceID, sessionID, message in
            try await post(
                ["message": message],
                to: messagesURL(workspaceID: workspaceID, sessionID: sessionID),
                decoding: Message.self
            )
        } setWorkspacePinned: { workspaceID, pinned in
            try await patch(
                WorkspacePatchBody(pinned: pinned),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceStatus: { workspaceID, status in
            try await patch(
                WorkspacePatchBody(status: status.rawValue),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceUnread: { workspaceID, unread in
            try await patch(
                WorkspacePatchBody(unread: unread),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } stopSession: { workspaceID, sessionID in
            try await post(
                [String: String](),
                // POST /workspaces/{workspaceID}/sessions/{sessionID}/stop
                to: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
                    .appending(path: "stop"),
                decoding: Session.self
            )
        }
    }

    private static func baseURL() throws -> URL {
        @Shared(.desktopServerAddress) var desktopServerAddress
        guard let desktopServerAddress,
              let baseURL = serverURL(scheme: "http", address: desktopServerAddress)
        else {
            throw DesktopClientError.invalidServerAddress
        }
        return baseURL
    }

    /// `scheme`` is either `http` or `ws`
    static func serverURL(scheme: String, address: String) -> URL? {
        guard var components = URLComponents(string: "\(scheme)://\(address)"),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }

        if components.port == nil {
            components.port = defaultServerPort
        }
        return components.url
    }

    static func ping(serverAddress: String) async throws {
        guard let url = serverURL(scheme: "http", address: serverAddress)?
            .appending(path: "ping")
        else {
            throw DesktopClientError.invalidServerAddress
        }

        // Settings can probe an unsaved draft address without changing the live connection status.
        @Dependency(\.urlSession) var urlSession

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await urlSession.data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    private static func ping() async throws {
        @Shared(.desktopConnectionStatus) var connectionStatus
        @Shared(.desktopServerAddress) var desktopServerAddress
        guard let desktopServerAddress else {
            return
        }

        $connectionStatus.withLock {
            if $0 == .disconnected {
                $0 = .connecting
            }
        }

        guard let url = serverURL(scheme: "http", address: desktopServerAddress)?
            .appending(path: "ping")
        else {
            throw DesktopClientError.invalidServerAddress
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    // POST /workspaces/{workspaceID}/sessions/{sessionID}/messages
    private static func messagesURL(workspaceID: String, sessionID: String) throws -> URL {
        try sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            .appending(path: "messages")
    }

    // POST /workspaces/{workspaceID}/sessions/{sessionID}
    private static func sessionURL(workspaceID: String, sessionID: String) throws -> URL {
        try baseURL()
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
            .appending(path: sessionID)
    }

    private static func workspaceURL(workspaceID: String) throws -> URL {
        try baseURL()
            .appending(path: "workspaces")
            .appending(path: workspaceID)
    }

    private static func post<Body: Encodable, Response: Decodable>(
        _ body: Body,
        to url: URL,
        decoding responseType: Response.Type
    ) async throws -> Response? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await data(for: request)
        let statusCode = try validateSuccessfulHTTPResponse(response, data: data)
        guard statusCode != 204 else {
            return nil
        }
        return try JSONDecoder.conductor.decode(responseType, from: data)
    }

    private static func post<Body: Encodable & Sendable>(
        _ body: Body,
        to url: URL,
        expectedStatus: Int
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await data(for: request)
        try validateSuccessfulHTTPResponse(
            response,
            data: data,
            expectedStatus: expectedStatus
        )
    }

    // URLSession only throws for transport failures, so validate HTTP status codes separately.
    @discardableResult
    private static func validateSuccessfulHTTPResponse(
        _ response: URLResponse,
        data: Data,
        expectedStatus: Int? = nil
    ) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        let isSuccessful = if let expectedStatus {
            response.statusCode == expectedStatus
        } else {
            (200..<300).contains(response.statusCode)
        }
        guard isSuccessful else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: errorMessage(from: data)
            )
        }
        return response.statusCode
    }

    static func errorMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
            ?? String(decoding: data, as: UTF8.self)
    }

    private struct ErrorResponse: Decodable {
        let error: Details

        struct Details: Decodable {
            let message: String
        }
    }

    private static func patch<Body: Encodable & Sendable>(
        _ body: Body,
        at url: URL
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    private static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        @Dependency(\.urlSession) var urlSession
        @Shared(.desktopConnectionStatus) var connectionStatus

        do {
            let result = try await urlSession.data(for: request)
            $connectionStatus.withLock { $0 = .connected }
            return result
        } catch {
            if DesktopClientError.isConnectionFailure(error) {
                $connectionStatus.withLock { $0 = .disconnected }
            }
            throw error
        }
    }
}

private struct CreateWorkspaceBody: Encodable, Sendable {
    let repositoryID: String
    let prompt: String

    enum CodingKeys: String, CodingKey {
        case repositoryID = "repository_id"
        case prompt
    }
}

private struct WorkspacePatchBody: Encodable, Sendable {
    var pinned: Bool? = nil
    var status: String? = nil
    var unread: Bool? = nil
}

public extension DesktopClient {
    // GET /repositories/{repositoryID}/icon
    static func repositoryIconURL(for repository: Repository) -> URL? {
        try? baseURL()
            .appending(path: "repositories")
            .appending(path: repository.id)
            .appending(path: "icon")
    }
}

public extension DependencyValues {
    var desktopClient: DesktopClient {
        get { self[DesktopClient.self] }
        set { self[DesktopClient.self] = newValue }
    }
}

public extension SharedKey where Self == FileStorageKey<String?>.Default {
    static var desktopServerAddress: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "desktop-server-address.json")
            ),
            default: nil,
        ]
    }
}

public extension SharedKey
where Self == FileStorageKey<DesktopClient.DisplayConfiguration?>.Default {
    static var desktopDisplayConfiguration: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "desktop-display-configuration.json")
            ),
            default: nil,
        ]
    }
}
