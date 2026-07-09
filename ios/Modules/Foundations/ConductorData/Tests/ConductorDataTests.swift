import ConductorData
import Foundation
import Testing

struct ConductorDataTests {
    @Test
    func testDesktopClientErrorDescriptions() {
        #expect(
            DesktopClientError.requestFailed(statusCode: 500, message: "boom").localizedDescription
                == "The desktop service returned HTTP 500: boom"
        )

        #expect(
            DesktopClientError.requestFailed(statusCode: 404, message: "").localizedDescription
                == "The desktop service returned HTTP 404."
        )
    }

    @Test
    func testMigrationsCreateReadableTables() throws {
        let database = try appDatabase()

        let workspaces = try database.read { db in
            try Workspace.fetchCount(db)
        }

        #expect(workspaces == 0)
    }

    @Test
    func testWorkspaceStateDecodingKeepsKnownAndUnknownValues() throws {
        let archived = try JSONDecoder().decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "state": "archived"
                }
                """.utf8
            )
        )

        #expect(archived.state == .archived)

        let future = try JSONDecoder().decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-2",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "state": "waiting_on_moonlight"
                }
                """.utf8
            )
        )

        #expect(future.state?.rawValue == "waiting_on_moonlight")
    }
}
