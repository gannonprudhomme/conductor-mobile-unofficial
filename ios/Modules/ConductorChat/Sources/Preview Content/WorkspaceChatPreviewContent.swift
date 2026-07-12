//
//  WorkspaceChatPreviewContent.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/12/26.
//

#if DEBUG
import SharedConductorData
import ConductorMobileData

struct WorkspaceChatPreviewContent: Sendable {
    let messages: [Message]
    let repository: Repository
    let sessions: [Session]
    let workspace: Workspace

    var workspaceWithRepository: WorkspaceWithRepository {
        WorkspaceWithRepository(workspace: workspace, repository: repository)
    }

    init() throws {
        let chat = try ChatPreviewContent()
        let repository = Repository.preview()
        let workingSession = Session.preview(
            id: "preview-working-session",
            workspaceID: chat.session.workspaceID,
            title: "Build and run the iOS app",
            createdAt: "2026-06-25T09:30:30.000Z",
            updatedAt: "2026-06-25T09:31:20.000Z",
            status: .working,
            contextTokenCount: 12680
        )
        let unreadSession = Session.preview(
            id: "preview-unread-session",
            workspaceID: chat.session.workspaceID,
            title: "Review session navigation",
            agentType: .claude,
            updatedAt: "2026-06-25T09:31:00.000Z",
            model: "sonnet",
            unreadCount: 3,
            contextTokenCount: 9340
        )
        let archivedSession = Session.preview(
            id: "preview-archived-session",
            workspaceID: chat.session.workspaceID,
            title: "Archive the old session picker",
            isHidden: true,
            createdAt: "2026-06-25T09:28:00.000Z",
            updatedAt: "2026-06-25T09:29:00.000Z",
            contextTokenCount: 7210
        )
        let workingMessages = try ChatPreviewContent.shortMessages(
            for: workingSession,
            userMessage: "Build the iOS app and run the focused session tests.",
            assistantMessage: "I’m compiling the sessions module now, then I’ll run its tests."
        )
        let unreadMessages = try ChatPreviewContent.shortMessages(
            for: unreadSession,
            userMessage: "Can you review the session navigation changes?",
            assistantMessage: "The workspace now opens directly into chat and keeps session switching local."
        )

        self.messages = chat.messages + workingMessages + unreadMessages
        self.repository = repository
        self.sessions = [
            chat.session,
            workingSession,
            unreadSession,
            archivedSession,
        ]
        self.workspace = .preview(
            id: chat.session.workspaceID,
            activeSessionID: chat.session.id,
            branch: "workspace-chat-session-switcher-v1",
            repositoryID: repository.id
        )
    }
}
#endif
