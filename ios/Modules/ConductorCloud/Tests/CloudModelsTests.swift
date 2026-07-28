//
//  CloudModelsTests.swift
//  ConductorCloudTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

@testable import ConductorCloud
import Foundation
import Testing

struct CloudModelsTests {
    @Test("Cloud session and transcript transport preserve unknown values")
    func sessionAndTranscriptValues() throws {
        let sessionStatus = try JSONDecoder.cloud.decode(
            CloudSessionStatusResponse.self,
            from: Data(
                #"""
                {
                  "workspaceId": "workspace",
                  "sessionId": "session",
                  "status": "waiting-for-future",
                  "updatedAt": "2026-07-24T12:00:00Z"
                }
                """#.utf8
            )
        )
        let transcript = try JSONDecoder.cloud.decode(
            CloudTranscriptMessage.self,
            from: Data(
                #"""
                {
                  "id": "event",
                  "sessionId": "session",
                  "sessionIndex": 1,
                  "type": "future-event",
                  "content": {
                    "nested": [true, 42, null]
                  },
                  "receivedAt": "2026-07-24T12:00:00Z"
                }
                """#.utf8
            )
        )

        #expect(sessionStatus.status.rawValue == "waiting-for-future")
        #expect(transcript.type.rawValue == "future-event")
        #expect(
            transcript.content
                == .object([
                    "nested": .array([
                        .bool(true),
                        .integer(42),
                        .null,
                    ]),
                ])
        )
    }

    @Test("Unknown server-owned status values decode without being discarded")
    func unknownStatusValues() throws {
        let response = try JSONDecoder.cloud.decode(
            CloudWorkspaceStatusResponse.self,
            from: Data(
                #"""
                {
                  "workspaceId": "workspace-1",
                  "status": "pausing"
                }
                """#.utf8
            )
        )

        #expect(response.status.rawValue == "pausing")
    }

    @Test("Fractional timestamps and pagination envelopes decode from API responses")
    func fractionalTimestampsAndPagination() throws {
        let page = try JSONDecoder.cloud.decode(
            CloudPage<CloudWorkspace>.self,
            from: Data(
                #"""
                {
                  "data": [
                    {
                      "id": "workspace-1",
                      "name": "Cloud workspace",
                      "createdAt": "2026-07-24 15:24:17.562275+00",
                      "lastActivityAt": "2026-07-24T15:25:18.000001Z"
                    }
                  ],
                  "offset": 50,
                  "hasMore": true
                }
                """#.utf8
            )
        )

        #expect(page.offset == 50)
        #expect(page.hasMore)
        #expect(page.data.first?.id == "workspace-1")
        #expect(page.data.first?.lastActivityAt != nil)
    }

    @Test("Authentication identity preserves optional organization and key metadata")
    func authenticationIdentity() throws {
        let identity = try JSONDecoder.cloud.decode(
            CloudIdentity.self,
            from: Data(
                #"""
                {
                  "userId": "user-1",
                  "email": "user@example.test",
                  "organizationId": "organization-1",
                  "authMethod": "api-key",
                  "apiKey": {"id": "key-1"}
                }
                """#.utf8
            )
        )

        #expect(identity.userID == "user-1")
        #expect(identity.organizationID == "organization-1")
        #expect(identity.authMethod == .apiKey)
        #expect(identity.apiKey?.id == "key-1")
    }
}
