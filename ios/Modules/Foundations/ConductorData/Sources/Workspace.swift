import Foundation
import SQLiteData

@Table("workspaces")
public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("active_session_id")
    public var activeSessionID: String?
    @Column("archive_commit")
    public var archiveCommit: String?
    @Column("assignee_user_id")
    public var assigneeUserID: String?
    @Column("big_terminal_mode")
    public var bigTerminalMode: Int?
    public var branch: String?
    @Column("created_at")
    public var createdAt: String
    @Column("creator_client_id")
    public var creatorClientID: String?
    @Column("creator_user_id")
    public var creatorUserID: String?
    // @Column("DEPRECATED_archived")
    // public var deprecatedArchived: Int?
    // @Column("DEPRECATED_city_name")
    // public var deprecatedCityName: String?
    @Column("derived_status")
    public var derivedStatus: String?
    @Column("directory_name")
    public var directoryName: String?
    @Column("hosting_server_url")
    public var hostingServerURL: String?
    @Column("initialization_files_copied")
    public var initializationFilesCopied: Int?
    @Column("initialization_log_path")
    public var initializationLogPath: String?
    @Column("initialization_parent_branch")
    public var initializationParentBranch: String?
    @Column("intended_target_branch")
    public var intendedTargetBranch: String?
    @Column("linked_directory_paths")
    public var linkedDirectoryPaths: String?
    @Column("linked_workspace_ids")
    public var linkedWorkspaceIDs: String?
    @Column("manual_status")
    public var manualStatus: String?
    public var notes: String?
    @Column("organization_id")
    public var organizationID: String?
    @Column("permission_level")
    public var permissionLevel: String?
    @Column("pinned_at")
    public var pinnedAt: String?
    @Column("placeholder_branch_name")
    public var placeholderBranchName: String?
    @Column("pr_description")
    public var prDescription: String?
    @Column("pr_title")
    public var prTitle: String?
    @Column("remote_file_sync_enabled")
    public var remoteFileSyncEnabled: Int?
    @Column("repository_id")
    public var repositoryID: String?
    @Column("sandbox_provider")
    public var sandboxProvider: String?
    @Column("secondary_directory_name")
    public var secondaryDirectoryName: String?
    @Column("setup_log_path")
    public var setupLogPath: String?
    public var state: State?
    public var unread: Int?
    @Column("updated_at")
    public var updatedAt: String
    @Column("user_set_branch_name")
    public var userSetBranchName: Int?
    @Column("user_set_workspace_name")
    public var userSetWorkspaceName: Int?
    @Column("watcher_user_ids")
    public var watcherUserIDs: String?
    @Column("workspace_name")
    public var workspaceName: String?
    @Column("workspace_path")
    public var workspacePath: String?
}

extension Workspace {
    public struct State: Codable, Hashable, QueryBindable, QueryDecodable, RawRepresentable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let initializing = Self(rawValue: "initializing")
        public static let settingUp = Self(rawValue: "setting_up")
        public static let ready = Self(rawValue: "ready")
        public static let archiving = Self(rawValue: "archiving")
        public static let archived = Self(rawValue: "archived")
    }
}

extension Workspace {
    public var displayBranchName: String {
        let name = [branch, placeholderBranchName, workspaceName, directoryName]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })

        guard let name
        else {
            return "Untitled branch"
        }

        let words = name.split { character in
            ["-", "_"].contains(character) || character.isWhitespace
        }
        let sentence = words.joined(separator: " ").lowercased()

        guard let firstCharacter = sentence.first else {
            return sentence
        }

        return firstCharacter.uppercased() + sentence.dropFirst()
    }
}

extension Workspace {
    enum CodingKeys: String, CodingKey {
        case id
        case activeSessionID = "active_session_id"
        case archiveCommit = "archive_commit"
        case assigneeUserID = "assignee_user_id"
        case bigTerminalMode = "big_terminal_mode"
        case branch
        case createdAt = "created_at"
        case creatorClientID = "creator_client_id"
        case creatorUserID = "creator_user_id"
        // case deprecatedArchived = "DEPRECATED_archived"
        // case deprecatedCityName = "DEPRECATED_city_name"
        case derivedStatus = "derived_status"
        case directoryName = "directory_name"
        case hostingServerURL = "hosting_server_url"
        case initializationFilesCopied = "initialization_files_copied"
        case initializationLogPath = "initialization_log_path"
        case initializationParentBranch = "initialization_parent_branch"
        case intendedTargetBranch = "intended_target_branch"
        case linkedDirectoryPaths = "linked_directory_paths"
        case linkedWorkspaceIDs = "linked_workspace_ids"
        case manualStatus = "manual_status"
        case notes
        case organizationID = "organization_id"
        case permissionLevel = "permission_level"
        case pinnedAt = "pinned_at"
        case placeholderBranchName = "placeholder_branch_name"
        case prDescription = "pr_description"
        case prTitle = "pr_title"
        case remoteFileSyncEnabled = "remote_file_sync_enabled"
        case repositoryID = "repository_id"
        case sandboxProvider = "sandbox_provider"
        case secondaryDirectoryName = "secondary_directory_name"
        case setupLogPath = "setup_log_path"
        case state
        case unread
        case updatedAt = "updated_at"
        case userSetBranchName = "user_set_branch_name"
        case userSetWorkspaceName = "user_set_workspace_name"
        case watcherUserIDs = "watcher_user_ids"
        case workspaceName = "workspace_name"
        case workspacePath = "workspace_path"
    }
}
