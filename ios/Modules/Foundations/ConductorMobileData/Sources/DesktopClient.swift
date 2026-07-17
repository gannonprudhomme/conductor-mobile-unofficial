//
//  DesktopClient.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Dependencies
import DependenciesMacros
import Foundation
import SharedConductorData
import Sharing

@DependencyClient
public struct DesktopClient: Sendable {
    public var checkConnection: @Sendable (_ serverAddress: String) async throws -> Void
    public var fetchDefaultModel: @Sendable () async throws -> Session.Model = {
        throw CancellationError()
    }
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
    public var sendMessage: @Sendable (
        _ workspaceID: String,
        _ sessionID: String,
        _ message: String,
        _ model: Session.Model
    ) async throws -> Message?
    public var setWorkspacePinned: @Sendable (_ workspaceID: String, _ isPinned: Bool) async throws -> WorkspaceMutationPath
    public var setWorkspaceStatus: @Sendable (_ workspaceID: String, _ status: Workspace.Status) async throws -> WorkspaceMutationPath
    public var setWorkspaceUnread: @Sendable (_ workspaceID: String, _ isUnread: Bool) async throws -> WorkspaceMutationPath
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

// A 204 persisted through the hook; a 202 used SQLite and may leave Conductor's window stale.
public enum WorkspaceMutationPath: Equatable, Sendable {
    case hook
    case sqliteFallback
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
        // iOS can abort a WebSocket while the app is suspended. Treat that like other transient
        // transport loss so observations reconnect instead of presenting an alert.
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ECONNABORTED.rawValue)
                || nsError.code == Int(POSIXErrorCode.ENOTCONN.rawValue) {
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
        } fetchDefaultModel: {
            let settings = try await get(SettingsResponse.self, from: settingsURL())
            return Session.Model(rawValue: settings.defaultModel)
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
        } sendMessage: { workspaceID, sessionID, message, model in
            try await post(
                SendMessageRequest(
                    message: message,
                    model: model.rawValue
                ),
                to: messagesURL(workspaceID: workspaceID, sessionID: sessionID),
                decoding: Message.self
            )
        } setWorkspacePinned: { workspaceID, isPinned in
            try await patch(
                WorkspacePatchBody(isPinned: isPinned),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceStatus: { workspaceID, status in
            try await patch(
                WorkspacePatchBody(status: status.rawValue),
                at: workspaceURL(workspaceID: workspaceID)
            )
        } setWorkspaceUnread: { workspaceID, isUnread in
            try await patch(
                WorkspacePatchBody(isUnread: isUnread),
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

    private struct SendMessageRequest: Encodable {
        let message: String
        let model: String
    }

    private struct SettingsResponse: Decodable {
        let defaultModel: String
    }

    private static func settingsURL() throws -> URL {
        try baseURL().appending(path: "settings")
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
        let request = try jsonRequest(method: "POST", body: body, url: url)
        let (data, response) = try await data(for: request)
        let statusCode = try validateSuccessfulHTTPResponse(response, data: data)
        guard statusCode != 204 else {
            return nil
        }
        return try JSONDecoder.conductor.decode(responseType, from: data)
    }

    private static func get<Response: Decodable>(
        _ responseType: Response.Type,
        from url: URL
    ) async throws -> Response {
        let (data, response) = try await data(for: URLRequest(url: url))
        try validateSuccessfulHTTPResponse(response, data: data)
        return try JSONDecoder.conductor.decode(responseType, from: data)
    }

    // URLSession only throws for transport failures, so validate HTTP status codes separately.
    @discardableResult
    private static func validateSuccessfulHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }
        return response.statusCode
    }

    private static func patch<Body: Encodable & Sendable>(
        _ body: Body,
        at url: URL
    ) async throws -> WorkspaceMutationPath {
        let request = try jsonRequest(method: "PATCH", body: body, url: url)
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        return try getWorkspaceMutationPathFromStatusCode(
            statusCode: response.statusCode,
            data: data
        )
    }

    private static func jsonRequest<Body: Encodable>(
        method: String,
        body: Body,
        url: URL
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func getWorkspaceMutationPathFromStatusCode(
        statusCode: Int,
        data: Data = Data()
    ) throws -> WorkspaceMutationPath {
        switch statusCode {
        case 204:
            return .hook

        case 202:
            return .sqliteFallback

        default:
            throw DesktopClientError.requestFailed(
                statusCode: statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }
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

struct WorkspacePatchBody: Encodable, Sendable {
    var isPinned: Bool? = nil
    var status: String? = nil
    var isUnread: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case isPinned = "pinned"
        case isUnread = "unread"
        case status
    }
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
