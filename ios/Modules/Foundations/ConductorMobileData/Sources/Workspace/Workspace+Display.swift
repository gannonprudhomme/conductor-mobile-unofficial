//
//  Workspace+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorFoundation
import Foundation
import IssueReporting

extension Workspace {
    public static let conductorCloudHostingServerURL = "https://api.conductor.build"

    public var status: Status {
        guard let rawValue = manualStatus?.nilIfEmpty ?? derivedStatus?.nilIfEmpty
        else {
            reportIssue("Workspace \(id) has neither a manual nor derived status.")
            return .inProgress
        }
        return Status(rawValue: rawValue)
    }
}

extension Workspace.Status {
    public static let displayOrder = [done, inReview, inProgress, backlog, canceled]

    public var title: String {
        switch self {
        case .done: "Done"
        case .inReview: "In review"
        case .inProgress: "In progress"
        case .backlog: "Backlog"
        case .canceled: "Canceled"
        default: rawValue
        }
    }
}

extension Workspace {
    public var isCloudHosted: Bool {
        guard let hostingServerURL,
              let components = URLComponents(string: hostingServerURL),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.conductor.build",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return components.path.isEmpty || components.path == "/"
    }

    public var emptyChatDirectoryName: String {
        let workspaceNameDirectoryName = workspaceName?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        let workspacePathDirectoryName = workspacePath
            .flatMap { $0.split(separator: "/").last }
            .map(String.init)

        return workspaceNameDirectoryName?.nilIfEmpty
            ?? branch?.nilIfEmpty
            ?? directoryName?.nilIfEmpty
            ?? workspacePathDirectoryName
            ?? id
    }

    public var displayName: String {
        if let prTitle = prTitle?.nilIfEmpty {
            return prTitle
        }

        if let workspaceName = workspaceName?.nilIfEmpty {
            return workspaceName
        }

        let name = [
            branch,
            placeholderBranchName,
            directoryName,
        ]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })

        guard let name else { return "Untitled branch" }

        let words = name.split { character in
            ["-", "_"].contains(character) || character.isWhitespace
        }
        let sentence = words.joined(separator: " ").lowercased()

        guard let firstCharacter = sentence.first else { return sentence }
        return firstCharacter.uppercased() + sentence.dropFirst()
    }
}
