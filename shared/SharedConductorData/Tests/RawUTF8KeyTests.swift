//
//  RawUTF8KeyTests.swift
//  SharedConductorDataTests
//
//  Created by Gannon Prudomme on 7/29/26.
//

@testable import SharedConductorData
import Testing

struct RawUTF8KeyTests {
    @Test("Identifiers compare and hash by their unnormalized UTF-8 bytes")
    func byteExactIdentity() {
        let composed = RawUTF8Key("message-\u{e9}")
        let decomposed = RawUTF8Key("message-e\u{301}")

        #expect(composed != decomposed)
        #expect(decomposed < composed)
        #expect(Set([composed, decomposed]).count == 2)
    }
}
