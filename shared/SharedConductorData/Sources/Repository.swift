//
//  Repository.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SQLiteData

@Table("repos")
public struct Repository: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    @Column("archive_script")
    public var archiveScript: String?
    @Column("conductor_config")
    public var conductorConfig: String?
    @Column("created_at", as: Date.ConductorDatabaseRepresentation.self)
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
    @Column("updated_at", as: Date.ConductorDatabaseRepresentation.self)
    public var updatedAt: Date

    public init(
        id: String,
        archiveScript: String? = nil,
        conductorConfig: String? = nil,
        createdAt: Date,
        customPromptCodeReview: String? = nil,
        customPromptCreatePR: String? = nil,
        customPromptFixErrors: String? = nil,
        customPromptGeneral: String? = nil,
        customPromptRenameBranch: String? = nil,
        customPromptResolveMergeConflicts: String? = nil,
        defaultBranch: String? = nil,
        displayOrder: Int? = nil,
        fileIncludeGlobs: String? = nil,
        hidden: Int? = nil,
        icon: String? = nil,
        name: String? = nil,
        remote: String? = nil,
        remoteURL: String? = nil,
        rootPath: String? = nil,
        runScript: String? = nil,
        runScriptMode: String? = nil,
        setupScript: String? = nil,
        spotlightTesting: Int? = nil,
        storageVersion: Int? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.archiveScript = archiveScript
        self.conductorConfig = conductorConfig
        self.createdAt = createdAt
        self.customPromptCodeReview = customPromptCodeReview
        self.customPromptCreatePR = customPromptCreatePR
        self.customPromptFixErrors = customPromptFixErrors
        self.customPromptGeneral = customPromptGeneral
        self.customPromptRenameBranch = customPromptRenameBranch
        self.customPromptResolveMergeConflicts = customPromptResolveMergeConflicts
        self.defaultBranch = defaultBranch
        self.displayOrder = displayOrder
        self.fileIncludeGlobs = fileIncludeGlobs
        self.hidden = hidden
        self.icon = icon
        self.name = name
        self.remote = remote
        self.remoteURL = remoteURL
        self.rootPath = rootPath
        self.runScript = runScript
        self.runScriptMode = runScriptMode
        self.setupScript = setupScript
        self.spotlightTesting = spotlightTesting
        self.storageVersion = storageVersion
        self.updatedAt = updatedAt
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
