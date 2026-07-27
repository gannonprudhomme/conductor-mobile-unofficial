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
    public var cancelSession: @Sendable (_ sessionID: String) async throws -> CloudCancelResponse
    public var createSession: @Sendable (
        _ request: CloudCreateSessionRequest
    ) async throws -> CloudSession
    public var createWorkspace: @Sendable (
        _ request: CloudCreateWorkspaceRequest
    ) async throws -> CloudCreateWorkspaceResponse
    public var messages: @Sendable (
        _ sessionID: String,
        _ limit: Int,
        _ offset: Int?,
        _ after: String?
    ) async throws -> CloudPage<CloudTranscriptMessage>
    public var projects: @Sendable (
        _ limit: Int,
        _ offset: Int
    ) async throws -> CloudPage<CloudProject>
    public var sendMessage: @Sendable (
        _ sessionID: String,
        _ messageID: String,
        _ message: String
    ) async throws -> CloudSendMessageResponse
    public var sessionStatus: @Sendable (
        _ sessionID: String
    ) async throws -> CloudSessionStatusResponse
    public var sessions: @Sendable (
        _ workspaceID: String,
        _ limit: Int,
        _ offset: Int
    ) async throws -> CloudPage<CloudSession>
    public var testConnection: @Sendable (_ apiKey: String) async throws -> CloudIdentity
    public var workspaceStatus: @Sendable (
        _ workspaceID: String
    ) async throws -> CloudWorkspaceStatusResponse
    public var workspace: @Sendable (_ workspaceID: String) async throws -> CloudWorkspace
    public var workspaces: @Sendable (
        _ projectID: String,
        _ limit: Int,
        _ offset: Int
    ) async throws -> CloudPage<CloudWorkspace>
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
            return false
        }
        return statusCode == 401
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
        Self { sessionID in
            try await request(
                CloudCancelResponse.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "cancel"],
                method: "POST",
                apiKey: try await apiKey()
            )
        } createSession: { createRequest in
            try await request(
                CloudSession.self,
                baseURL: baseURL,
                path: ["v0", "sessions"],
                method: "POST",
                body: createRequest,
                apiKey: try await apiKey()
            )
        } createWorkspace: { createRequest in
            try await request(
                CloudCreateWorkspaceResponse.self,
                baseURL: baseURL,
                path: ["v0", "workspaces"],
                method: "POST",
                body: createRequest,
                apiKey: try await apiKey()
            )
        } messages: { sessionID, limit, offset, after in
            var queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            if let after {
                queryItems.append(URLQueryItem(name: "after", value: after))
            } else if let offset {
                queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
            }
            return try await request(
                CloudPage<CloudTranscriptMessage>.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "messages"],
                queryItems: queryItems,
                apiKey: try await apiKey()
            )
        } projects: { limit, offset in
            try await request(
                CloudPage<CloudProject>.self,
                baseURL: baseURL,
                path: ["v0", "projects"],
                queryItems: [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ],
                apiKey: try await apiKey()
            )
        } sendMessage: { sessionID, messageID, message in
            try await request(
                CloudSendMessageResponse.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "messages"],
                method: "POST",
                body: SendMessageBody(messageID: messageID, message: message),
                apiKey: try await apiKey()
            )
        } sessionStatus: { sessionID in
            try await request(
                CloudSessionStatusResponse.self,
                baseURL: baseURL,
                path: ["v0", "sessions", sessionID, "status"],
                apiKey: try await apiKey()
            )
        } sessions: { workspaceID, limit, offset in
            try await request(
                CloudPage<CloudSession>.self,
                baseURL: baseURL,
                path: ["v0", "workspaces", workspaceID, "sessions"],
                queryItems: [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ],
                apiKey: try await apiKey()
            )
        } testConnection: { candidateAPIKey in
            try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: candidateAPIKey
            )
        } workspaceStatus: { workspaceID in
            try await request(
                CloudWorkspaceStatusResponse.self,
                baseURL: baseURL,
                path: ["v0", "workspaces", workspaceID, "status"],
                apiKey: try await apiKey()
            )
        } workspace: { workspaceID in
            try await request(
                CloudWorkspace.self,
                baseURL: baseURL,
                path: ["v0", "workspaces", workspaceID],
                apiKey: try await apiKey()
            )
        } workspaces: { projectID, limit, offset in
            try await request(
                CloudPage<CloudWorkspace>.self,
                baseURL: baseURL,
                path: ["v0", "projects", projectID, "workspaces"],
                queryItems: [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                ],
                apiKey: try await apiKey()
            )
        }
    }

    private static func request<Response: Decodable>(
        _ responseType: Response.Type,
        baseURL: URL,
        path: [String],
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        apiKey: String
    ) async throws -> Response {
        try await request(
            responseType,
            baseURL: baseURL,
            path: path,
            method: method,
            queryItems: queryItems,
            body: Optional<EmptyBody>.none,
            apiKey: apiKey
        )
    }

    private static func request<Response: Decodable, Body: Encodable>(
        _ responseType: Response.Type,
        baseURL: URL,
        path: [String],
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Body?,
        apiKey: String
    ) async throws -> Response {
        @Dependency(\.urlSession) var urlSession

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
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CloudAPIClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CloudAPIClientError.requestFailed(
                statusCode: response.statusCode,
                error: try? JSONDecoder().decode(CloudStructuredError.self, from: data)
            )
        }
        return try JSONDecoder.cloud.decode(responseType, from: data)
    }

    private struct EmptyBody: Encodable { }

    private struct SendMessageBody: Encodable {
        let messageID: String
        let message: String

        private enum CodingKeys: String, CodingKey {
            case messageID = "messageId"
            case message
        }
    }
}

public extension CloudAPIClient {
    func allProjects(pageSize: Int = 100) async throws -> [CloudProject] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await projects(limit: limit, offset: offset)
        }
    }

    func allWorkspaces(
        projectID: String,
        pageSize: Int = 100
    ) async throws -> [CloudWorkspace] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await workspaces(projectID: projectID, limit: limit, offset: offset)
        }
    }

    func allSessions(
        workspaceID: String,
        pageSize: Int = 100
    ) async throws -> [CloudSession] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await sessions(workspaceID: workspaceID, limit: limit, offset: offset)
        }
    }

    func allMessages(
        sessionID: String,
        pageSize: Int = 100
    ) async throws -> [CloudTranscriptMessage] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await messages(
                sessionID: sessionID,
                limit: limit,
                offset: offset,
                after: nil
            )
        }
    }

    func messagesAfter(
        sessionID: String,
        messageID: String,
        pageSize: Int = 100
    ) async throws -> [CloudTranscriptMessage] {
        var cursor = messageID
        var results: [CloudTranscriptMessage] = []

        while true {
            try Task.checkCancellation()
            let page = try await messages(
                sessionID: sessionID,
                limit: pageSize,
                offset: nil,
                after: cursor
            )
            results.append(contentsOf: page.data)
            guard page.hasMore else {
                return results
            }
            guard let lastMessageID = page.data.last?.id else {
                throw CloudAPIClientError.invalidResponse
            }
            cursor = lastMessageID
        }
    }

    private func allPages<Element: Decodable & Equatable & Sendable>(
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
            offset = Int(response.offset) + response.data.count
        }
    }
}

public extension DependencyValues {
    var cloudAPIClient: CloudAPIClient {
        get { self[CloudAPIClient.self] }
        set { self[CloudAPIClient.self] = newValue }
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
