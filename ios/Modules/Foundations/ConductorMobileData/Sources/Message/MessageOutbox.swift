//
//  MessageOutbox.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/19/26.
//

import Foundation
import SharedConductorData
import Sharing

public struct MessageOutbox: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var workspaces: [Workspace.ID: [Session.ID: [Bubble]]]

    public init(
        workspaces: [Workspace.ID: [Session.ID: [Bubble]]] = [:]
    ) {
        self.workspaces = workspaces
    }

    public subscript(workspaceID: Workspace.ID, sessionID: Session.ID) -> [Bubble] {
        get { workspaces[workspaceID]?[sessionID] ?? [] }
        set {
            workspaces[workspaceID, default: [:]][sessionID] = newValue.isEmpty
                ? nil
                : newValue
            if workspaces[workspaceID]?.isEmpty == true {
                workspaces[workspaceID] = nil
            }
        }
    }

    public struct Bubble: Codable, Equatable, Identifiable, Sendable {
        public let bubbleID: UUID
        public let content: String
        public let model: Session.Model
        public var attempts: [Attempt]

        public var id: UUID { bubbleID }

        public init(
            bubbleID: UUID,
            content: String,
            model: Session.Model,
            attempts: [Attempt]
        ) {
            self.bubbleID = bubbleID
            self.content = content
            self.model = model
            self.attempts = attempts
        }
    }

    public struct Attempt: Codable, Equatable, Identifiable, Sendable {
        public let attemptID: UUID
        public var state: State

        public var id: UUID { attemptID }

        public init(attemptID: UUID, state: State) {
            self.attemptID = attemptID
            self.state = state
        }

        public enum State: Codable, Equatable, Sendable {
            case sending
            case accepted(messageID: Message.ID)
            case unknown
            case rejected

            private enum CodingKeys: String, CodingKey {
                case messageID = "messageId"
                case type
            }

            private enum StateType: String, Codable {
                case accepted
                case rejected
                case sending
                case unknown
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(StateType.self, forKey: .type) {
                case .sending:
                    self = .sending
                case .accepted:
                    let messageID = try container.decode(Message.ID.self, forKey: .messageID)
                    guard !messageID.isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .messageID,
                            in: container,
                            debugDescription: "An accepted message ID cannot be empty."
                        )
                    }
                    self = .accepted(messageID: messageID)
                case .unknown:
                    self = .unknown
                case .rejected:
                    self = .rejected
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .sending:
                    try container.encode(StateType.sending, forKey: .type)
                case .accepted(let messageID):
                    try container.encode(StateType.accepted, forKey: .type)
                    try container.encode(messageID, forKey: .messageID)
                case .unknown:
                    try container.encode(StateType.unknown, forKey: .type)
                case .rejected:
                    try container.encode(StateType.rejected, forKey: .type)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case workspaces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported message outbox version: \(version)."
            )
        }

        let workspaces = try container.decode(
            [Workspace.ID: [Session.ID: [Bubble]]].self,
            forKey: .workspaces
        )
        try Self.validate(workspaces: workspaces)
        self.workspaces = workspaces
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(workspaces, forKey: .workspaces)
    }

    private static func validate(
        workspaces: [Workspace.ID: [Session.ID: [Bubble]]]
    ) throws {
        var bubbleIDs: Set<UUID> = []
        var attemptIDs: Set<UUID> = []
        for sessions in workspaces.values {
            for bubbles in sessions.values {
                for bubble in bubbles {
                    guard !bubble.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    !bubble.model.rawValue.isEmpty,
                    !bubble.attempts.isEmpty,
                    bubbleIDs.insert(bubble.bubbleID).inserted,
                    bubble.attempts.allSatisfy({ attemptIDs.insert($0.attemptID).inserted }) else {
                        throw DecodingError.dataCorrupted(
                            .init(
                                codingPath: [],
                                debugDescription: "The message outbox is invalid."
                            )
                        )
                    }
                }
            }
        }
    }
}

public extension SharedKey where Self == FileStorageKey<MessageOutbox>.Default {
    static var messageOutbox: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "message-outbox.json")
            ),
            default: MessageOutbox(),
        ]
    }
}
