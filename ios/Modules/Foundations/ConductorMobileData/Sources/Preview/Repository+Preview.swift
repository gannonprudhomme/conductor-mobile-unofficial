//
//  Repository+Preview.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation

extension Repository {
    public static func preview(
        id: String = "repository-1",
        archiveScript: String? = nil,
        conductorConfig: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_783_555_200),
        customPromptCodeReview: String? = nil,
        customPromptCreatePR: String? = nil,
        customPromptFixErrors: String? = nil,
        customPromptGeneral: String? = nil,
        customPromptRenameBranch: String? = nil,
        customPromptResolveMergeConflicts: String? = nil,
        defaultBranch: String? = "main",
        displayOrder: Int? = 0,
        fileIncludeGlobs: String? = nil,
        hidden: Int? = 0,
        icon: String? = nil,
        name: String? = "conductor-mobile",
        remote: String? = nil,
        remoteURL: String? = nil,
        rootPath: String? = nil,
        runScript: String? = nil,
        runScriptMode: String? = nil,
        setupScript: String? = nil,
        spotlightTesting: Int? = 0,
        storageVersion: Int? = 1,
        updatedAt: Date = Date(timeIntervalSince1970: 1_783_555_200)
    ) -> Self {
        Self(
            id: id,
            archiveScript: archiveScript,
            conductorConfig: conductorConfig,
            createdAt: createdAt,
            customPromptCodeReview: customPromptCodeReview,
            customPromptCreatePR: customPromptCreatePR,
            customPromptFixErrors: customPromptFixErrors,
            customPromptGeneral: customPromptGeneral,
            customPromptRenameBranch: customPromptRenameBranch,
            customPromptResolveMergeConflicts: customPromptResolveMergeConflicts,
            defaultBranch: defaultBranch,
            displayOrder: displayOrder,
            fileIncludeGlobs: fileIncludeGlobs,
            hidden: hidden,
            icon: icon,
            name: name,
            remote: remote,
            remoteURL: remoteURL,
            rootPath: rootPath,
            runScript: runScript,
            runScriptMode: runScriptMode,
            setupScript: setupScript,
            spotlightTesting: spotlightTesting,
            storageVersion: storageVersion,
            updatedAt: updatedAt
        )
    }
}
