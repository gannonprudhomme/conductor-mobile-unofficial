//
//  IconRouteTests.swift
//  ConductorMobileServerTests
//
//  Created by Gannon Prudomme on 7/12/26.
//

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
            <svg width="1" height="1" xmlns="http://www.w3.org/2000/svg">
              <rect width="1" height="1" fill="black"/>
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
            let eTag = try await client.execute(
                uri: "/repositories/repository-1/icon",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(Data(response.body.readableBytesView).starts(with: pngSignature))
                return try #require(response.headers[.eTag])
            }

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

    private let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
}
