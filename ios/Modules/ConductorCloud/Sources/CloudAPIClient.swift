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
    /// `GET /v0/projects?limit={limit}&offset={offset}`
    public var getProjects: @Sendable (
        _ limit: Int,
        _ offset: Int
    ) async throws -> CloudPage<CloudProject>
    /// `GET /me`
    public var getIdentity: @Sendable (_ apiKey: String) async throws -> CloudIdentity
    /// `GET /v0/workspaces/{workspaceID}/status`
    public var getWorkspaceStatus: @Sendable (
        _ workspaceID: String
    ) async throws -> CloudWorkspaceStatusResponse
    /// `GET /v0/projects/{projectID}/workspaces?limit={limit}&offset={offset}`
    public var getWorkspaces: @Sendable (
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
        Self { limit, offset in
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
        } getIdentity: { candidateAPIKey in
            try await request(
                CloudIdentity.self,
                baseURL: baseURL,
                path: ["me"],
                apiKey: candidateAPIKey
            )
        } getWorkspaceStatus: { workspaceID in
            try await request(
                CloudWorkspaceStatusResponse.self,
                baseURL: baseURL,
                path: ["v0", "workspaces", workspaceID, "status"],
                apiKey: try await apiKey()
            )
        } getWorkspaces: { projectID, limit, offset in
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

public extension CloudAPIClient {
    func allProjects(pageSize: Int = 100) async throws -> [CloudProject] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await getProjects(limit: limit, offset: offset)
        }
    }

    func allWorkspaces(
        projectID: String,
        pageSize: Int = 100
    ) async throws -> [CloudWorkspace] {
        try await allPages(pageSize: pageSize) { limit, offset in
            try await getWorkspaces(
                projectID: projectID,
                limit: limit,
                offset: offset
            )
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

            let nextOffset = response.offset + response.data.count
            guard nextOffset > offset else {
                throw CloudAPIClientError.invalidResponse
            }
            offset = nextOffset
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
