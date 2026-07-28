//
//  WorkspaceMutationRoute.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import ConductorCloud
import SharedConductorData

public enum WorkspaceSource: Equatable, Sendable {
    case desktop
    case cloud
}

public enum WorkspaceMutationRoute: Equatable, Sendable {
    case desktop
    case cloud(
        accountID: String,
        remoteWorkspaceID: String
    )
}

public enum WorkspaceCreationRoute: Equatable, Sendable {
    case desktop
    case cloud(accountID: String)
}

public struct WorkspaceCapabilities: Equatable, Sendable {
    public var canSend: Bool
    public var canCancel: Bool
    public var canCreateSession: Bool
    public var canRenameSession: Bool
    public var canArchiveSession: Bool
    public var canArchiveWorkspace: Bool
    public var canManageQueue: Bool
    public var canRestoreSession: Bool
    public var canRenameBranch: Bool
    public var canPin: Bool
    public var canMarkUnread: Bool
    public var canSetStatus: Bool
    public var canConfigureMessages: Bool

    public static let unavailable = Self(
        canSend: false,
        canCancel: false,
        canCreateSession: false,
        canRenameSession: false,
        canArchiveSession: false,
        canArchiveWorkspace: false,
        canManageQueue: false,
        canRestoreSession: false,
        canRenameBranch: false,
        canPin: false,
        canMarkUnread: false,
        canSetStatus: false,
        canConfigureMessages: false
    )

    public static let desktop = Self(
        canSend: true,
        canCancel: true,
        canCreateSession: true,
        canRenameSession: true,
        canArchiveSession: true,
        canArchiveWorkspace: true,
        canManageQueue: true,
        canRestoreSession: true,
        canRenameBranch: true,
        canPin: true,
        canMarkUnread: true,
        canSetStatus: true,
        canConfigureMessages: true
    )

    public static let cloud = Self(
        canSend: true,
        canCancel: true,
        canCreateSession: true,
        canRenameSession: true,
        canArchiveSession: true,
        canArchiveWorkspace: true,
        canManageQueue: false,
        canRestoreSession: false,
        canRenameBranch: false,
        canPin: false,
        canMarkUnread: false,
        canSetStatus: false,
        canConfigureMessages: false
    )
}

public extension WorkspaceWithRepository {
    var source: WorkspaceSource {
        cloudMetadata != nil || workspace.isCloudHosted
            ? .cloud
            : .desktop
    }

    func mutationRoute(
        cloudConfiguration: CloudConfiguration?
    ) -> WorkspaceMutationRoute? {
        if cloudMetadata == nil && !workspace.isCloudHosted {
            return .desktop
        }
        guard let cloudMetadata,
              cloudMetadata.accountID == cloudConfiguration?.accountID else {
            return nil
        }
        return .cloud(
            accountID: cloudMetadata.accountID,
            remoteWorkspaceID: cloudMetadata.remoteWorkspaceID
        )
    }
}

public extension WorkspaceMutationRoute {
    var capabilities: WorkspaceCapabilities {
        switch self {
        case .desktop:
            .desktop
        case .cloud:
            .cloud
        }
    }
}

public extension Optional where Wrapped == WorkspaceMutationRoute {
    var capabilities: WorkspaceCapabilities {
        self?.capabilities ?? .unavailable
    }
}

public struct CloudCreationConfiguration: Equatable, Sendable {
    public let agent: Session.AgentType
    public let model: Session.Model
    public let efforts: [Session.ReasoningEffort]
    public let supportsFastMode: Bool

    public init(
        agent: Session.AgentType,
        model: Session.Model,
        efforts: [Session.ReasoningEffort],
        supportsFastMode: Bool
    ) {
        self.agent = agent
        self.model = model
        self.efforts = efforts
        self.supportsFastMode = supportsFastMode
    }
}

public enum CloudCreationConfigurationCatalog {
    public static let defaultConfiguration = configurations[0]

    public static let configurations: [CloudCreationConfiguration] = [
        claude(.fable5),
        claude(.opus4_8_1M),
        claude(Session.Model(rawValue: "opus-4-8")),
        claude(.opus4_7_1M),
        claude(Session.Model(rawValue: "opus-4-7")),
        claude(.opus_1M),
        claude(.opus),
        claude(.opus4_6_1M),
        claude(.sonnet5_1M),
        claude(.sonnet_4_6_1M),
        claude(.sonnet_4_6),
        claude(.haiku4_5),
        codex(.gpt5_5),
        codex(.gpt5_4),
        codex(.gpt_5_6_sol),
        codex(.gpt_5_6_terra),
        codex(.gpt_5_6_luna),
        codex(Session.Model(rawValue: "gpt-5.3-codex-spark")),
        codex(.gpt5_3Codex),
        codex(Session.Model(rawValue: "gpt-5.2-codex")),
    ]

    private static func claude(
        _ model: Session.Model
    ) -> CloudCreationConfiguration {
        CloudCreationConfiguration(
            agent: .claude,
            model: model,
            efforts: [.low, .medium, .high, .extraHigh, .max],
            supportsFastMode: false
        )
    }

    private static func codex(
        _ model: Session.Model
    ) -> CloudCreationConfiguration {
        CloudCreationConfiguration(
            agent: .codex,
            model: model,
            efforts: [.none, .low, .medium, .high, .extraHigh, .max],
            supportsFastMode: false
        )
    }
}
