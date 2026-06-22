import XCTest
@testable import ViewerCore

/// Differential parity fuzz for the fuzzy matcher — Swift `FuzzyMatcher` vs the Rust
/// port (`RustFuzzyAdapter`, A/B'd by the `.fuzzy` gate env `MDV_RUST_FUZZY`). The
/// adapter documents `matchedIndices` as ASCII-identical (scalar vs grapheme offsets)
/// but claims SCORES + ORDERING are EXACT (the engine port "pins the scoring table +
/// stable ties"). This fuzzes that claim over random ASCII queries + candidate lists,
/// including the separator chars (`/ _ - .`) that drive the word-boundary score
/// bonuses — the algorithm-heavy edges most likely to diverge. Applies the same
/// differential-fuzz method that found four real formula port bugs (TSK-1218..1221)
/// to a second dual-twin engine.
final class FuzzyDifferentialFuzzTests: XCTestCase {
    private struct Xorshift {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    // Letters (mixed case), separators (boundary bonuses), digits — ASCII only so
    // matchedIndices stay aligned and only the scoring logic is under test.
    private let alphabet = Array("abcdefgABCDEFG/_-.0123")

    private func randomString(_ rng: inout Xorshift, _ maxLen: Int) -> String {
        let n = rng.int(1, maxLen)
        var s = ""
        for _ in 0..<n { s.append(alphabet[rng.int(0, alphabet.count - 1)]) }
        return s
    }

    func test_swift_rust_fuzzy_score_and_order_parity() throws {
        for seed in UInt64(1)...UInt64(60) {
            var rng = Xorshift(s: (seed &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 60 seeds × 25 = 1500 random rankings
                let query = randomString(&rng, 3) // short → many candidates match
                let candidates = (0..<rng.int(3, 8)).map { _ in randomString(&rng, 12) }
                let rust = RustFuzzyAdapter.outcome(candidates, query: query, by: { $0 },
                                                    environment: ["MDV_RUST_FUZZY": "1"]).value
                let swift = RustFuzzyAdapter.outcome(candidates, query: query, by: { $0 },
                                                     environment: ["MDV_RUST_FUZZY": "0"]).value
                // Compare item + score in RANKED ORDER — captures both the scoring
                // table and the stable-tie ordering (the claimed-exact contract).
                let rustKey = rust.map { "\($0.item)=\($0.match.score)" }
                let swiftKey = swift.map { "\($0.item)=\($0.match.score)" }
                XCTAssertEqual(rustKey, swiftKey,
                    "fuzzy score/order parity diverged: query=\(query.debugDescription) candidates=\(candidates)")
            }
        }
    }

    /// Teeth for the parity fuzz above: prove the `MDV_RUST_FUZZY` env A/B genuinely
    /// toggles engines, so a green parity result reflects Rust==Swift and not both
    /// running the same path (a silent false green).
    func test_fuzzy_AB_toggle_actually_switches_engines() {
        let items = ["foobar", "baz", "fzbr"]
        let rust = RustFuzzyAdapter.outcome(items, query: "fb", by: { $0 },
                                            environment: ["MDV_RUST_FUZZY": "1"])
        let swift = RustFuzzyAdapter.outcome(items, query: "fb", by: { $0 },
                                             environment: ["MDV_RUST_FUZZY": "0"])
        XCTAssertEqual(rust.source, .rust, "gate-on must run the Rust engine")
        XCTAssertEqual(swift.source, .swiftBecauseGateOff, "gate-off must run Swift")
    }
}
