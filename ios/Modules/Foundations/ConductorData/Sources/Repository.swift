import ConductorFoundation
import Foundation
import SQLiteData

@Table("repos")
public struct Repository: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("archive_script")
    public var archiveScript: String?
    @Column("conductor_config")
    public var conductorConfig: String?
    @Column("created_at")
    public var createdAt: Date
    @Column("custom_prompt_code_review")
    public var customPromptCodeReview: String?
    @Column("custom_prompt_create_pr")
    public var customPromptCreatePR: String?
    @Column("custom_prompt_fix_errors")
    public var customPromptFixErrors: String?
    @Column("custom_prompt_general")
    public var customPromptGeneral: String?
    @Column("custom_prompt_rename_branch")
    public var customPromptRenameBranch: String?
    @Column("custom_prompt_resolve_merge_conflicts")
    public var customPromptResolveMergeConflicts: String?
    @Column("default_branch")
    public var defaultBranch: String?
    @Column("display_order")
    public var displayOrder: Int?
    @Column("file_include_globs")
    public var fileIncludeGlobs: String?
    public var hidden: Int?
    public var icon: String?
    public var name: String?
    public var remote: String?
    @Column("remote_url")
    public var remoteURL: String?
    @Column("root_path")
    public var rootPath: String?
    @Column("run_script")
    public var runScript: String?
    @Column("run_script_mode")
    public var runScriptMode: String?
    @Column("setup_script")
    public var setupScript: String?
    @Column("spotlight_testing")
    public var spotlightTesting: Int?
    @Column("storage_version")
    public var storageVersion: Int?
    @Column("updated_at")
    public var updatedAt: Date
}

extension Repository {
    public var displayName: String {
        name?.nilIfEmpty ?? id
    }

    public var githubOwnerAvatarURL: URL? {
        guard let remoteURL else { return nil }

        let owner: String? = if let components = URLComponents(string: remoteURL),
            components.host?.lowercased() == "github.com" {
            // URL-shaped remotes, including HTTPS and `ssh://`, expose their host and path.
            components.path.split(separator: "/").first.map(String.init)
        } else if remoteURL.lowercased().hasPrefix("git@github.com:") {
            // Git's SCP-like SSH syntax does not expose `github.com` as a URL host.
            remoteURL
                .dropFirst("git@github.com:".count)
                .split(separator: "/")
                .first
                .map(String.init)
        } else {
            nil
        }

        guard let owner, !owner.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner).png"
        components.queryItems = [URLQueryItem(name: "size", value: "128")]
        return components.url
    }
}

extension Repository {
    enum CodingKeys: String, CodingKey {
        case id
        case archiveScript = "archive_script"
        case conductorConfig = "conductor_config"
        case createdAt = "created_at"
        case customPromptCodeReview = "custom_prompt_code_review"
        case customPromptCreatePR = "custom_prompt_create_pr"
        case customPromptFixErrors = "custom_prompt_fix_errors"
        case customPromptGeneral = "custom_prompt_general"
        case customPromptRenameBranch = "custom_prompt_rename_branch"
        case customPromptResolveMergeConflicts = "custom_prompt_resolve_merge_conflicts"
        case defaultBranch = "default_branch"
        case displayOrder = "display_order"
        case fileIncludeGlobs = "file_include_globs"
        case hidden
        case icon
        case name
        case remote
        case remoteURL = "remote_url"
        case rootPath = "root_path"
        case runScript = "run_script"
        case runScriptMode = "run_script_mode"
        case setupScript = "setup_script"
        case spotlightTesting = "spotlight_testing"
        case storageVersion = "storage_version"
        case updatedAt = "updated_at"
    }
}
