//
//  IconRoute.swift
//  ConductorMobileServer
//
//  Created by Gannon Prudomme on 7/12/26.
//

import AppKit
import Foundation
import Hummingbird
import NIOPosix
import SharedConductorData
import SQLiteData

enum IconRoute {
    static func response(
        request: Request,
        context: Server.RequestContext,
        database: any DatabaseReader
    ) async throws -> Response {
        let repositoryID = try context.parameters.require("repositoryID")
        let rootPath = try await database.read { database in
            let rootPath: String? = try Repository
                .where { $0.id.eq(repositoryID) }
                .select(\.rootPath)
                .fetchOne(database)
                ?? nil
            return rootPath
        }
        guard let rootPath, let iconFile = searchForFavicon(rootURL: URL(filePath: rootPath)) else {
            throw HTTPError(.notFound)
        }

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

    private static func pngData(contentsOf url: URL) throws -> Data {
        // NIO thread-pool jobs have no per-job autorelease pool. Drain AppKit's temporary image
        // representations after each request, and draw one bounded bitmap instead of creating the
        // multiple large raster snapshots produced by NSImage.tiffRepresentation.
        try autoreleasepool {
            guard let image = NSImage(contentsOf: url) else {
                throw HTTPError(.internalServerError, message: "Could not decode repository icon")
            }
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
}
