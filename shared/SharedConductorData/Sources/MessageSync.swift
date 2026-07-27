//
//  MessageSync.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation

public struct MessageSyncRequest: Codable, Equatable, Sendable {
    public var fingerprints: [Message.ID: Data]

    public init(fingerprints: [Message.ID: Data]) {
        self.fingerprints = fingerprints
    }
}

public struct MessageSyncResponse: Codable, Equatable, Sendable {
    public var messages: [Message]
    public var deletedMessageIDs: [Message.ID]

    public init(
        messages: [Message],
        deletedMessageIDs: [Message.ID]
    ) {
        self.messages = messages
        self.deletedMessageIDs = deletedMessageIDs
    }

    public init(from decoder: any Decoder) throws {
        if let messages = try? decoder.singleValueContainer().decode([Message].self) {
            self.init(messages: messages, deletedMessageIDs: [])
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            messages: try container.decode([Message].self, forKey: .messages),
            deletedMessageIDs: try container.decode(
                [Message.ID].self,
                forKey: .deletedMessageIDs
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case deletedMessageIDs
        case messages
    }
}
