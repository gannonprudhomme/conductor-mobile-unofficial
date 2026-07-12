//
//  Queries.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import SQLiteData

extension Message {
    static func all(
        forWorkspaceID workspaceID: String,
        sessionID: String
    ) -> some SelectStatement<Message, Message, Session> {
        Message
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
    static var mostRecentlyUpdated: some SelectStatement<(), Session, ()> {
        Session
            .order { $0.updatedAt.desc() }
            .limit(200)
    }

    static func all(
        forWorkspaceID workspaceID: String
    ) -> some SelectStatement<(), Session, ()> {
        Session
            .where { $0.workspaceID.eq(workspaceID) }
            .order { $0.updatedAt.desc() }
    }
}
