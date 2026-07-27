//
//  MessageSyncEvent.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Foundation

public struct MessageSyncEvent: Codable, Equatable, Sendable {
    public let isSnapshot: Bool
    public let messages: [Message]
    public let deletedMessageIDs: [Message.ID]

    public init(
        isSnapshot: Bool,
        messages: [Message],
        deletedMessageIDs: [Message.ID]
    ) {
        self.isSnapshot = isSnapshot
        self.messages = messages
        self.deletedMessageIDs = deletedMessageIDs
    }

    public static func snapshot(_ messages: [Message]) -> Self {
        Self(
            isSnapshot: true,
            messages: messages,
            deletedMessageIDs: []
        )
    }

    public static func changes(
        upserting messages: [Message] = [],
        deleting deletedMessageIDs: [Message.ID] = []
    ) -> Self {
        Self(
            isSnapshot: false,
            messages: messages,
            deletedMessageIDs: deletedMessageIDs
        )
    }

    enum CodingKeys: String, CodingKey {
        case isSnapshot = "is_snapshot"
        case messages
        case deletedMessageIDs = "deleted_message_ids"
    }
}
