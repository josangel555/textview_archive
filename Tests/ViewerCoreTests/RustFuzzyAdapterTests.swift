import XCTest
@testable import ViewerCore
import RustCore

/// RustFuzzyAdapter routing (TSK-646): gate OFF → Swift, gate ON → Rust
/// with results matching the Swift `filterWithMatches` contract exactly on
/// ASCII (scores, ordering incl. stable ties, matched indices), empty
/// query short-circuits. Gate state injected via `environment`.
final class RustFuzzyAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_FUZZY": "1"]
    private let corpus = [
        "src/main.rs", "Sources/ViewerCore/FuzzyMatcher.swift", "docs/DESIGN.md",
        "fuzzy_test", "FzyUtil", "a/b/fz", "unrelated", "fz-dup-a", "fz-dup-b",
    ]

    private func swiftResults(_ query: String) -> [(item: String, match: FuzzyMatcher.Match)] {
        FuzzyMatcher.filterWithMatches(corpus, query: query) { $0 }
    }

    private func assertSame(
        _ a: [(item: String, match: FuzzyMatcher.Match)],
        _ b: [(item: String, match: FuzzyMatcher.Match)],
        _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.map(\.item), b.map(\.item), "items diverged: \(context)",
                       file: file, line: line)
        XCTAssertEqual(a.map(\.match), b.map(\.match), "matches diverged: \(context)",
                       file: file, line: line)
    }

    func test_gateOff_runsSwift() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 round 3).
        let out = RustFuzzyAdapter.outcome(corpus, query: "fz", by: { $0 },
                                           environment: ["MDV_RUST_FUZZY": "0"])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        assertSame(out.value, swiftResults("fz"), "gate off")
    }

    func test_gateOn_runsRust_matchesSwiftContract() {
        // Boundary/consecutive/prefix scoring, stable ties (fz-dup-a before
        // fz-dup-b), non-matches dropped — the whole batch contract.
        for query in ["fz", "fuzzy", "main", "xyz-no-hit", "f"] {
            let out = RustFuzzyAdapter.outcome(corpus, query: query, by: { $0 }, environment: gateOn)
            XCTAssertEqual(out.source, .rust, "gate ON must route rust for '\(query)'")
            assertSame(out.value, swiftResults(query), "query '\(query)'")
        }
    }

    func test_emptyQuery_listsAllInInputOrder_withoutBridgeCall() {
        let out = RustFuzzyAdapter.outcome(corpus, query: "", by: { $0 }, environment: gateOn)
        XCTAssertEqual(out.value.map(\.item), corpus)
        XCTAssertTrue(out.value.allSatisfy { $0.match == FuzzyMatcher.Match(score: 0, matchedIndices: []) })
    }

    func test_genericItems_keyClosureDrivesTheRank() {
        struct Cmd: Sendable, Equatable { let title: String; let id: Int }
        let cmds = [Cmd(title: "Open File", id: 1), Cmd(title: "Close Tab", id: 2)]
        let out = RustFuzzyAdapter.outcome(cmds, query: "of", by: { $0.title }, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        XCTAssertEqual(out.value.map(\.item.id), [1], "only 'Open File' matches 'of'")
    }
}
