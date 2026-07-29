//
//  RawUTF8Key.swift
//  SharedConductorData
//
//  Created by Gannon Prudomme on 7/29/26.
//

/// A byte-exact comparison key for opaque identifiers and endpoint identities.
///
/// Swift considers canonically equivalent Unicode strings equal. Conductor identifiers are opaque,
/// so server ordering/diffing and mobile resume-key validation must instead preserve
/// the exact UTF-8 bytes received on the wire.
public struct RawUTF8Key: Hashable, Comparable, Sendable {
    private let bytes: [UInt8]

    /// Captures the string's current UTF-8 representation without Unicode normalization.
    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    /// Provides the protocol's deterministic raw-byte tie-break ordering.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}
