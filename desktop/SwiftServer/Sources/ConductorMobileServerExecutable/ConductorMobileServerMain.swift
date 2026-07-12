//
//  ConductorMobileServerMain.swift
//  ConductorMobileServerExecutable
//
//  Created by Gannon Prudomme on 7/12/26.
//

import ConductorMobileServer
import Darwin
import Foundation

@main
enum ConductorMobileServerMain {
    static func main() async {
        do {
            try await Server.run(databaseURL: databaseURL())
        } catch {
            FileHandle.standardError.write(
                Data("conductor-mobile-server: \(error.localizedDescription)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func databaseURL() -> URL {
        if let index = CommandLine.arguments.firstIndex(of: "--database-path"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.conductor.app/conductor.db")
    }
}
