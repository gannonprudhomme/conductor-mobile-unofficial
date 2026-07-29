//
//  DesktopEndpointTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import Foundation
@testable import ConductorMobileData
import Testing

struct DesktopEndpointTests {
    @Test(
        "Configured desktop addresses have one canonical network address",
        arguments: [
            ("EXAMPLE.com", "example.com:3768"),
            (" example.com:3768 ", "example.com:3768"),
            ("[2001:db8::1]", "[2001:db8::1]:3768"),
            ("[2001:DB8::1]:4000", "[2001:db8::1]:4000"),
            ("127.0.0.1:4000", "127.0.0.1:4000"),
        ]
    )
    func normalization(rawAddress: String, canonicalAddress: String) throws {
        let endpoint = try #require(DesktopEndpoint(rawAddress: rawAddress))

        #expect(endpoint.canonicalAddress == canonicalAddress)
        #expect(
            endpoint.url(scheme: "http")?.absoluteString
                == "http://\(canonicalAddress)"
        )
    }

    @Test(
        "Desktop addresses reject URL syntax and invalid ports",
        arguments: [
            "",
            "https://example.com",
            "user@example.com",
            "example.com/path",
            "example.com?query",
            "example.com#fragment",
            "example.com:0",
            "example.com:65536",
            "2001:db8::1",
        ]
    )
    func invalidAddress(rawAddress: String) {
        #expect(DesktopEndpoint(rawAddress: rawAddress) == nil)
    }

    @Test("Resume keys compare IDs as raw UTF-8 bytes")
    func resumeKeyUsesRawUTF8() {
        let composed = ResumeKey(
            workspaceID: "workspace-\u{e9}",
            sessionID: "session"
        )
        let decomposed = ResumeKey(
            workspaceID: "workspace-e\u{301}",
            sessionID: "session"
        )

        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
    }

    @Test("Request leases stop persistence after the configured endpoint changes")
    func requestLeasePersistenceBoundary() throws {
        let firstLifecycle = DesktopLeaseAuthority.shared.transition(
            to: "first-\(UUID().uuidString).example:3768"
        )
        let firstEndpoint = try #require(firstLifecycle.configuredEndpoint)
        let requestLease = DesktopRequestLease(
            baseURL: try #require(firstEndpoint.url(scheme: "http")),
            endpointEpoch: firstLifecycle.endpointEpoch
        )
        var value = 0

        let currentResult = requestLease.performIfCurrent {
            value = 1
        }
        #expect(currentResult != nil)
        #expect(value == 1)

        _ = DesktopLeaseAuthority.shared.transition(
            to: "second-\(UUID().uuidString).example:3768"
        )
        let staleResult = requestLease.performIfCurrent {
            value = 2
        }
        #expect(staleResult == nil)
        #expect(value == 1)
    }
}

private extension DesktopEndpointLifecycle {
    var configuredEndpoint: DesktopEndpoint? {
        guard case let .configured(endpoint, _) = self else {
            return nil
        }
        return endpoint
    }
}
