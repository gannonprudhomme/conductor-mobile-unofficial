//
//  RepositoryPicker.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SharedConductorData
import SwiftUI

public struct RepositoryPicker<Selection: Hashable>: View {
    private let repositories: [Repository]
    @Binding private var selection: Selection
    private let repositoryTag: (Repository) -> Selection
    private let allRepositoriesTag: (() -> Selection)?

    public init(
        _ repositories: [Repository],
        selection: Binding<Repository.ID>
    ) where Selection == Repository.ID {
        self.repositories = repositories
        _selection = selection
        repositoryTag = { $0.id }
        allRepositoriesTag = nil
    }

    public init(
        _ repositories: [Repository],
        selection: Binding<Repository.ID?>
    ) where Selection == Repository.ID? {
        self.repositories = repositories
        _selection = selection
        repositoryTag = { $0.id }
        allRepositoriesTag = { nil }
    }

    public var body: some View {
        Picker("Repository", selection: $selection) {
            if let allRepositoriesTag {
                Text("All Repositories")
                    .tag(allRepositoriesTag())
            }

            ForEach(repositories) { repository in
                Label {
                    Text(verbatim: repository.displayName)
                } icon: {
                    RepositoryIcon(
                        repository: repository,
                        size: 16,
                        relativeTo: .body
                    )
                }
                .tag(repositoryTag(repository))
            }
        }
        .labelsHidden()
        .pickerStyle(.inline)
    }
}
