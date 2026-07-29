//
//  CloudCanonicalIDTests.swift
//  ConductorMobileDataTests
//
//  Created by Gannon Prudomme on 7/28/26.
//

@testable import ConductorMobileData
import Testing

struct CloudCanonicalIDTests {
    @Test("Cloud session IDs expose the original desktop session ID")
    func remoteSessionID() {
        let canonicalID = CloudCanonicalID.session(
            accountID: "account:/+",
            remoteSessionID: "session:/+"
        )

        #expect(
            CloudCanonicalID.remoteSessionID(from: canonicalID)
                == "session:/+"
        )
        #expect(CloudCanonicalID.remoteSessionID(from: "session:/+") == nil)
        #expect(CloudCanonicalID.remoteSessionID(from: "cloud-session:not-base64:!") == nil)
    }
}
