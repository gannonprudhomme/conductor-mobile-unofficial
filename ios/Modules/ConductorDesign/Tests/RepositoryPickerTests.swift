//
//  RepositoryPickerTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorMobileData
@testable import ConductorDesign
import SharedConductorData
import SwiftUI
import Testing

@MainActor
struct RepositoryPickerTests {
    @Test("Menu equality only tracks repositories and the selected value")
    func equality() {
        let firstRepository = Repository.preview(id: "first")
        let secondRepository = Repository.preview(id: "second")
        var selection = firstRepository.id
        let binding = Binding(
            get: { selection },
            set: { selection = $0 }
        )
        let picker = RepositoryPicker(
            [firstRepository, secondRepository],
            selection: binding
        )

        #expect(
            picker == RepositoryPicker(
                [firstRepository, secondRepository],
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )
            )
        )

        selection = secondRepository.id

        #expect(
            picker != RepositoryPicker(
                [firstRepository, secondRepository],
                selection: binding
            )
        )
        #expect(
            picker != RepositoryPicker(
                [firstRepository],
                selection: .constant(firstRepository.id)
            )
        )

        let optionalPicker = RepositoryPicker(
            [firstRepository, secondRepository],
            selection: Binding<Repository.ID?>.constant(nil)
        )
        #expect(
            optionalPicker == RepositoryPicker(
                [firstRepository, secondRepository],
                selection: Binding<Repository.ID?>.constant(nil)
            )
        )
        #expect(
            optionalPicker != RepositoryPicker(
                [firstRepository, secondRepository],
                selection: Binding<Repository.ID?>.constant(firstRepository.id)
            )
        )
    }
}
