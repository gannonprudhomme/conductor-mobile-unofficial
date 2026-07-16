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

    static func getHook(request: Request, source: String) -> Response {
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


    private static func hookAdmission(for request: Request) -> HookAdmission? {
        if request.headers[.origin] == origin {
            return .conductor
        } else {
            // Cross-origin module scripts omit Origin, so admit only their exact fetch metadata.
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
