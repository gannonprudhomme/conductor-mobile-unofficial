//
//  MessageSyncEvent.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/27/26.
//

import Foundation

/// One server-to-mobile transcript synchronization envelope.
///
/// Completed history and the mutable queue deliberately have different semantics: history can be
/// replaced or incrementally changed, while every non-`nil` queue is a complete replacement.
/// `DesktopTranscriptStore` validates these partitions before persisting an event.
public struct MessageSyncEvent: Codable, Equatable, Sendable {
    /// Whether `messages` completely replaces completed history rather than upserting into it.
    ///
    /// This flag does not describe `queuedMessages`, which is authoritative whenever present.
    public let isSnapshot: Bool

    /// Completed-history rows to replace or upsert.
    public let messages: [Message]

    /// Completed-history row identifiers to delete.
    public let deletedMessageIDs: [Message.ID]

    /// The opaque ID at the tail of completed history after applying this event.
    ///
    /// The tail is determined by `sentAt`, then `createdAt` and raw UTF-8 ID bytes. A reconnect
    /// sends this value as `after`; it is not a count, digest, or timestamp. It is `nil` when
    /// history is empty.
    public let cursor: Message.ID?

    /// The complete current queue, or `nil` when queue state is unchanged.
    ///
    /// An empty array explicitly clears the queue. For compatibility only, a legacy complete
    /// snapshot with this field absent may still embed queued rows in `messages`; the mobile store
    /// separates those rows before validation.
    public let queuedMessages: [Message]?

    /// Creates an envelope with explicit completed-history and queue semantics.
    ///
    /// Prefer `snapshot` and `changes` at call sites because they communicate whether `messages`
    /// replaces or updates history.
    public init(
        isSnapshot: Bool,
        messages: [Message],
        deletedMessageIDs: [Message.ID],
        cursor: Message.ID? = nil,
        queuedMessages: [Message]? = nil
    ) {
        self.isSnapshot = isSnapshot
        self.messages = messages
        self.deletedMessageIDs = deletedMessageIDs
        self.cursor = cursor
        self.queuedMessages = queuedMessages
    }

    /// Creates a complete replacement for completed history.
    ///
    /// Modern initial WebSocket events also provide the complete queue. The optional default is
    /// retained so old full-snapshot mocks and envelopes can be interpreted by the mobile store.
    public static func snapshot(
        _ messages: [Message],
        cursor: Message.ID? = nil,
        queuedMessages: [Message]? = nil
    ) -> Self {
        Self(
            isSnapshot: true,
            messages: messages,
            deletedMessageIDs: [],
            cursor: cursor,
            queuedMessages: queuedMessages
        )
    }

    /// Creates an incremental completed-history update and optional complete queue replacement.
    ///
    /// `queuedMessages == nil` leaves the cached queue unchanged. The cursor default exists for
    /// queue-only or empty-history events; events with completed history must identify its tail.
    public static func changes(
        upserting messages: [Message] = [],
        deleting deletedMessageIDs: [Message.ID] = [],
        cursor: Message.ID? = nil,
        queuedMessages: [Message]? = nil
    ) -> Self {
        Self(
            isSnapshot: false,
            messages: messages,
            deletedMessageIDs: deletedMessageIDs,
            cursor: cursor,
            queuedMessages: queuedMessages
        )
    }

    // These keys only bridge Swift names to the snake_case wire contract. Codable synthesis is
    // intentional: absent optional fields decode as nil for legacy envelopes without custom code.
    enum CodingKeys: String, CodingKey {
        case isSnapshot = "is_snapshot"
        case messages
        case deletedMessageIDs = "deleted_message_ids"
        case cursor
        case queuedMessages = "queued_messages"
    }
}
