//
//  CloudWorkspaceCreationPayload.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import Foundation
import SharedConductorData

public struct CloudWorkspaceCreationPayload: Codable, Equatable, Sendable {
    public let request: CloudCreateWorkspaceRequest
    public let canonicalRepositoryID: Repository.ID
    public let projectID: String?
    public let repositoryURL: URL?
    public let selectedModel: Session.Model
    public let selectedReasoningEffort: Session.ReasoningEffort?
    public let prompt: String
    public var baselineRemoteWorkspaceIDs: [String]?

    public init(
        request: CloudCreateWorkspaceRequest,
        canonicalRepositoryID: Repository.ID,
        projectID: String?,
        repositoryURL: URL?,
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort?,
        prompt: String,
        baselineRemoteWorkspaceIDs: [String]? = nil
    ) {
        self.request = request
        self.canonicalRepositoryID = canonicalRepositoryID
        self.projectID = projectID
        self.repositoryURL = repositoryURL
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.prompt = prompt
        self.baselineRemoteWorkspaceIDs = baselineRemoteWorkspaceIDs
    }
}
public struct CloudWorkspaceCreationCompletionPayload: Codable, Equatable, Sendable {
    public let canonicalWorkspaceID: Workspace.ID
    public let remoteWorkspaceID: String
    public let canonicalSessionID: Session.ID
    public let remoteSessionID: String
    public let canonicalRepositoryID: Repository.ID
    public let selectedModel: Session.Model
    public let selectedReasoningEffort: Session.ReasoningEffort?
    public let submittedPrompt: String

    public init(
        canonicalWorkspaceID: Workspace.ID,
        remoteWorkspaceID: String,
        canonicalSessionID: Session.ID,
        remoteSessionID: String,
        canonicalRepositoryID: Repository.ID,
        selectedModel: Session.Model,
        selectedReasoningEffort: Session.ReasoningEffort?,
        submittedPrompt: String
    ) {
        self.canonicalWorkspaceID = canonicalWorkspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.canonicalSessionID = canonicalSessionID
        self.remoteSessionID = remoteSessionID
        self.canonicalRepositoryID = canonicalRepositoryID
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.submittedPrompt = submittedPrompt
    }
}
