//
//  RepositoryPicker.swift
//  ConductorDesign
//
//  Created by Gannon Prudomme on 7/16/26.
//

import SharedConductorData
import SwiftUI

public struct RepositoryPicker<Selection: Hashable>: Equatable, View {
    private let repositories: [Repository]
    @Binding private var selection: Selection
    private let selectionValue: Selection
    private let repositoryTag: (Repository) -> Selection
    private let allRepositoriesTag: (() -> Selection)?

    public init(
        _ repositories: [Repository],
        selection: Binding<Repository.ID>
    ) where Selection == Repository.ID {
        self.repositories = repositories
        _selection = selection
        selectionValue = selection.wrappedValue
        repositoryTag = { $0.id }
        allRepositoriesTag = nil
    }

    public init(
        _ repositories: [Repository],
        selection: Binding<Repository.ID?>
    ) where Selection == Repository.ID? {
        self.repositories = repositories
        _selection = selection
        selectionValue = selection.wrappedValue
        repositoryTag = { $0.id }
        allRepositoriesTag = { nil }
    }

    // System menus reset their open scroll position when SwiftUI replaces equal content.
    // Recreated binding and tag closures are not content changes.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repositories == rhs.repositories
            && lhs.selectionValue == rhs.selectionValue
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
