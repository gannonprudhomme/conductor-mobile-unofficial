//
//  Queries.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import SQLiteData

extension Message {
    static var excludingToolResults: Where<Message> {
        Message.where { message in
            #sql(
                """
                CASE
                  WHEN json_valid(\(message.content))
                  THEN NOT (
                    json_extract(\(message.content), '$.type') = 'user'
                    AND json_extract(
                      \(message.content),
                      '$.message.content[0].type'
                    ) = 'tool_result'
                  )
                  ELSE 1
                END
                """
            )
        }
    }

    static func all(
        forWorkspaceID workspaceID: String,
        sessionID: String
    ) -> some SelectStatement<Message, Message, Session> {
        excludingToolResults
            .where { $0.sessionID.eq(sessionID) }
            .order(by: \.createdAt)
            .join(Session.all) { message, session in
                message.sessionID.eq(session.id)
            }
            .where { _, session in
                session.workspaceID.eq(workspaceID)
            }
            .select { message, _ in message }
    }
}

extension Repository {
    static var orderedByDisplayOrder: some SelectStatement<(), Repository, ()> {
        Repository.order(by: \.displayOrder)
    }
}

extension Session {
    static func all(
        forWorkspaceID workspaceID: String
    ) -> some SelectStatement<(), Session, ()> {
        Session
            .where { $0.workspaceID.eq(workspaceID) }
            .order { $0.updatedAt.desc() }
    }
}
