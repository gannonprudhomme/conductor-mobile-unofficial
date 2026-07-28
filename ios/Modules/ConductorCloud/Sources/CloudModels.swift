//
//  CloudModels.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation

/// Pagination envelope returned by the Cloud API's offset-based list routes.
struct CloudPage<Element: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    let data: [Element]
    let offset: Int
    let hasMore: Bool

    init(data: [Element], offset: Int, hasMore: Bool) {
        self.data = data
        self.offset = offset
        self.hasMore = hasMore
    }
}

/// Response from `GET /me`.
public struct CloudIdentity: Decodable, Equatable, Sendable {
    public let userID: String
    public let email: String?
    public let organizationID: String?
    public let workspaceID: String?
    public let authMethod: AuthMethod
    public let apiKey: APIKey?

    public init(
        userID: String,
        email: String? = nil,
        organizationID: String? = nil,
        workspaceID: String? = nil,
        authMethod: AuthMethod,
        apiKey: APIKey? = nil
    ) {
        self.userID = userID
        self.email = email
        self.organizationID = organizationID
        self.workspaceID = workspaceID
        self.authMethod = authMethod
        self.apiKey = apiKey
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case email
        case organizationID = "organizationId"
        case workspaceID = "workspaceId"
        case authMethod
        case apiKey
    }

    public var cacheID: String {
        [userID, organizationID ?? "", workspaceID ?? ""].joined(separator: ":")
    }

    public struct APIKey: Decodable, Equatable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    public struct AuthMethod: Codable, Hashable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let apiKey = Self(rawValue: "api-key")
    }
}

/// Project item from `GET /v0/projects`.
public struct CloudProject: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let gitRemote: String

    public init(id: String, name: String, gitRemote: String) {
        self.id = id
        self.name = name
        self.gitRemote = gitRemote
    }
}

/// Client-side association between two independent Cloud API resources.
public struct CloudProjectWorkspace: Equatable, Identifiable, Sendable {
    public var id: String { workspace.id }
    public let project: CloudProject
    public let workspace: CloudWorkspace

    public init(project: CloudProject, workspace: CloudWorkspace) {
        self.project = project
        self.workspace = workspace
    }
}

/// Client-constructed snapshot combining paginated projects, workspaces, and statuses.
public struct CloudWorkspaceSnapshot: Equatable, Sendable {
    public let accountID: String
    public let projects: [CloudProject]
    public let statuses: [CloudWorkspace.ID: CloudWorkspaceStatusResponse]
    public let workspaces: [CloudProjectWorkspace]

    public init(
        accountID: String,
        projects: [CloudProject],
        statuses: [CloudWorkspace.ID: CloudWorkspaceStatusResponse],
        workspaces: [CloudProjectWorkspace]
    ) {
        self.accountID = accountID
        self.projects = projects
        self.statuses = statuses
        self.workspaces = workspaces
    }
}

/// Workspace item from `GET /v0/projects/{projectID}/workspaces`.
public struct CloudWorkspace: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let creatorID: String?
    public let lastActivityAt: Date?

    public init(
        id: String,
        name: String,
        createdAt: Date,
        creatorID: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.creatorID = creatorID
        self.lastActivityAt = lastActivityAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case creatorID = "creatorId"
        case lastActivityAt
    }
}

/// Session item from `GET /v0/workspaces/{workspaceID}/sessions`.
public struct CloudSession: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let deepLink: URL
    public let name: String?
    public let model: String?
    public let resolvedModel: String?
    public let effort: String?
    public let fastMode: Bool?
    public let archivedAt: Date?

    public init(
        id: String,
        deepLink: URL,
        name: String? = nil,
        model: String? = nil,
        resolvedModel: String? = nil,
        effort: String? = nil,
        fastMode: Bool? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.deepLink = deepLink
        self.name = name
        self.model = model
        self.resolvedModel = resolvedModel
        self.effort = effort
        self.fastMode = fastMode
        self.archivedAt = archivedAt
    }
}

/// Response from `GET /v0/sessions/{sessionID}/status`.
public struct CloudSessionStatusResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let status: Status
    public let updatedAt: Date
    public let errorMessage: String?
    public let lastError: String?
    public let lastErrorAt: Date?

    public init(
        workspaceID: String,
        sessionID: String,
        status: Status,
        updatedAt: Date,
        errorMessage: String? = nil,
        lastError: String? = nil,
        lastErrorAt: Date? = nil
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.status = status
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case sessionID = "sessionId"
        case status
        case updatedAt
        case errorMessage
        case lastError
        case lastErrorAt
    }

    public struct Status: Codable, Hashable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let idle = Self(rawValue: "idle")
        public static let working = Self(rawValue: "working")
        public static let error = Self(rawValue: "error")
    }
}

/// Transcript item from `GET /v0/sessions/{sessionID}/messages`.
public struct CloudTranscriptMessage: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let sessionIndex: Double
    public let type: MessageType
    public let content: CloudJSONValue
    public let receivedAt: Date

    public init(
        id: String,
        sessionID: String,
        sessionIndex: Double,
        type: MessageType,
        content: CloudJSONValue,
        receivedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionIndex = sessionIndex
        self.type = type
        self.content = content
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case sessionIndex
        case type
        case content
        case receivedAt
    }

    public struct MessageType: Codable, Hashable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public static func normalized(_ messages: [Self]) -> [Self] {
        let newestByID = messages.reduce(into: [String: Self]()) { result, message in
            result[message.id] = message
        }
        return newestByID.values.sorted {
            if $0.sessionIndex != $1.sessionIndex {
                $0.sessionIndex < $1.sessionIndex
            } else if $0.receivedAt != $1.receivedAt {
                $0.receivedAt < $1.receivedAt
            } else {
                $0.id < $1.id
            }
        }
    }
}

/// One canonicalizable session observation result.
public struct CloudSessionSnapshot: Equatable, Sendable {
    public let accountID: String
    public let workspace: CloudWorkspace
    public let sessions: [CloudSession]
    public let statuses: [CloudSession.ID: CloudSessionStatusResponse]

    public init(
        accountID: String,
        workspace: CloudWorkspace,
        sessions: [CloudSession],
        statuses: [CloudSession.ID: CloudSessionStatusResponse]
    ) {
        self.accountID = accountID
        self.workspace = workspace
        self.sessions = sessions
        self.statuses = statuses
    }
}

/// A complete or incremental transcript observation result.
public struct CloudTranscriptSnapshot: Equatable, Sendable {
    public let accountID: String
    public let sessionID: CloudSession.ID
    public let status: CloudSessionStatusResponse
    public let messages: [CloudTranscriptMessage]
    public let isFullSnapshot: Bool

    public init(
        accountID: String,
        sessionID: CloudSession.ID,
        status: CloudSessionStatusResponse,
        messages: [CloudTranscriptMessage],
        isFullSnapshot: Bool
    ) {
        self.accountID = accountID
        self.sessionID = sessionID
        self.status = status
        self.messages = messages
        self.isFullSnapshot = isFullSnapshot
    }
}

/// Response from `GET /v0/workspaces/{workspaceID}/status`.
public struct CloudWorkspaceStatusResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let status: Status

    public init(
        workspaceID: String,
        status: Status
    ) {
        self.workspaceID = workspaceID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case status
    }

    public struct Status: Codable, Hashable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let initializing = Self(rawValue: "initializing")
        public static let ready = Self(rawValue: "ready")
        public static let sleeping = Self(rawValue: "sleeping")
        public static let archived = Self(rawValue: "archived")
        public static let deleted = Self(rawValue: "deleted")
        public static let updating = Self(rawValue: "updating")
    }
}

/// Structured error body returned by Cloud API endpoints.
public struct CloudStructuredError: Decodable, Equatable, Sendable {
    public let code: String?
    public let userMessage: String
    public let debugMessage: String?
    public let retryable: Bool?
    public let source: String?
    public let details: [String: JSONValue]?
    public let underlying: [Self]?

    public init(
        code: String?,
        userMessage: String,
        debugMessage: String?,
        retryable: Bool?,
        source: String?,
        details: [String: JSONValue]?,
        underlying: [Self]?
    ) {
        self.code = code
        self.userMessage = userMessage
        self.debugMessage = debugMessage
        self.retryable = retryable
        self.source = source
        self.details = details
        self.underlying = underlying
    }

    public enum JSONValue: Codable, Hashable, Sendable {
        case null
        case bool(Bool)
        case integer(Int64)
        case number(Double)
        case string(String)
        case array([Self])
        case object([String: Self])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()

            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([Self].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: Self].self) {
                self = .object(value)
            } else {
                throw DecodingError.typeMismatch(
                    Self.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected a JSON value."
                    )
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()

            switch self {
            case .null:
                try container.encodeNil()
            case let .bool(value):
                try container.encode(value)
            case let .integer(value):
                try container.encode(value)
            case let .number(value):
                try container.encode(value)
            case let .string(value):
                try container.encode(value)
            case let .array(value):
                try container.encode(value)
            case let .object(value):
                try container.encode(value)
            }
        }
    }
}

public typealias CloudJSONValue = CloudStructuredError.JSONValue
