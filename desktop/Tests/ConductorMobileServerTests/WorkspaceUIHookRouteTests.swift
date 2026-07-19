//
//  WorkspaceUIHookRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Dependencies
import Foundation
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

@testable import ConductorMobileServer

struct WorkspaceUIHookRouteTests {
    @Test("Command results require Conductor and complete the matching command")
    func commandResult() async throws {
        let uiHook = WorkspaceUIHook.liveValue
        let connection = await uiHook.connect()
        var events = connection.events.makeAsyncIterator()
        let requestID = UUID()
        let send = Task {
            try await uiHook.sendMessage(
                requestID: requestID,
                sessionID: "session-1",
                workspaceID: "workspace-1",
                content: "Run the tests.",
                mode: .sent
            )
        }
        let event = try #require(await events.next())
        let payload = event.dropFirst("data: ".count).dropLast(2)
        let command = try JSONDecoder().decode(
            CommandResultCommand.self,
            from: Data(payload.utf8)
        )

        try await withDependencies {
            $0.workspaceUIHook = uiHook
        } operation: {
            let application = Server.makeWorkspaceUIHookApplication(hookSource: "hook();")
            try await application.test(.router) { client in
                try await client.execute(
                    uri: "/workspace-ui-hook/command-result",
                    method: .options,
                    headers: [.origin: WorkspaceUIHookRoute.origin]
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(
                        response.headers[.accessControlAllowOrigin]
                            == WorkspaceUIHookRoute.origin
                    )
                    #expect(response.headers[.accessControlAllowMethods] == "POST")
                    #expect(response.headers[.accessControlAllowHeaders] == "Content-Type")
                }

                try await client.execute(
                    uri: "/workspace-ui-hook/command-result",
                    method: .post,
                    headers: [
                        .contentType: "application/json",
                        .origin: "https://malicious.example",
                    ],
                    body: ByteBuffer(
                        string: "{\"requestId\":\"\(command.requestID)\",\"result\":{\"type\":\"accepted\",\"messageId\":\"message-id\",\"state\":\"sent\"}}"
                    )
                ) { response in
                    #expect(response.status == .forbidden)
                    #expect(response.headers[.accessControlAllowOrigin] == nil)
                }

                try await client.execute(
                    uri: "/workspace-ui-hook/command-result",
                    method: .post,
                    headers: [
                        .contentType: "application/json",
                        .origin: WorkspaceUIHookRoute.origin,
                    ],
                    body: ByteBuffer(
                        string: "{\"requestId\":\"\(command.requestID)\",\"result\":{\"type\":\"accepted\",\"messageId\":\"message-id\",\"state\":\"sent\"}}"
                    )
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(
                        response.headers[.accessControlAllowOrigin]
                            == WorkspaceUIHookRoute.origin
                    )
                }
            }
        }

        #expect(try await send.value.messageID == "message-id")
    }

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

private struct CommandResultCommand: Decodable {
    let requestID: UUID

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
    }
}

private let secFetchDestination = HTTPField.Name("Sec-Fetch-Dest")!
private let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!
private let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!
