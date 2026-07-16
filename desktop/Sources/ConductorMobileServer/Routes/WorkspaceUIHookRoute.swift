//
//  WorkspaceUIHookRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Dependencies
import Foundation
import Hummingbird
import HTTPTypes

// Serves the `browser-hook.mjs` file to the Console script running inside Tauri (`bootstrap-loader.js`)
enum WorkspaceUIHookRoute {
    static let origin = "tauri://localhost"

    static func getHookFileContents(request: Request, source: String) -> Response {
        guard let admission = hookAdmission(for: request) else {
            logDenied(route: "hook", request: request)
            return Response(status: .forbidden, headers: hookHeaders(admission: nil))
        }

        var headers = hookHeaders(admission: admission)
        headers[.contentType] = "text/javascript; charset=utf-8"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: source))
        )
    }

    static func events(request: Request) async -> Response {
        // SSE carries mutations, so it always requires Conductor's exact Origin.
        guard request.headers[.origin] == origin else {
            logDenied(route: "events", request: request)
            return Response(status: .forbidden, headers: eventHeaders(isAdmitted: false))
        }

        @Dependency(\.workspaceUIHook) var uiHook
        let connection = await uiHook.connect()
        var headers = eventHeaders(isAdmitted: true)
        headers[.connection] = "keep-alive"
        headers[.contentType] = "text/event-stream; charset=utf-8"
        return Response(
            status: .ok,
            headers: headers,
            body: .init { writer in
                do {
                    for await event in connection.events {
                        try await writer.write(ByteBuffer(string: event))
                    }
                    try await writer.finish(nil)
                } catch {
                    await uiHook.disconnect(connectionID: connection.id)
                    throw error
                }
                await uiHook.disconnect(connectionID: connection.id)
            }
        )
    }

    private enum HookAdmission {
        case conductor
        case originlessScript
    }

    // The loader dynamically imports this module from Conductor's `tauri://localhost` page into
    // the hook server's `http://127.0.0.1` origin. Tauri's module request omits `Origin`, so the
    // exact `Sec-Fetch-*` metadata is the only evidence that the originless request is the expected
    // cross-origin script load. Rejecting all originless requests would break the loader; accepting
    // them without these checks would expose the hook source to arbitrary local requests.
    // HTTPTypes has no predefined names for these three Fetch Metadata headers.
    private static let secFetchDestination = HTTPField.Name("Sec-Fetch-Dest")!
    private static let secFetchMode = HTTPField.Name("Sec-Fetch-Mode")!
    private static let secFetchSite = HTTPField.Name("Sec-Fetch-Site")!

    private static func hookAdmission(for request: Request) -> HookAdmission? {
        if request.headers[.origin] == origin {
            return .conductor
        } else {
            guard request.headers[.origin] == nil,
                request.headers[secFetchSite] == "cross-site",
                request.headers[secFetchMode] == "no-cors",
                request.headers[secFetchDestination] == "script"
            else {
                return nil
            }

            return .originlessScript
        }
    }

    private static func hookHeaders(admission: HookAdmission?) -> HTTPFields {
        var headers: HTTPFields = [
            .cacheControl: "no-store",
            .vary: "Origin, Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest",
        ]
        switch admission {
        case .conductor:
            headers[.accessControlAllowOrigin] = origin
        case .originlessScript:
            // With no request Origin to echo, `*` lets the admitted module load complete. The
            // mutation-bearing event stream still requires Conductor's exact Origin below.
            headers[.accessControlAllowOrigin] = "*"
        case nil:
            break
        }
        return headers
    }

    private static func eventHeaders(isAdmitted: Bool) -> HTTPFields {
        var headers: HTTPFields = [
            .cacheControl: "no-cache, no-transform",
            .vary: "Origin",
        ]
        if isAdmitted {
            headers[.accessControlAllowOrigin] = origin
        }
        return headers
    }

    private static func logDenied(route: String, request: Request) {
        #if DEBUG
            let values = [
                "route=\(route)",
                "origin=\(request.headers[.origin] ?? "<none>")",
                "sec-fetch-site=\(request.headers[secFetchSite] ?? "<none>")",
                "sec-fetch-mode=\(request.headers[secFetchMode] ?? "<none>")",
                "sec-fetch-dest=\(request.headers[secFetchDestination] ?? "<none>")",
            ]
            FileHandle.standardError.write(
                Data("workspace-ui-hook denied: \(values.joined(separator: " "))\n".utf8)
            )
        #endif
    }
}
