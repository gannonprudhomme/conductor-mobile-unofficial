//
//  MessageDeliveryTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/24/26.
//

import Foundation
import SharedConductorData
import Testing

struct MessageDeliveryTests {
    @Test("Message delivery request and response use the shared wire contract")
    func wireContract() throws {
        let attemptID = UUID(1)
        let request = MessageSendRequest(
            attemptID: attemptID,
            isFastModeEnabled: true,
            message: "Run the tests.",
            model: "gpt-5.6-terra",
            mode: .sent,
            reasoningEffort: .ultra
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(
            String(decoding: try encoder.encode(request), as: UTF8.self)
                == #"{"attemptId":"00000000-0000-0000-0000-000000000001","fast_mode":true,"message":"Run the tests.","mode":"sent","model":"gpt-5.6-terra","reasoning_effort":"ultra"}"#
        )

        let response = MessageSendResponse(
            attemptID: attemptID,
            result: .accepted(messageID: "message-1")
        )
        #expect(
            String(decoding: try encoder.encode(response), as: UTF8.self)
                == #"{"attemptId":"00000000-0000-0000-0000-000000000001","result":{"messageId":"message-1","type":"accepted"}}"#
        )
        #expect(
            try JSONDecoder().decode(
                MessageSendResponse.self,
                from: Data(
                    #"{"attemptId":"00000000-0000-0000-0000-000000000001","result":{"messageId":"message-1","type":"accepted"}}"#.utf8
                )
            ) == response
        )
    }

    @Test(
        "Delivery responses reject empty identifiers and reasons",
        arguments: [
            #"{"type":"accepted","messageId":""}"#,
            #"{"type":"rejected","reason":""}"#,
            #"{"type":"unknown","reason":""}"#,
        ]
    )
    func invalidResult(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                MessageDeliveryResult.self,
                from: Data(json.utf8)
            )
        }
    }
}
