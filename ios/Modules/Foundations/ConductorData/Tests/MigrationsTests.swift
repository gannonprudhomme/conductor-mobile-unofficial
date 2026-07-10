import ConductorData
import Testing

struct MigrationsTests {
    @Test("Migrations create readable tables")
    func createReadableTables() throws {
        let database = try appDatabase()

        let workspaces = try database.read { db in
            try Workspace.fetchCount(db)
        }
        let sessions = try database.read { db in
            try Session.fetchCount(db)
        }

        #expect(workspaces == 0)
        #expect(sessions == 0)
    }
}
