//
//  CloudProjectRepositoryMapping.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SharedConductorData
import SQLiteData

@Table("cloud_project_repository_mappings")
public struct CloudProjectRepositoryMapping: Equatable, Identifiable, Sendable {
    public let id: String
    @Column("account_id")
    public var accountID: String
    @Column("cloud_project_id")
    public var cloudProjectID: String
    @Column("canonical_repository_id")
    public var canonicalRepositoryID: String
    @Column("project_name")
    public var projectName: String
    @Column("git_remote")
    public var gitRemote: String
    @Column("refresh_generation")
    public var refreshGeneration: String

    public init(
        accountID: String,
        cloudProjectID: String,
        canonicalRepositoryID: String,
        projectName: String,
        gitRemote: String,
        refreshGeneration: String
    ) {
        self.id = Self.id(
            accountID: accountID,
            cloudProjectID: cloudProjectID
        )
        self.accountID = accountID
        self.cloudProjectID = cloudProjectID
        self.canonicalRepositoryID = canonicalRepositoryID
        self.projectName = projectName
        self.gitRemote = gitRemote
        self.refreshGeneration = refreshGeneration
    }

    public static func id(
        accountID: String,
        cloudProjectID: String
    ) -> String {
        "\(accountID.count):\(accountID)\(cloudProjectID)"
    }
}

public struct CloudWorkspaceCreationCandidate: Equatable, Identifiable, Sendable {
    public var id: Repository.ID { repository.id }
    public let repository: Repository
    public let projectID: String
    public let repositoryURL: URL?

    public init(
        repository: Repository,
        projectID: String,
        repositoryURL: URL?
    ) {
        self.repository = repository
        self.projectID = projectID
        self.repositoryURL = repositoryURL
    }
}
