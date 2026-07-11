import ConductorData
import CustomDump
import Foundation
import IssueReporting
import Testing

struct WorkspaceTests {
    @Test("Workspace activity decodes with the workspace")
    func activityDecoding() throws {
        let workspace = try JSONDecoder.conductor.decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "is_working": true
                }
                """.utf8
            )
        )

        #expect(workspace.id == "workspace-1")
        #expect(workspace.isWorking)
    }

    @Test("Workspace state decoding keeps known and unknown values")
    func stateDecodingKeepsKnownAndUnknownValues() throws {
        let archived = try JSONDecoder.conductor.decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-1",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "is_working": false,
                  "state": "archived"
                }
                """.utf8
            )
        )

        #expect(archived.state == .archived)

        let future = try JSONDecoder.conductor.decode(
            Workspace.self,
            from: Data(
                """
                {
                  "id": "workspace-2",
                  "created_at": "2026-07-09 00:00:00",
                  "updated_at": "2026-07-09 00:00:00",
                  "is_working": false,
                  "state": "waiting_on_moonlight"
                }
                """.utf8
            )
        )

        #expect(future.state?.rawValue == "waiting_on_moonlight")
    }

    @Test("Workspace status prefers manual status, then derived status")
    func statusResolution() {
        let workspaces = [
            Workspace.preview(derivedStatus: "in-progress", manualStatus: "done"),
            Workspace.preview(derivedStatus: "in-review", manualStatus: nil),
            Workspace.preview(derivedStatus: "backlog", manualStatus: ""),
            Workspace.preview(derivedStatus: "in-progress", manualStatus: "waiting-on-user"),
        ]

        expectNoDifference(
            workspaces.map(\.status),
            [.done, .inReview, .backlog, Workspace.Status(rawValue: "waiting-on-user")]
        )
        expectNoDifference(workspaces.last?.status.title, "waiting-on-user")
    }

    @Test("Workspace status reports missing source data and falls back to in progress")
    func missingStatusReportsIssue() {
        withExpectedIssue {
            #expect(Workspace.preview(derivedStatus: nil, manualStatus: nil).status == .inProgress)
        }
    }

    @Test("Workspace display branch names use Conductor sentence case")
    func displayBranchNameFormatsConductorNames() {
        let workspace = Workspace.preview(branch: "foo-baz_qux")

        #expect(workspace.displayBranchName == "Foo baz qux")
    }

    @Test("Workspace display branch names use the first available name")
    func displayBranchNameFallsBackThroughAvailableNames() {
        let workspace = Workspace.preview(
            directoryName: "also-unused",
            placeholderBranchName: "stuttgart-v1",
            workspaceName: "unused-name"
        )

        #expect(workspace.displayBranchName == "Stuttgart v1")
    }
}
