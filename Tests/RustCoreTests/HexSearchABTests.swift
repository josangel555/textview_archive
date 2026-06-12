import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_hex_search` (via `mdvCoreHexSearch`) vs
/// the SHIPPING Swift `HexSearchEngine.search`, over a corpus spanning both
/// modes, the hex-parse forms (spaced / packed / mixed), invalid queries
/// (odd-length, non-hex), non-overlapping multi-match, no-match, and empty.
/// Offsets must match exactly. Forces the Rust path directly (no gate).
final class HexSearchABTests: XCTestCase {

    private func k(_ m: HexSearchMode) -> HexSearchKind {
        switch m { case .hex: return .hex; case .ascii: return .ascii }
    }

    /// Each case: a byte buffer + query + mode. Both impls must agree.
    private func cases() -> [(data: [UInt8], query: String, mode: HexSearchMode)] {
        [
            ([0x00, 0xde, 0xad, 0xde, 0xad], "dead", .hex),       // two matches
            ([0xAA, 0xAA, 0xAA], "aa aa", .hex),                  // non-overlapping → [0]
            ([0xAA, 0xAA, 0xAA], "AA", .hex),                     // single byte → [0,1,2]
            ([0xde, 0xad, 0xbe, 0xef], "de adbe ef", .hex),       // mixed spacing
            ([0xde, 0xad], "de a", .hex),                         // odd-length token → invalid → []
            ([0xde, 0xad], "zz", .hex),                           // non-hex → invalid → []
            ([0xde, 0xad], "", .hex),                             // empty query → []
            (Array("hello hex hello".utf8), "hello", .ascii),     // ascii two matches
            (Array("hello".utf8), "xyz", .ascii),                 // ascii no match
            (Array("hello".utf8), "", .ascii),                    // ascii empty → []
            ([], "dead", .hex),                                   // empty data
            ([0x01, 0x02, 0x03], "01 02 03 04", .hex),            // pattern longer than data → []
            (Array(repeating: 0x41, count: 100), "4141", .hex),   // dense non-overlapping
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for c in cases() {
            let data = Data(c.data)
            let swift = HexSearchEngine.search(c.query, mode: c.mode, in: data)
            let rust = try mdvCoreHexSearch(data: data, query: c.query, mode: k(c.mode))
            XCTAssertEqual(rust, swift,
                           "parity mismatch for query=\(c.query.debugDescription) mode=\(c.mode) over \(c.data.count) bytes")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 round 2).
        let data = Data([0xde, 0xad, 0xde, 0xad])
        let o = RustHexSearchAdapter.outcome(
            "dead", mode: .hex, in: data, environment: ["MDV_RUST_HEXSEARCH": "0"])
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, HexSearchEngine.search("dead", mode: .hex, in: data))
    }

    func test_shippedDefault_routesRust_andMatchesSwift() {
        let data = Data([0xde, 0xad, 0xde, 0xad])
        let o = RustHexSearchAdapter.outcome("dead", mode: .hex, in: data, environment: [:])
        XCTAssertEqual(o.source, .rust, "hexSearch ships default-ON (soak round 2)")
        XCTAssertEqual(o.value, HexSearchEngine.search("dead", mode: .hex, in: data))
    }
}
