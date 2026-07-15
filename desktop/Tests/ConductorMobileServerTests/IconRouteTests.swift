//
//  IconRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

import AppKit
import CustomDump
import Foundation
import Hummingbird
import HummingbirdTesting
import SQLiteData
import Testing

@testable import ConductorMobileServer

struct IconRouteTests {
    @Test("Repository icons use Conductor's documented filename order and are served as PNG")
    func repositoryIcon() async throws {
        let fileManager = FileManager.default
        let rootURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileManager.temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: rootURL) }

        let publicURL = rootURL.appending(path: "public", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: publicURL, withIntermediateDirectories: true)
        try Data("lower-priority".utf8).write(to: rootURL.appending(path: "favicon.svg"))
        let svgData = Data(
            """
            <svg width="2" height="3" xmlns="http://www.w3.org/2000/svg">
              <rect x="0" y="0" width="1" height="1" fill="#ff0000"/>
              <rect x="1" y="0" width="1" height="1" fill="#00ff00" fill-opacity="0.5"/>
              <rect x="0" y="1" width="1" height="1" fill="#0000ff"/>
              <rect x="1" y="1" width="1" height="1" fill="#ffff00"/>
              <rect x="0" y="2" width="1" height="1" fill="#ff00ff"/>
              <rect x="1" y="2" width="1" height="1" fill="#00ffff"/>
            </svg>
            """.utf8
        )
        try svgData.write(to: publicURL.appending(path: "favicon.svg"))

        let database = try DatabaseQueue()
        try await database.write { database in
            try database.execute(
                sql: """
                    CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT);
                    INSERT INTO repos (id, root_path) VALUES (?, ?);
                    """,
                arguments: ["repository-1", rootURL.path]
            )
        }
        let router = Router(context: Server.RequestContext.self)
        router.get("/repositories/{repositoryID}/icon") { request, context in
            try await IconRoute.response(
                request: request,
                context: context,
                database: database
            )
        }
        let application = Application(router: router)

        try await application.test(.router) { client in
            let (eTag, svgImage) = try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                #expect(response.headers[.cacheControl] == "no-cache")
                return (
                    try #require(response.headers[.eTag]),
                    try decodedImage(
                        Data(response.body.readableBytesView),
                        sampling: [(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2)]
                    )
                )
            }
            expectNoDifference(
                svgImage,
                DecodedImage(
                    width: 2,
                    height: 3,
                    pixels: [
                        DecodedPixel(x: 0, y: 0, red: 255, green: 0, blue: 0, alpha: 255),
                        DecodedPixel(x: 1, y: 0, red: 0, green: 255, blue: 0, alpha: 128),
                        DecodedPixel(x: 0, y: 1, red: 0, green: 0, blue: 255, alpha: 255),
                        DecodedPixel(x: 1, y: 1, red: 255, green: 255, blue: 0, alpha: 255),
                        DecodedPixel(x: 0, y: 2, red: 255, green: 0, blue: 255, alpha: 255),
                        DecodedPixel(x: 1, y: 2, red: 0, green: 255, blue: 255, alpha: 255),
                    ]
                )
            )

            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get,
                headers: [.ifNoneMatch: eTag]
            ) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
            }

            try (svgData + Data("\n".utf8)).write(
                to: publicURL.appending(path: "favicon.svg")
            )
            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get,
                headers: [.ifNoneMatch: eTag]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.eTag] != eTag)
            }

            try FileManager.default.removeItem(at: publicURL.appending(path: "favicon.svg"))
            try FileManager.default.removeItem(at: rootURL.appending(path: "favicon.svg"))
            try asymmetricICOData.write(to: rootURL.appending(path: "favicon.ico"))
            let icoImage = try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                try decodedImage(
                    Data(response.body.readableBytesView),
                    sampling: [(0, 0), (15, 0), (0, 15), (15, 15)]
                )
            }
            expectNoDifference(
                icoImage,
                DecodedImage(
                    width: 16,
                    height: 16,
                    pixels: [
                        DecodedPixel(x: 0, y: 0, red: 255, green: 0, blue: 0, alpha: 255),
                        DecodedPixel(x: 15, y: 0, red: 0, green: 255, blue: 0, alpha: 128),
                        DecodedPixel(x: 0, y: 15, red: 0, green: 0, blue: 255, alpha: 255),
                        DecodedPixel(x: 15, y: 15, red: 255, green: 255, blue: 0, alpha: 255),
                    ]
                )
            )

            try await client.execute(
                uri: "/repositories/missing/icon",
                method: .get
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("Repository icons cannot escape the repository through a symbolic link")
    func symlinkEscape() async throws {
        let fileManager = FileManager.default
        let containerURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileManager.temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: containerURL) }

        let rootURL = containerURL.appending(path: "repository", directoryHint: .isDirectory)
        let publicURL = rootURL.appending(path: "public", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: publicURL, withIntermediateDirectories: true)
        let outsideURL = containerURL.appending(path: "outside.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outsideURL)
        try fileManager.createSymbolicLink(
            at: publicURL.appending(path: "apple-touch-icon.png"),
            withDestinationURL: outsideURL
        )

        let database = try DatabaseQueue()
        try await database.write { database in
            try database.execute(
                sql: """
                    CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT);
                    INSERT INTO repos (id, root_path) VALUES (?, ?);
                    """,
                arguments: ["repository-1", rootURL.path]
            )
        }
        let router = Router(context: Server.RequestContext.self)
        router.get("/repositories/{repositoryID}/icon") { request, context in
            try await IconRoute.response(
                request: request,
                context: context,
                database: database
            )
        }
        let application = Application(router: router)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("Oversized vector icons are rejected before rasterization")
    func oversizedVectorIcon() async throws {
        let fileManager = FileManager.default
        let containerURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileManager.temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: containerURL) }

        let rootURL = containerURL.appending(path: "repository", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000">
              <rect width="100%" height="100%"/>
            </svg>
            """.utf8
        ).write(to: rootURL.appending(path: "favicon.svg"))

        let database = try DatabaseQueue()
        try await database.write { database in
            try database.execute(
                sql: """
                    CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT);
                    INSERT INTO repos (id, root_path) VALUES (?, ?);
                    """,
                arguments: ["repository-1", rootURL.path]
            )
        }
        let router = Router(context: Server.RequestContext.self)
        router.get("/repositories/{repositoryID}/icon") { request, context in
            try await IconRoute.response(
                request: request,
                context: context,
                database: database
            )
        }
        let application = Application(router: router)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    private struct DecodedImage: Equatable, Sendable {
        let width: Int
        let height: Int
        let pixels: [DecodedPixel]
    }

    private struct DecodedPixel: Equatable, Sendable {
        let x: Int
        let y: Int
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private func decodedImage(
        _ data: Data,
        sampling coordinates: [(x: Int, y: Int)]
    ) throws -> DecodedImage {
        #expect(data.starts(with: pngSignature))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        return DecodedImage(
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            pixels: try coordinates.map { coordinate in
                let color = try #require(
                    bitmap.colorAt(x: coordinate.x, y: coordinate.y)?.usingColorSpace(.sRGB)
                )
                return DecodedPixel(
                    x: coordinate.x,
                    y: coordinate.y,
                    red: binaryChannel(color.redComponent),
                    green: binaryChannel(color.greenComponent),
                    blue: binaryChannel(color.blueComponent),
                    alpha: UInt8(clamping: Int((color.alphaComponent * 255).rounded()))
                )
            }
        )
    }

    private func binaryChannel(_ component: CGFloat) -> UInt8 {
        component < 0.5 ? 0 : 255
    }

    private var asymmetricICOData: Data {
        let size = 16
        let bitmapByteCount = size * size * 4
        let maskByteCount = ((size + 31) / 32) * 4 * size
        let imageByteCount = 40 + bitmapByteCount + maskByteCount
        var data = Data()

        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append(UInt16(0))
        append(UInt16(1))
        append(UInt16(1))
        data.append(UInt8(size))
        data.append(UInt8(size))
        data.append(contentsOf: [0, 0])
        append(UInt16(1))
        append(UInt16(32))
        append(UInt32(imageByteCount))
        append(UInt32(22))
        append(UInt32(40))
        append(UInt32(size))
        append(UInt32(size * 2))
        append(UInt16(1))
        append(UInt16(32))
        append(UInt32(0))
        append(UInt32(bitmapByteCount))
        append(UInt32(0))
        append(UInt32(0))
        append(UInt32(0))
        append(UInt32(0))
        for bitmapY in 0..<size {
            for x in 0..<size {
                let outputY = size - 1 - bitmapY
                switch (x, outputY) {
                case (0, 0):
                    data.append(contentsOf: [0, 0, 255, 255])
                case (size - 1, 0):
                    data.append(contentsOf: [0, 255, 0, 128])
                case (0, size - 1):
                    data.append(contentsOf: [255, 0, 0, 255])
                case (size - 1, size - 1):
                    data.append(contentsOf: [0, 255, 255, 255])
                default:
                    data.append(contentsOf: [0, 0, 0, 255])
                }
            }
        }
        data.append(Data(repeating: 0, count: maskByteCount))
        return data
    }

    private let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
}
