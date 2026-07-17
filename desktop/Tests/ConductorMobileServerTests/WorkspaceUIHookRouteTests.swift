//
//  WorkspaceUIHookRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Dependencies
import HummingbirdTesting
import HTTPTypes
import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookRouteTests {
    @Test("Hook script admits only Conductor or narrow originless script loads")
    func hookAdmission() async throws {
        let hookSource = "hook();"
        let revision = WorkspaceUIHookRoute.revision(for: hookSource)
        let application = Server.makeWorkspaceUIHookApplication(hookSource: hookSource)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/workspace-ui-hook/hook.js",
                method: .get,
                headers: [.origin: WorkspaceUIHookRoute.origin]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.accessControlAllowOrigin] == WorkspaceUIHookRoute.origin)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.contentType] == "text/javascript; charset=utf-8")
                #expect(response.headers[.eTag] == revision)
                #expect(response.headers[.accessControlExposeHeaders] == "ETag")
                #expect(
                    response.headers[.vary]
                        == "Origin, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest"
                )
                #expect(String(buffer: response.body) == "hook();")
            }

            try await client.execute(
                uri: "/workspace-ui-hook/hook.js",
                method: .get,
                headers: [
                    secFetchDestination: "script",
                    secFetchMode: "no-cors",
                    secFetchSite: "cross-site",
                ]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.accessControlAllowOrigin] == "*")
            }

            for headers: HTTPFields in [
                [:],
                [.origin: "https://malicious.example"],
                [
                    secFetchDestination: "script",
                    secFetchMode: "cors",
                    secFetchSite: "cross-site",
                ],
            ] {
                try await client.execute(
                    uri: "/workspace-ui-hook/hook.js",
                    method: .get,
                    headers: headers
                ) { response in
                    #expect(response.status == .forbidden)
                    #expect(response.headers[.accessControlAllowOrigin] == nil)
                }
            }
        }
    }

    @Test("Events require the exact Conductor origin")
    func eventsAdmission() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let hookSource = "hook();"
        let revision = WorkspaceUIHookRoute.revision(for: hookSource)
        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeWorkspaceUIHookApplication(hookSource: hookSource)
            try await application.test(.router) { client in
                for headers: HTTPFields in [
                    [:],
                    [.origin: "https://malicious.example"],
                ] {
                    try await client.execute(
                        uri: "/workspace-ui-hook/events",
                        method: .get,
                        headers: headers
                    ) { response in
                        #expect(response.status == .forbidden)
                        #expect(response.headers[.accessControlAllowOrigin] == nil)
                        #expect(response.headers[.cacheControl] == "no-cache, no-transform")
                        #expect(response.headers[.vary] == "Origin")
                    }
                }

                try await client.execute(
                    uri: "/workspace-ui-hook/events?revision=stale",
                    method: .get,
                    headers: [.origin: WorkspaceUIHookRoute.origin]
                ) { response in
                    #expect(response.status == .conflict)
                    #expect(await uiHook.isConnected() == false)
                }

                let disconnect = Task {
                    while !(await uiHook.isConnected()) {
                        await Task.yield()
                    }
                    await uiHook.listenerUnavailable()
                }
                try await client.execute(
                    uri: "/workspace-ui-hook/events?revision=\(revision)",
                    method: .get,
                    headers: [.origin: WorkspaceUIHookRoute.origin]
                ) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.accessControlAllowOrigin] == WorkspaceUIHookRoute.origin)
                    #expect(response.headers[.cacheControl] == "no-cache, no-transform")
                    #expect(response.headers[.connection] == "keep-alive")
                    #expect(response.headers[.contentType] == "text/event-stream; charset=utf-8")
                    #expect(response.headers[.vary] == "Origin")
                }
                await disconnect.value
            }
        }

        #expect(await uiHook.isConnected() == false)
    }
}

private let secFetchDestination = HTTPField.Name("Sec-Fetch-Dest")!
private let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!
private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!
