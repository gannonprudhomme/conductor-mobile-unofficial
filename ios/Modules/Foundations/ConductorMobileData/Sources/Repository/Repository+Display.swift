//
//  Repository+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import SharedConductorData
import Foundation

extension Repository {
    public var displayName: String {
        guard let name, !name.isEmpty else { return id }
        return name
    }

    public var githubOwnerAvatarURL: URL? {
        guard let remoteURL else { return nil }

        let owner: String? = if let components = URLComponents(string: remoteURL),
            components.host?.lowercased() == "github.com" {
            // URL-shaped remotes, including HTTPS and `ssh://`, expose their host and path.
            components.path.split(separator: "/").first.map(String.init)
        } else if remoteURL.lowercased().hasPrefix("git@github.com:") {
            // Git's SCP-like SSH syntax does not expose `github.com` as a URL host.
            remoteURL
                .dropFirst("git@github.com:".count)
                .split(separator: "/")
                .first
                .map(String.init)
        } else {
            nil
        }

        guard let owner, !owner.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner).png"
        components.queryItems = [URLQueryItem(name: "size", value: "128")]
        return components.url
    }
}
