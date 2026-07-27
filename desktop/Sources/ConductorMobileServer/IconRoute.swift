//
//  IconRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

#if canImport(AppKit)
import AppKit
import Foundation
import Hummingbird
import NIOPosix
import SharedConductorData
import SQLiteData

enum IconRoute {
    struct RemoteFavicon: Sendable {
        let data: Data
        let eTag: String
    }

    static func response(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader,
        remoteWorkspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "conductor/remote-workspace-sync", directoryHint: .isDirectory),
        loadRemoteFavicon: @escaping @Sendable (URL) async throws -> RemoteFavicon? =
            loadRemoteFavicon
    ) async throws -> Response {
        let repositoryID = try context.parameters.require("repositoryID")
        let repositoryLocation = try await database.read { database in
            let rootPath: String? = try Repository
                .where { $0.id.eq(repositoryID) }
                .select(\.rootPath)
                .fetchOne(database)
                ?? nil
            let remoteURL: String? = try Repository
                .where { $0.id.eq(repositoryID) }
                .select(\.remoteURL)
                .fetchOne(database)
                ?? nil
            let defaultBranch: String? = try Repository
                .where { $0.id.eq(repositoryID) }
                .select(\.defaultBranch)
                .fetchOne(database)
                ?? nil
            let name: String? = try Repository
                .where { $0.id.eq(repositoryID) }
                .select(\.name)
                .fetchOne(database)
                ?? nil
            let workspaceIDs = try Workspace
                .where { $0.repositoryID.eq(repositoryID) }
                .select(\.id)
                .fetchAll(database)
            return RepositoryLocation(
                rootPath: rootPath,
                remoteURL: remoteURL,
                defaultBranch: defaultBranch,
                name: name,
                workspaceIDs: workspaceIDs
            )
        }

        if let rootPath = repositoryLocation.rootPath,
            let iconFile = searchForFavicon(rootURL: URL(filePath: rootPath)) {
            return try await localResponse(
                request: request,
                context: context,
                iconFile: iconFile
            )
        }

        if let iconFile = searchRemoteWorkspaceMirrors(
            rootURL: remoteWorkspaceRoot,
            repositoryName: repositoryLocation.name,
            workspaceIDs: repositoryLocation.workspaceIDs
        ) {
            return try await localResponse(
                request: request,
                context: context,
                iconFile: iconFile
            )
        }

        guard let remoteURL = repositoryLocation.remoteURL,
            let faviconURL = remoteFaviconURL(
                repositoryURL: remoteURL,
                defaultBranch: repositoryLocation.defaultBranch
            ),
            let remoteFavicon = try await loadRemoteFavicon(faviconURL)
        else {
            throw HTTPError(.notFound)
        }
        return try await remoteResponse(
            request: request,
            context: context,
            favicon: remoteFavicon
        )
    }

    private static func localResponse(
        request: Request,
        context: Server.RequestContext,
        iconFile: (url: URL, eTag: String)
    ) async throws -> Response {
        // Clients revalidate a cached icon with If-None-Match. A matching ETag returns
        // 304 without loading or resending the icon; a changed ETag sends the new image.
        return try await request.ifNoneMatch(
            headers: [
                .cacheControl: "no-cache",
                .contentType: "image/png",
            ],
            eTag: iconFile.eTag,
            context: context
        ) {
            if iconFile.url.pathExtension.lowercased() == "png" {
                return Response(
                    status: .ok,
                    body: try await FileIO().loadFile(path: iconFile.url.path, context: context)
                )
            }

            let data = try await NIOThreadPool.singleton.runIfActive {
                try pngData(contentsOf: iconFile.url)
            }
            return Response(
                status: .ok,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }
    }

    private static func remoteResponse(
        request: Request,
        context: Server.RequestContext,
        favicon: RemoteFavicon
    ) async throws -> Response {
        try await request.ifNoneMatch(
            headers: [
                .cacheControl: "no-cache",
                .contentType: "image/png",
            ],
            eTag: favicon.eTag,
            context: context
        ) {
            let data = try await NIOThreadPool.singleton.runIfActive {
                try pngData(favicon.data)
            }
            return Response(
                status: .ok,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }
    }

    private static func pngData(contentsOf url: URL) throws -> Data {
        // NIO thread-pool jobs have no per-job autorelease pool. Drain AppKit's temporary image
        // representations after each request, and draw one bounded bitmap instead of creating the
        // multiple large raster snapshots produced by NSImage.tiffRepresentation.
        try autoreleasepool {
            guard let image = NSImage(contentsOf: url) else {
                throw HTTPError(.internalServerError, message: "Could not decode repository icon")
            }
            return try pngData(image)
        }
    }

    private static func pngData(_ data: Data) throws -> Data {
        try autoreleasepool {
            guard let image = NSImage(data: data) else {
                throw HTTPError(
                    .internalServerError,
                    message: "Could not decode repository icon"
                )
            }
            return try pngData(image)
        }
    }

    private static func pngData(_ image: NSImage) throws -> Data {
        let size = image.size
        guard size.width.isFinite,
            size.height.isFinite,
            size.width > 0,
            size.height > 0,
            size.width <= maximumPixelDimension,
            size.height <= maximumPixelDimension,
            size.width * size.height <= maximumPixelCount
        else {
            throw HTTPError(.notFound)
        }
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw HTTPError(.internalServerError, message: "Could not decode repository icon")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw HTTPError(.internalServerError, message: "Could not encode repository icon")
        }
        return pngData
    }

    private static func loadRemoteFavicon(url: URL) async throws -> RemoteFavicon? {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
            200..<300 ~= response.statusCode,
            data.count <= maximumIconByteCount
        else {
            return nil
        }
        return RemoteFavicon(
            data: data,
            eTag: response.value(forHTTPHeaderField: "ETag")
                ?? "\"remote-\(data.count)-\(data.hashValue)\""
        )
    }

    private static func remoteFaviconURL(
        repositoryURL: String,
        defaultBranch: String?
    ) -> URL? {
        let path: Substring? = if let components = URLComponents(string: repositoryURL),
            components.host?.lowercased() == "github.com" {
            components.path[...]
        } else if repositoryURL.lowercased().hasPrefix("git@github.com:") {
            repositoryURL.dropFirst("git@github.com:".count)
        } else {
            nil
        }

        guard let path else { return nil }
        let pathComponents = path.split(separator: "/")
        guard pathComponents.count >= 2 else { return nil }
        let owner = String(pathComponents[0])
        let repository = pathComponents[1].hasSuffix(".git")
            ? String(pathComponents[1].dropLast(4))
            : String(pathComponents[1])
        guard !owner.isEmpty, !repository.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        let branch = defaultBranch.flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        components.path = [
            "",
            owner,
            repository,
            branch,
            "favicon.svg",
        ].joined(separator: "/")
        return components.url
    }

    private static func searchRemoteWorkspaceMirrors(
        rootURL: URL,
        repositoryName: String?,
        workspaceIDs: [Workspace.ID]
    ) -> (url: URL, eTag: String)? {
        guard let repositoryName,
            isSafePathComponent(repositoryName)
        else {
            return nil
        }

        for workspaceID in workspaceIDs.sorted() where isSafePathComponent(workspaceID) {
            let workspaceURL = rootURL
                .appending(path: repositoryName, directoryHint: .isDirectory)
                .appending(path: workspaceID, directoryHint: .isDirectory)
            if let iconFile = searchForFavicon(rootURL: workspaceURL) {
                return iconFile
            }
        }
        return nil
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    // Searches known favicon locations in priority order and returns the first safe, usable file.
    private static func searchForFavicon(rootURL: URL) -> (url: URL, eTag: String)? {
        // Resolve the repository root once so candidate symlinks can be checked against it.
        let canonicalRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        // Stop searching when the repository root does not exist or is not a directory.
        guard (try? canonicalRootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        // Check each supported location in display-priority order.
        for (index, iconPath) in iconSearchPaths.enumerated() {
            let iconURL = canonicalRootURL
                .appending(path: iconPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            // Skip symbolic links that resolve outside the repository.
            guard iconURL.pathComponents.starts(with: canonicalRootURL.pathComponents) else {
                continue
            }
            // Skip missing, non-file, or oversized candidates.
            guard let values = try? iconURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let fileSize = values.fileSize,
                fileSize <= maximumIconByteCount, let modificationDate = values.contentModificationDate
            else {
                continue
            }
            return (
                url: iconURL,
                eTag: "\"\(index)-\(fileSize)-\(modificationDate.timeIntervalSince1970.bitPattern)\""
            )
        }

        return nil
    }

    private static let maximumIconByteCount = 5 * 1_024 * 1_024
    private static let maximumPixelDimension: CGFloat = 4_096
    private static let maximumPixelCount: CGFloat = 1_024 * 1_024

    private static let iconSearchPaths = [
        "public/apple-touch-icon.png",
        "apple-touch-icon.png",
        "public/favicon.svg",
        "favicon.svg",
        "public/favicon.png",
        "public/icon.png",
        "public/logo.png",
        "favicon.png",
        "app/icon.png",
        "src/app/icon.png",
        "public/favicon.ico",
        "favicon.ico",
        "app/favicon.ico",
        "static/favicon.ico",
        "src-tauri/icons/icon.png",
        "assets/icon.png",
        "src/assets/icon.png",
    ]

    private struct RepositoryLocation: Sendable {
        let rootPath: String?
        let remoteURL: String?
        let defaultBranch: String?
        let name: String?
        let workspaceIDs: [Workspace.ID]
    }
}
#endif
