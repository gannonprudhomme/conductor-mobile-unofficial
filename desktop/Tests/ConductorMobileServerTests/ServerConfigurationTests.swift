//
//  ServerConfigurationTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Testing

@testable import ConductorMobileServer

struct ServerConfigurationTests {
    @Test("Server uses its production port and ignores CONDUCTOR_PORT")
    func defaults() throws {
        let configuration = try ServerConfiguration(
            environment: ["CONDUCTOR_PORT": "49000"]
        )
        #expect(configuration.mobileAPIPort == 3_768)
        #expect(configuration.workspaceUIHookPort == 3_769)
    }

    @Test("Debug and test builds accept a mobile server port override")
    func override() throws {
        let configuration = try ServerConfiguration(
            environment: ["CONDUCTOR_MOBILE_API_PORT": "3778"]
        )
        #expect(configuration.mobileAPIPort == 3_778)
        #expect(configuration.workspaceUIHookPort == 3_779)
        #expect(
            try ServerConfiguration(
                environment: ["CONDUCTOR_MOBILE_API_PORT": "65534"]
            ).workspaceUIHookPort == 65_535
        )
    }

    @Test(
        "Explicit invalid overrides fail",
        arguments: ["", "abc", "0", "65535", "65536", "-1"]
    )
    func invalidOverride(value: String) {
        #expect(throws: ServerConfigurationError.invalidMobileAPIPort(value)) {
            try ServerConfiguration(
                environment: ["CONDUCTOR_MOBILE_API_PORT": value]
            )
        }
    }
}
