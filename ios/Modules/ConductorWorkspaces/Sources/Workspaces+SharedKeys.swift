//
//  Workspaces+SharedKeys.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorMobileData
import Foundation
import SharedConductorData
import Sharing
import SwiftUI

extension WorkspaceWithRepository.Grouping {
    var title: LocalizedStringKey {
        switch self {
        case .status: "Status"
        case .project: "Project"
        }
    }
}

extension WorkspaceWithRepository.Sort {
    var title: LocalizedStringKey {
        switch self {
        case .updated: "Updated"
        case .created: "Created"
        }
    }
}

extension SharedKey where Self == FileStorageKey<WorkspaceWithRepository.Grouping>.Default {
    static var workspaceGrouping: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "workspace-grouping.json")
            ),
            default: .status,
        ]
    }
}

extension SharedKey where Self == FileStorageKey<Set<String>>.Default {
    static var collapsedWorkspaceSectionIDs: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "collapsed-workspace-section-ids.json")
            ),
            default: [],
        ]
    }
}

extension SharedKey where Self == FileStorageKey<String>.Default {
    static var createWorkspacePrompt: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "create-workspace-prompt.json")
            ),
            default: "",
        ]
    }
}

extension SharedKey where Self == FileStorageKey<CreateWorkspace.Mode?>.Default {
    /// The workspace location the user last created from, so the picker reopens where they left off.
    static var createWorkspaceMode: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "create-workspace-mode.json")
            ),
            default: nil,
        ]
    }
}

extension SharedKey where Self == FileStorageKey<Session.Model?>.Default {
    /// The model the user last selected while creating a workspace.
    static var createWorkspaceModel: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "create-workspace-model.json")
            ),
            default: nil,
        ]
    }
}

extension SharedKey where Self == FileStorageKey<String?>.Default {
    /// The repository the user last created a workspace for, across both locations.
    static var createWorkspaceRepositoryID: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "create-workspace-repository-id.json")
            ),
            default: nil,
        ]
    }

    static var selectedRepositoryID: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "selected-repository-id.json")
            ),
            default: nil,
        ]
    }
}

extension SharedKey where Self == FileStorageKey<WorkspaceWithRepository.Sort>.Default {
    static var workspaceSort: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "workspace-sort.json")
            ),
            default: .updated,
        ]
    }
}
