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

@DependencyClient
public struct DesktopClient: Sendable {
    public var fetchMessages: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> [Message]
    public var fetchRepositories: @Sendable () async throws -> [Repository]
    public var fetchSessions: @Sendable (_ workspaceID: String) async throws -> [Session]
    public var fetchWorkspaces: @Sendable () async throws -> [WorkspaceSnapshot]
    public var sendMessage: @Sendable (_ workspaceID: String, _ sessionID: String, _ message: String) async throws -> Void
    public var setWorkspacePinned: @Sendable (_ workspaceID: String, _ pinned: Bool) async throws -> Void
    public var setWorkspaceStatus: @Sendable (_ workspaceID: String, _ status: Workspace.Status) async throws -> Void
    public var setWorkspaceUnread: @Sendable (_ workspaceID: String, _ unread: Bool) async throws -> Void
    public var stopSession: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> Void
}

public enum DesktopClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The desktop service returned an invalid response."

        case let .requestFailed(statusCode, message):
            if message.isEmpty {
                "The desktop service returned HTTP \(statusCode)."
            } else {
                "The desktop service returned HTTP \(statusCode): \(message)"
            }
        }
    }
}

extension DesktopClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            fetchMessages: { workspaceID, sessionID in
                try await fetch(
                    [Message].self,
                    // GET /workspaces/{workspaceID}/sessions/{sessionID}/messages
                    from: messagesURL(workspaceID: workspaceID, sessionID: sessionID)
                )
            },
            fetchRepositories: {
                try await fetch(
                    [Repository].self,
                    from: baseURL.appending(path: "repositories")
                )
            },
            fetchSessions: { workspaceID in
                try await fetch(
                    [Session].self,
                    // GET /workspaces/{workspaceID}/sessions
                    from: baseURL
                        .appending(path: "workspaces")
                        .appending(path: workspaceID)
                        .appending(path: "sessions")
                )
            },
            fetchWorkspaces: {
                try await fetch(
                    [WorkspaceSnapshot].self,
                    from: baseURL.appending(path: "workspaces")
                )
            },
            sendMessage: { workspaceID, sessionID, message in
                try await post(
                    ["message": message],
                    to: messagesURL(workspaceID: workspaceID, sessionID: sessionID)
                )
            },
            setWorkspacePinned: { workspaceID, pinned in
                try await patch(
                    WorkspacePatchBody(pinned: pinned),
                    at: workspaceURL(workspaceID: workspaceID)
                )
            },
            setWorkspaceStatus: { workspaceID, status in
                try await patch(
                    WorkspacePatchBody(status: status.rawValue),
                    at: workspaceURL(workspaceID: workspaceID)
                )
            },
            setWorkspaceUnread: { workspaceID, unread in
                try await patch(
                    WorkspacePatchBody(unread: unread),
                    at: workspaceURL(workspaceID: workspaceID)
                )
            },
            stopSession: { workspaceID, sessionID in
                try await post(
                    [String: String](),
                    // POST /workspaces/{workspaceID}/sessions/{sessionID}/stop
                    to: sessionURL(workspaceID: workspaceID, sessionID: sessionID)
                        .appending(path: "stop")
                )
            }
        )
    }

    private static let baseURL = URL(string: "http://192.168.0.32:3768")!

    // POST /workspaces/{workspaceID}/sessions/{sessionID}/messages
    private static func messagesURL(workspaceID: String, sessionID: String) -> URL {
        sessionURL(workspaceID: workspaceID, sessionID: sessionID)
            .appending(path: "messages")
    }

    // POST /workspaces/{workspaceID}/sessions/{sessionID}
    private static func sessionURL(workspaceID: String, sessionID: String) -> URL {
        baseURL
            .appending(path: "workspaces")
            .appending(path: workspaceID)
            .appending(path: "sessions")
            .appending(path: sessionID)
    }

    private static func workspaceURL(workspaceID: String) -> URL {
        baseURL
            .appending(path: "workspaces")
            .appending(path: workspaceID)
    }

    private static func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(from: url)

        try validateSuccessfulHTTPResponse(response, data: data)

        return try JSONDecoder.conductor.decode(type, from: data)
    }

    private static func post<Body: Encodable>(_ body: Body, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }

    // URLSession only throws for transport failures, so validate HTTP status codes separately.
    private static func validateSuccessfulHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws {
        guard let response = response as? HTTPURLResponse else {
            throw DesktopClientError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateSuccessfulHTTPResponse(response, data: data)
    }
}

private struct WorkspacePatchBody: Encodable, Sendable {
    var pinned: Bool? = nil
    var status: String? = nil
    var unread: Bool? = nil
}

public extension DesktopClient {
    // GET /repositories/{repositoryID}/icon
    static func repositoryIconURL(for repository: Repository) -> URL {
        URL(string: "\(baseURL)/repositories/\(repository.id)/icon")!
    }
}

public extension DependencyValues {
    var desktopClient: DesktopClient {
        get { self[DesktopClient.self] }
        set { self[DesktopClient.self] = newValue }
    }
}
