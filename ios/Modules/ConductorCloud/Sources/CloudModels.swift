//
//  CloudModels.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation

public struct CloudPage<Element: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    public let data: [Element]
    public let offset: Int
    public let hasMore: Bool

    public init(data: [Element], offset: Int, hasMore: Bool) {
        self.data = data
        self.offset = offset
        self.hasMore = hasMore
    }
}

public struct CloudIdentity: Decodable, Equatable, Sendable {
    public let userID: String
    public let email: String?
    public let organizationID: String?
    public let workspaceID: String?
    public let authMethod: CloudAuthMethod
    public let apiKey: CloudAPIKeyIdentity?

    public init(
        userID: String,
        email: String? = nil,
        organizationID: String? = nil,
        workspaceID: String? = nil,
        authMethod: CloudAuthMethod,
        apiKey: CloudAPIKeyIdentity? = nil
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
}

public struct CloudAPIKeyIdentity: Decodable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct CloudAuthMethod: Codable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let apiKey = Self(rawValue: "api-key")
}

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

public struct CloudProjectWorkspace: Equatable, Identifiable, Sendable {
    public var id: String { workspace.id }
    public let project: CloudProject
    public let workspace: CloudWorkspace

    public init(project: CloudProject, workspace: CloudWorkspace) {
        self.project = project
        self.workspace = workspace
    }
}

public struct CloudWorkspace: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let deepLink: URL
    public let creatorID: String?
    public let lastActivityAt: Date?

    public init(
        id: String,
        name: String,
        createdAt: Date,
        deepLink: URL,
        creatorID: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.deepLink = deepLink
        self.creatorID = creatorID
        self.lastActivityAt = lastActivityAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case deepLink
        case creatorID = "creatorId"
        case lastActivityAt
    }
}

public struct CloudWorkspaceStatusResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let status: CloudWorkspaceStatus
    public let lifecycleStep: CloudLifecycleStep?
    public let updatedAt: Date
    public let errorMessage: String?

    public init(
        workspaceID: String,
        status: CloudWorkspaceStatus,
        lifecycleStep: CloudLifecycleStep? = nil,
        updatedAt: Date,
        errorMessage: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.status = status
        self.lifecycleStep = lifecycleStep
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case status
        case lifecycleStep
        case updatedAt
        case errorMessage
    }
}

public struct CloudWorkspaceStatus: Codable, Hashable, RawRepresentable, Sendable {
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

public struct CloudLifecycleStep: Codable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let buildingSnapshot = Self(rawValue: "building_snapshot")
    public static let preparing = Self(rawValue: "preparing")
    public static let settingUp = Self(rawValue: "setting_up")
    public static let updating = Self(rawValue: "updating")
}

public struct CloudStructuredError: Decodable, Equatable, Sendable {
    public let code: String?
    public let userMessage: String
    public let debugMessage: String?
    public let retryable: Bool?
    public let source: String?
    public let details: [String: CloudJSONValue]?
    public let underlying: [Self]?

    public init(
        code: String?,
        userMessage: String,
        debugMessage: String?,
        retryable: Bool?,
        source: String?,
        details: [String: CloudJSONValue]?,
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
}

public enum CloudJSONValue: Codable, Hashable, Sendable {
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
