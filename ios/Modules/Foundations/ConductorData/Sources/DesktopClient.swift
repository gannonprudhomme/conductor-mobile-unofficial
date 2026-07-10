import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct DesktopClient: Sendable {
    public var fetchMessages: @Sendable (_ workspaceID: String, _ sessionID: String) async throws -> [Message]
    public var fetchSessions: @Sendable (_ workspaceID: String) async throws -> [Session]
    public var fetchWorkspaces: @Sendable () async throws -> [Workspace]
    public var fetchRepositories: @Sendable () async throws -> [Repository]
}

public enum DesktopClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The desktop service returned an invalid response."

        case let .requestFailed(statusCode, message):
            if message.isEmpty {
                "The desktop service returned HTTP \(statusCode)."
            } else {
                "The desktop service returned HTTP \(statusCode): \(message)"
            }
        }
    }
}

extension DesktopClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            fetchMessages: { workspaceID, sessionID in
                try await fetch(
                    [Message].self,
                    from: URL(
                        string: "\(baseURL)/workspaces/\(workspaceID)/sessions/\(sessionID)/messages"
                    )!
                )
            },
            fetchSessions: { workspaceID in
                try await fetch(
                    [Session].self,
                    from: baseURL
                        .appending(path: "workspaces")
                        .appending(path: workspaceID)
                        .appending(path: "sessions")
                )
            },
            fetchWorkspaces: {
                try await fetch(
                    [Workspace].self,
                    from: baseURL.appending(path: "workspaces")
                )
            },
            fetchRepositories: {
                try await fetch(
                    [Repository].self,
                    from: baseURL.appending(path: "repositories")
                )
            }
        )
    }

    private static let baseURL = URL(string: "http://127.0.0.1:3768")!

    private static func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let response = response as? HTTPURLResponse
        else { throw DesktopClientError.invalidResponse }

        guard response.statusCode == 200
        else {
            throw DesktopClientError.requestFailed(
                statusCode: response.statusCode,
                message: String(decoding: data, as: UTF8.self)
            )
        }

        return try JSONDecoder.conductor.decode(type, from: data)
    }
}

public extension DependencyValues {
    var desktopClient: DesktopClient {
        get { self[DesktopClient.self] }
        set { self[DesktopClient.self] = newValue }
    }
}

public extension JSONDecoder {
    static var conductor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            if let date = Date.conductorDate(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(string)"
            )
        }
        return decoder
    }
}

private extension Date {
    static func conductorDate(from string: String) -> Date? {
        // The desktop service forwards Conductor's timestamp TEXT columns without normalizing
        // them. They contain both ISO 8601 values and SQLite datetime('now') values formatted as
        // "yyyy-MM-dd HH:mm:ss", whose space separator and missing time zone are not ISO 8601.
        // Try ISO 8601 first, then interpret SQLite's UTC value with the custom formatter.
        (try? Date(string, strategy: .iso8601))
            ?? DateFormatter.conductorSQLite.date(from: string)
    }
}

private extension DateFormatter {
    static var conductorSQLite: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .iso8601)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dateFormatter
    }
}
