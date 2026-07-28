//
//  Repository+Display.swift
//  ConductorMobileData
//
//  Created by Gannon Prudomme on 7/12/26.
//

import Foundation
import SharedConductorData
import SQLiteData

extension Repository {
    /// Repositories that the desktop companion can use to create a local workspace.
    ///
    /// `Repository.all` also contains repositories created from Cloud API projects so the
    /// unified workspace list can group and label API-only rows. Those repositories cannot be
    /// sent to the desktop creation endpoint unless desktop observation has also seen one of
    /// their workspaces. Repositories with no workspaces remain eligible.
    public static var availableForLocalWorkspaceCreation: some SelectStatement<
        Repository,
        Repository,
        (Workspace?, CloudWorkspaceMetadata?, MobileWorkspaceState?)
    > {
        Repository.all
            // Join through workspaces to determine which source currently owns this repository.
            .leftJoin(Workspace.all) { repository, workspace in
                workspace.repositoryID.eq(repository.id)
            }
            .leftJoin(CloudWorkspaceMetadata.all) {
                _,
                workspace,
                cloudMetadata in
                workspace.id.eq(cloudMetadata.workspaceID)
            }
            .leftJoin(MobileWorkspaceState.all) {
                _,
                workspace,
                _,
                mobileState in
                workspace.id.eq(mobileState.workspaceID)
            }
            .where { _, workspace, cloudMetadata, mobileState in
                let hasCloudMetadata = cloudMetadata.workspaceID.isNot(nil)
                let isCloudHosted = workspace.hostingServerURL.is(
                    Workspace.conductorCloudHostingServerURL
                )
                let hasDesktopObservation = mobileState.workspaceID.isNot(nil)
                return !(hasCloudMetadata || isCloudHosted)
                    || hasDesktopObservation
            }
            // A repository can join multiple workspaces; the creation menu needs one row each.
            .order { repository, _, _, _ in repository.displayOrder }
            .order { repository, _, _, _ in repository.name.lower() }
            .order { repository, _, _, _ in repository.id }
            .select { repository, _, _, _ in repository }
            .distinct()
    }

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
