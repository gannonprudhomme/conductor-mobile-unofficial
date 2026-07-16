//
//  Workspaces+SharedKeys.swift
//  ConductorWorkspaces
//
//  Created by Gannon Prudomme on 7/10/26.
//

import ConductorMobileData
import Foundation
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

extension SharedKey where Self == FileStorageKey<String?>.Default {
    static var selectedRepositoryIDFilter: Self {
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

extension SharedKey where Self == FileStorageKey<String>.Default {
    static var createWorkspaceMessage: Self {
        Self[
            .fileStorage(
                .applicationSupportDirectory
                    .appending(component: "create-workspace-message.json")
            ),
            default: ""
        ]
    }
}
