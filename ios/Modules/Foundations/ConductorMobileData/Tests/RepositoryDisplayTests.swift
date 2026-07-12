//
//  RepositoryDisplayTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
@testable import ConductorMobileData
import Foundation
import Testing

struct RepositoryDisplayTests {
    @Test("Repositories derive GitHub owner avatars from common remote URL formats")
    func githubOwnerAvatarURL() {
        let remoteURLs = [
            "https://github.com/acme/conductor-mobile.git",
            "git@github.com:acme/conductor-mobile.git",
            "ssh://git@github.com/acme/conductor-mobile.git",
            "https://gitlab.com/acme/conductor-mobile.git",
            nil,
        ]

        #expect(
            remoteURLs.map {
                repository(remoteURL: $0).githubOwnerAvatarURL?.absoluteString
            } == [
                "https://github.com/acme.png?size=128",
                "https://github.com/acme.png?size=128",
                "https://github.com/acme.png?size=128",
                nil,
                nil,
            ]
        )
    }

    @Test("Repositories use their name for display and fall back to their ID")
    func repositoryDisplayName() {
        #expect(repository(name: "Conductor").displayName == "Conductor")
        #expect(repository(name: "").displayName == "repository-1")
        #expect(repository().displayName == "repository-1")
    }
}

private func repository(name: String? = nil, remoteURL: String? = nil) -> Repository {
    Repository(
        id: "repository-1",
        createdAt: Date(timeIntervalSince1970: 0),
        name: name,
        remoteURL: remoteURL,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
