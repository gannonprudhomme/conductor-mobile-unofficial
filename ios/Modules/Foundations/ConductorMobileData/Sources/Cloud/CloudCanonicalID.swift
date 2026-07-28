//
//  CloudCanonicalID.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
import SharedConductorData

public enum CloudCanonicalID {
    public static func session(
        accountID: String,
        remoteSessionID: String
    ) -> Session.ID {
        "cloud-session:\(component(accountID)):\(component(remoteSessionID))"
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
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
