//
//  WorkspaceUIHookRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/14/26.
//

import Foundation
import Hummingbird
import HTTPTypes

// Serves the `browser-hook.mjs` file to the Console script running inside Tauri (`bootstrap-loader.js`)
enum WorkspaceUIHookRoute {
    static let origin = "tauri://localhost"


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
