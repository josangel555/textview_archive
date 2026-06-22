import XCTest
@testable import ViewerCore

/// Differential parity fuzz for the in-buffer find engine — Swift `FindEngine` vs the
/// Rust port (`RustFindAdapter`, A/B'd by the `.find` gate env `MDV_RUST_FIND`) over
/// random ASCII text/patterns, across literal search with case-sensitivity and
/// whole-word toggled. Compares the full `[FindMatch]` (range + 1-based line/column).
/// Scoped to `.literal`: regex parity is NOT expected (Swift NSRegularExpression vs
/// the Rust regex engine are different implementations). Completes the systematic
/// dual-twin parity coverage (formula found 4 bugs; fuzzy + find verify clean).
final class FindDifferentialFuzzTests: XCTestCase {
    private struct Xorshift {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    // Letters (mixed case for case-folding), spaces + newlines (line/column + word
    // boundaries), '.' and a repeated 'o' (overlap-prone) — ASCII only.
    private let alphabet = Array("abAB \n.foo")

    private func randomText(_ rng: inout Xorshift, _ maxLen: Int) -> String {
        let n = rng.int(1, maxLen)
        var s = ""
        for _ in 0..<n { s.append(alphabet[rng.int(0, alphabet.count - 1)]) }
        return s
    }

    func test_swift_rust_find_literal_parity() throws {
        for seed in UInt64(1)...UInt64(60) {
            var rng = Xorshift(s: (seed &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 { // 60 seeds × 25 = 1500 random searches
                let text = randomText(&rng, 40)
                let pattern = randomText(&rng, 3) // short → frequent matches
                let query = FindQuery(pattern: pattern, kind: .literal,
                                      caseSensitive: rng.int(0, 1) == 0,
                                      wholeWord: rng.int(0, 1) == 0)
                let rust = RustFindAdapter.outcome(in: text, query: query,
                                                   environment: ["MDV_RUST_FIND": "1"]).value
                let swift = RustFindAdapter.outcome(in: text, query: query,
                                                    environment: ["MDV_RUST_FIND": "0"]).value
                XCTAssertEqual(rust, swift,
                    "find parity diverged: pattern=\(pattern.debugDescription) cs=\(query.caseSensitive) ww=\(query.wholeWord) text=\(text.debugDescription)")
            }
        }
    }

    /// Teeth: prove the MDV_RUST_FIND env A/B genuinely switches engines (else a green
    /// parity result could be both paths running the same engine — a false green).
    func test_find_AB_toggle_actually_switches_engines() {
        let query = FindQuery(pattern: "a", kind: .literal, caseSensitive: true, wholeWord: false)
        let rust = RustFindAdapter.outcome(in: "abc a", query: query,
                                           environment: ["MDV_RUST_FIND": "1"])
        let swift = RustFindAdapter.outcome(in: "abc a", query: query,
                                            environment: ["MDV_RUST_FIND": "0"])
        XCTAssertEqual(rust.source, .rust, "gate-on must run the Rust engine")
        XCTAssertEqual(swift.source, .swiftBecauseGateOff, "gate-off must run Swift")
    }
}
