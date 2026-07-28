//
//  CloudSessionMetadata.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import SharedConductorData
import SQLiteData

@Table("cloud_session_metadata")
public struct CloudSessionMetadata: Equatable, Identifiable, Sendable {
    @Column("canonical_session_id", primaryKey: true)
    public let canonicalSessionID: Session.ID
    @Column("cloud_session_id")
    public var cloudSessionID: String
    @Column("workspace_id")
    public var workspaceID: Workspace.ID
    @Column("account_id")
    public var accountID: String
    @Column("list_order")
    public var listOrder: Int
    @Column("refresh_generation")
    public var refreshGeneration: String
    @Column("transcript_cursor")
    public var transcriptCursor: String?
    @Column("has_complete_transcript")
    public var hasCompleteTranscript: Bool
    @Column("transcript_projection_version")
    public var transcriptProjectionVersion: Int

    public init(
        canonicalSessionID: Session.ID,
        cloudSessionID: String,
        workspaceID: Workspace.ID,
        accountID: String,
        listOrder: Int,
        refreshGeneration: String,
        transcriptCursor: String? = nil,
        hasCompleteTranscript: Bool = false,
        transcriptProjectionVersion: Int = 0
    ) {
        self.canonicalSessionID = canonicalSessionID
        self.cloudSessionID = cloudSessionID
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.listOrder = listOrder
        self.refreshGeneration = refreshGeneration
        self.transcriptCursor = transcriptCursor
        self.hasCompleteTranscript = hasCompleteTranscript
        self.transcriptProjectionVersion = transcriptProjectionVersion
    }

    public var id: Session.ID { canonicalSessionID }
}

public extension CloudSessionMetadata {
    static func sessions(
        workspaceID: Workspace.ID,
        isHidden: Bool
    ) -> some SelectStatement<
        Session,
        Session,
        CloudSessionMetadata
    > {
        Session
            .join(Self.all) { session, metadata in
                session.id.eq(metadata.canonicalSessionID)
            }
            .where { session, metadata in
                metadata.workspaceID.eq(workspaceID)
                    && session.isHidden.eq(isHidden)
            }
            .order { session, metadata in
                (metadata.listOrder, session.id)
            }
            .select { session, _ in session }
    }
}
