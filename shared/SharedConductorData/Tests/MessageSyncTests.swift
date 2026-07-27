//
//  MessageSyncTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation
import SharedConductorData
import Testing

struct MessageSyncTests {
    @Test("Message sync envelopes round-trip fingerprints, upserts, and deletions")
    func codableRoundTrip() throws {
        let message = Message(
            id: "message-1",
            sessionID: "session-1",
            role: .assistant,
            content: "Done.",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let request = MessageSyncRequest(
            fingerprints: [message.id: Data([0, 1, 2, 3])]
        )
        let response = MessageSyncResponse(
            messages: [message],
            deletedMessageIDs: ["message-2"]
        )

        let requestData = try JSONEncoder.conductor.encode(request)
        let responseData = try JSONEncoder.conductor.encode(response)

        #expect(String(decoding: requestData, as: UTF8.self).contains("AAECAw=="))
        #expect(
            try JSONDecoder.conductor.decode(MessageSyncRequest.self, from: requestData)
                == request
        )
        #expect(
            try JSONDecoder.conductor.decode(MessageSyncResponse.self, from: responseData)
                == response
        )
    }

    @Test("The response also decodes the legacy desktop message array")
    func legacyMessageArray() throws {
        let message = Message(
            id: "message-1",
            sessionID: "session-1",
            role: .user,
            content: "Hello.",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder.conductor.encode([message])

        let response = try JSONDecoder.conductor.decode(
            MessageSyncResponse.self,
            from: data
        )

        #expect(
            response == MessageSyncResponse(
                messages: [message],
                deletedMessageIDs: []
            )
        )
    }
}
