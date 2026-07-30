//
//  CloudCanonicalID.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SharedConductorData

public enum CloudCanonicalID {
    public static func workspace(
        accountID: String,
        remoteWorkspaceID: String
    ) -> Workspace.ID {
        "cloud-workspace:\(component(accountID)):\(component(remoteWorkspaceID))"
    }

    public static func session(
        accountID: String,
        remoteSessionID: String
    ) -> Session.ID {
        "cloud-session:\(component(accountID)):\(component(remoteSessionID))"
    }

    public static func remoteSessionID(
        from canonicalSessionID: Session.ID
    ) -> Session.ID? {
        let components = canonicalSessionID.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "cloud-session",
              let accountID = decodeComponent(String(components[1])),
              let remoteSessionID = decodeComponent(String(components[2])),
              session(
                accountID: accountID,
                remoteSessionID: remoteSessionID
              ) == canonicalSessionID else {
            return nil
        }
        return remoteSessionID
    }

    public static func message(
        accountID: String,
        remoteSessionID: String,
        eventID: String,
        partOrder: Int
    ) -> Message.ID {
        [
            "cloud-message",
            component(accountID),
            component(remoteSessionID),
            component(eventID),
            String(partOrder),
        ]
        .joined(separator: ":")
    }

    public static func turn(
        accountID: String,
        remoteSessionID: String,
        remoteTurnID: String
    ) -> String {
        [
            "cloud-turn",
            component(accountID),
            component(remoteSessionID),
            component(remoteTurnID),
        ]
        .joined(separator: ":")
    }

    public static func tool(
        accountID: String,
        remoteSessionID: String,
        remoteToolID: String
    ) -> String {
        [
            "cloud-tool",
            component(accountID),
            component(remoteSessionID),
            component(remoteToolID),
        ]
        .joined(separator: ":")
    }

    private static func component(_ value: String) -> String {
        let normalizedValue = UUID(uuidString: value)?
            .uuidString
            .lowercased()
            ?? value
        return Data(normalizedValue.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
