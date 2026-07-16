//
//  WorkspaceUIHookRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import HummingbirdTesting
import HTTPTypes
import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookRouteTests {
    @Test("Hook script admits only Conductor or narrow originless script loads")
    func hookAdmission() async throws {
        let application = Server.makeWorkspaceUIHookApplication(
            broker: WorkspaceUIHookBroker(),
            hookSource: "hook();"
        )

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
        let broker = WorkspaceUIHookBroker()
        let application = Server.makeWorkspaceUIHookApplication(
            broker: broker,
            hookSource: "hook();"
        )

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

            let disconnect = Task {
                while !(await broker.isConnected) {
                    await Task.yield()
                }
                await broker.listenerUnavailable()
            }
            try await client.execute(
                uri: "/workspace-ui-hook/events",
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

        #expect(await broker.isConnected == false)
    }
}

private let secFetchDestination = HTTPField.Name("Sec-Fetch-Dest")!
private let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!
private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!
