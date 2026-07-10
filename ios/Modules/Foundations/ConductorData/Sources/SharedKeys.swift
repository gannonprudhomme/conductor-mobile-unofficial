import Foundation
import Sharing

public extension SharedKey where Self == FileStorageKey<String?>.Default {
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

public extension SharedKey where Self == FileStorageKey<WorkspaceWithRepository.Sort>.Default {
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
