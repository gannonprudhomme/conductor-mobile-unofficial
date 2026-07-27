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
            model: "gpt-5.6-terra"
        )
        let requestObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request)
            ) as? [String: Any]
        )
        #expect(requestObject["attemptId"] as? String == attemptID.uuidString)
        #expect(requestObject["fast_mode"] as? Bool == true)

        let response = MessageSendResponse(
            attemptID: attemptID,
            result: .accepted(messageID: "message-1")
        )
        #expect(
            try JSONDecoder().decode(
                MessageSendResponse.self,
                from: JSONEncoder().encode(response)
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
