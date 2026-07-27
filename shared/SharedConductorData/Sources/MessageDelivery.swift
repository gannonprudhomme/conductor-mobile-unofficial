//
//  MessageDelivery.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation

public struct MessageSendRequest: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let isFastModeEnabled: Bool
    public let message: String
    public let model: String

    public init(
        attemptID: UUID,
        isFastModeEnabled: Bool,
        message: String,
        model: String
    ) {
        self.attemptID = attemptID
        self.isFastModeEnabled = isFastModeEnabled
        self.message = message
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case isFastModeEnabled = "fast_mode"
        case message
        case model
    }
}

public struct MessageSendResponse: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let result: MessageDeliveryResult

    public init(attemptID: UUID, result: MessageDeliveryResult) {
        self.attemptID = attemptID
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case result
    }
}

public enum MessageDeliveryResult: Codable, Equatable, Sendable {
    case accepted(messageID: Message.ID)
    case rejected(reason: String)
    case unknown(reason: String)

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case reason
        case type
    }

    private enum ResultType: String, Codable {
        case accepted
        case rejected
        case unknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ResultType.self, forKey: .type) {
        case .accepted:
            let messageID = try container.decode(Message.ID.self, forKey: .messageID)
            guard !messageID.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .messageID,
                    in: container,
                    debugDescription: "The message ID is empty."
                )
            }
            self = .accepted(messageID: messageID)
        case .rejected:
            self = .rejected(reason: try Self.reason(from: container))
        case .unknown:
            self = .unknown(reason: try Self.reason(from: container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let messageID):
            try container.encode(ResultType.accepted, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
        case .rejected(let reason):
            try container.encode(ResultType.rejected, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .unknown(let reason):
            try container.encode(ResultType.unknown, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }

    private static func reason(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let reason = try container.decode(String.self, forKey: .reason)
        guard !reason.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .reason,
                in: container,
                debugDescription: "The delivery reason is empty."
            )
        }
        return reason
    }
}
