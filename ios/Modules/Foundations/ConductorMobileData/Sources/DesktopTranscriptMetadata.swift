//
//  DesktopTranscriptMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import SharedConductorData
import SQLiteData

/// Marks one session's cached transcript as a complete, resumable baseline.
///
/// The row exists only after a complete snapshot has committed. A nil cursor therefore means a
/// complete empty history, while no row means the cache cannot safely accept an incremental suffix.
/// A non-nil cursor is the final completed row in `(createdAt, raw UTF-8 ID)` order.
@Table("desktop_transcript_metadata")
struct DesktopTranscriptMetadata: Equatable, Identifiable, Sendable {
    @Column("session_id", primaryKey: true)
    let sessionID: Session.ID
    @Column("transcript_cursor")
    var transcriptCursor: Message.ID?

    var id: Session.ID { sessionID }
}
