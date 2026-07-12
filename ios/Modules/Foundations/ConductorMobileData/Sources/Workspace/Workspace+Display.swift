//
//  Workspace+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import ConductorFoundation
import IssueReporting

extension Workspace {
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
    public var displayBranchName: String {
        let name = [
            branch,
            placeholderBranchName,
            workspaceName,
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
