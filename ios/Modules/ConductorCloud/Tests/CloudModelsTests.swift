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
    @Test("API status values and both API date formats decode losslessly")
    func apiStatusAndDateFormats() throws {
        let workspaceStatus = try JSONDecoder.cloud.decode(
            CloudWorkspaceStatusResponse.self,
            from: Data(
                #"""
                {
                  "workspaceId": "workspace-1",
                  "status": "pausing",
                  "lifecycleStep": "snapshotting_v2",
                  "updatedAt": "2026-07-24T12:34:56.123Z"
                }
                """#.utf8
            )
        )
        let sessionStatus = try JSONDecoder.cloud.decode(
            CloudSessionStatusResponse.self,
            from: Data(
                #"""
                {
                  "workspaceId": "workspace-1",
                  "sessionId": "session-1",
                  "status": "waiting_for_input",
                  "updatedAt": "2026-07-24 15:24:17.562275+00"
                }
                """#.utf8
            )
        )

        #expect(workspaceStatus.status.rawValue == "pausing")
        #expect(workspaceStatus.lifecycleStep?.rawValue == "snapshotting_v2")
        #expect(sessionStatus.status.rawValue == "waiting_for_input")
    }

    @Test("The real transcript envelope remains lossless")
    func transcriptEnvelope() throws {
        let messages = try JSONDecoder.cloud.decode(
            CloudPage<CloudTranscriptMessage>.self,
            from: Data(
                #"""
                {
                  "data": [
                    {
                      "id": "user-1",
                      "sessionId": "session-1",
                      "sessionIndex": 1,
                      "type": "userMessage",
                      "content": {
                        "type": "userMessage",
                        "id": "user-item-1",
                        "message": "Run the tests.",
                        "state": "sent",
                        "turnId": "turn-1",
                        "config": {"model": "gpt-5.6-sol"},
                        "senderId": "user-1"
                      },
                      "receivedAt": "2026-07-24 15:24:17.562275+00"
                    },
                    {
                      "id": "agent-1",
                      "sessionId": "session-1",
                      "sessionIndex": 2,
                      "type": "agent",
                      "content": {
                        "type": "agent",
                        "eventId": "event-1",
                        "turnId": "turn-1",
                        "userMessageId": "user-item-1",
                        "rawPayload": {
                          "thread_id": "thread-1",
                          "event": {
                            "type": "item.completed",
                            "item": {
                              "id": "assistant-item-1",
                              "type": "agentMessage",
                              "text": "All tests passed."
                            }
                          }
                        }
                      },
                      "receivedAt": "2026-07-24 15:24:18.000001+00"
                    }
                  ],
                  "offset": 0,
                  "hasMore": false
                }
                """#.utf8
            )
        ).data

        #expect(messages.map(\.type.rawValue) == ["userMessage", "agent"])

        for message in messages {
            let encoded = try JSONEncoder().encode(message.content)
            let decoded = try JSONDecoder().decode(CloudJSONValue.self, from: encoded)
            #expect(decoded == message.content)
        }
    }

    @Test("Transcript normalization deduplicates server IDs and preserves stable session order")
    func transcriptOrderingAndDeduplication() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z"))
        let messages = [
            transcriptMessage(id: "second", index: 2, content: "old", date: date),
            transcriptMessage(id: "first", index: 1, content: "first", date: date),
            transcriptMessage(id: "second", index: 2, content: "new", date: date),
            transcriptMessage(id: "third", index: 2, content: "third", date: date),
        ]

        let normalized = CloudTranscriptMessage.normalized(messages)

        #expect(normalized.map(\.id) == ["first", "second", "third"])
        #expect(normalized[1].content == .string("new"))
    }

    private func transcriptMessage(
        id: String,
        index: Double,
        content: String,
        date: Date
    ) -> CloudTranscriptMessage {
        CloudTranscriptMessage(
            id: id,
            sessionID: "session-1",
            sessionIndex: index,
            type: .init(rawValue: "assistant"),
            content: .string(content),
            receivedAt: date
        )
    }
}
