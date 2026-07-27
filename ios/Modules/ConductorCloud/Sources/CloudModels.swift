//
//  CloudModels.swift
//  ConductorCloud
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation

public struct CloudPage<Element: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    public let data: [Element]
    public let offset: Double
    public let hasMore: Bool

    public init(data: [Element], offset: Double, hasMore: Bool) {
        self.data = data
        self.offset = offset
        self.hasMore = hasMore
    }
}

public struct CloudIdentity: Decodable, Equatable, Sendable {
    public let userID: String
    public let authMethod: CloudAuthMethod

    public init(userID: String, authMethod: CloudAuthMethod) {
        self.userID = userID
        self.authMethod = authMethod
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case authMethod
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

public struct CloudCreateWorkspaceRequest: Encodable, Equatable, Sendable {
    public let projectID: String?
    public let repositoryURL: URL?
    public let branch: String?
    public let name: String?
    public let sessionName: String?
    public let agent: String?
    public let model: String?
    public let effort: String?

    public init(
        projectID: String? = nil,
        repositoryURL: URL? = nil,
        branch: String? = nil,
        name: String? = nil,
        sessionName: String? = nil,
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.projectID = projectID
        self.repositoryURL = repositoryURL
        self.branch = branch
        self.name = name
        self.sessionName = sessionName
        self.agent = agent
        self.model = model
        self.effort = effort
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case repositoryURL = "repositoryUrl"
        case branch
        case name
        case sessionName
        case agent
        case model
        case effort
    }
}

public struct CloudCreateSessionRequest: Encodable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String?
    public let name: String?
    public let agent: String
    public let model: String?
    public let effort: String?
    public let fastMode: Bool?

    public init(
        workspaceID: String,
        sessionID: String? = nil,
        name: String? = nil,
        agent: String,
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool? = nil
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.name = name
        self.agent = agent
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case sessionID = "sessionId"
        case name
        case agent
        case model
        case effort
        case fastMode
    }
}

public struct CloudCreateWorkspaceResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let deepLink: URL

    public init(workspaceID: String, sessionID: String, deepLink: URL) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.deepLink = deepLink
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case sessionID = "sessionId"
        case deepLink
    }
}

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

public struct CloudSessionStatusResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let status: CloudSessionStatus
    public let updatedAt: Date
    public let errorMessage: String?
    public let lastError: String?
    public let lastErrorAt: Date?

    public init(
        workspaceID: String,
        sessionID: String,
        status: CloudSessionStatus,
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
}

public struct CloudSessionStatus: Codable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let idle = Self(rawValue: "idle")
    public static let working = Self(rawValue: "working")
    public static let error = Self(rawValue: "error")
}

public struct CloudTranscriptMessage: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let sessionIndex: Double
    public let type: CloudTranscriptMessageType
    public let content: CloudJSONValue
    public let receivedAt: Date

    public init(
        id: String,
        sessionID: String,
        sessionIndex: Double,
        type: CloudTranscriptMessageType,
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

    public static func normalized(_ messages: [Self]) -> [Self] {
        let newestByID = messages.reduce(into: [String: Self]()) { result, message in
            result[message.id] = message
        }
        return newestByID.values.sorted {
            if $0.sessionIndex != $1.sessionIndex {
                return $0.sessionIndex < $1.sessionIndex
            } else if $0.receivedAt != $1.receivedAt {
                return $0.receivedAt < $1.receivedAt
            } else {
                return $0.id < $1.id
            }
        }
    }
}

public struct CloudTranscriptMessageType: Codable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct CloudSendMessageResponse: Decodable, Equatable, Sendable {
    public let messageID: String
    public let state: CloudMessageDeliveryState

    public init(messageID: String, state: CloudMessageDeliveryState) {
        self.messageID = messageID
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case state
    }
}

public struct CloudMessageDeliveryState: Codable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let queued = Self(rawValue: "queued")
    public static let sent = Self(rawValue: "sent")
}

public struct CloudCancelResponse: Decodable, Equatable, Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let status: CloudSessionStatus
    public let canceledQueuedMessages: Double

    public init(
        workspaceID: String,
        sessionID: String,
        status: CloudSessionStatus,
        canceledQueuedMessages: Double
    ) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.status = status
        self.canceledQueuedMessages = canceledQueuedMessages
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case sessionID = "sessionId"
        case status
        case canceledQueuedMessages
    }
}

public struct CloudStructuredError: Decodable, Equatable, Sendable {
    public let code: String?
    public let userMessage: String
    public let debugMessage: String?
    public let retryable: Bool?
    public let source: String?
    public let details: [String: CloudJSONValue]?
    public let underlying: [Self]?
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
