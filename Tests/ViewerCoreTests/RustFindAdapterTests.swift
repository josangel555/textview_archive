import XCTest
@testable import ViewerCore
import RustCore

/// RustFindAdapter routing (TSK-645): gate OFF → Swift, gate ON → Rust,
/// ICU-only pattern → Swift fallback WITH the ICU result, invalid pattern
/// → `[]`. Gate state is injected via `environment`/`defaults` so nothing
/// process-global is touched (same harness shape as RustCoreFallbackTests).
final class RustFindAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_FIND": "1"]
    private let text = "hello world\nsecond hello line\r\nthird HELLO"

    private func swiftResults(_ query: FindQuery) -> [FindMatch] {
        (try? FindEngine().search(in: text, query: query)) ?? []
    }

    func test_gateOff_runsSwift_withoutCallingRust() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 round 3).
        let q = FindQuery(pattern: "hello")
        let out = RustFindAdapter.outcome(in: text, query: q,
                                          environment: ["MDV_RUST_FIND": "0"])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertEqual(out.value, swiftResults(q))
        XCTAssertFalse(out.value.isEmpty)
    }

    func test_gateOn_runsRust_resultsMatchSwiftOnCommonSubset() {
        // Literal + case-insensitive + multi-line/CRLF accounting — the
        // hazards the engine port pinned. Byte-identical FindMatch values
        // prove the adapter's CoreFindMatch→FindMatch mapping too.
        for q in [
            FindQuery(pattern: "hello"),
            FindQuery(pattern: "hello", caseSensitive: true),
            FindQuery(pattern: "hello", wholeWord: true),
            FindQuery(pattern: #"h\w+o"#, kind: .regex),
        ] {
            let out = RustFindAdapter.outcome(in: text, query: q, environment: gateOn)
            XCTAssertEqual(out.source, .rust, "gate ON must route rust for \(q.pattern)")
            XCTAssertEqual(out.value, swiftResults(q),
                           "rust/swift diverged for \(q.pattern)")
        }
    }

    func test_gateOn_icuOnlyPattern_fallsBackToSwiftWithICUResult() {
        // Lookbehind: regex-lite rejects (→ .invalidPattern), ICU runs it.
        // The fallback must surface the ICU matches, not an empty set.
        let q = FindQuery(pattern: "(?<=h)e", kind: .regex)
        let out = RustFindAdapter.outcome(in: text, query: q, environment: gateOn)
        XCTAssertEqual(out.source, .swiftFallback)
        XCTAssertEqual(out.value, swiftResults(q))
        XCTAssertFalse(out.value.isEmpty, "ICU handles lookbehind — result must be non-empty")
    }

    func test_gateOn_invalidPattern_yieldsEmpty_notAThrow() {
        let q = FindQuery(pattern: "(unclosed", kind: .regex)
        let out = RustFindAdapter.outcome(in: text, query: q, environment: gateOn)
        XCTAssertEqual(out.source, .swiftFallback, "rust rejects → falls back")
        XCTAssertEqual(out.value, [], "both engines reject → empty, never a throw")
    }

    func test_emptyPattern_isEmptyBothWays() {
        let q = FindQuery(pattern: "")
        XCTAssertEqual(RustFindAdapter.outcome(in: text, query: q, environment: [:]).value, [])
        XCTAssertEqual(RustFindAdapter.outcome(in: text, query: q, environment: gateOn).value, [])
    }
}
