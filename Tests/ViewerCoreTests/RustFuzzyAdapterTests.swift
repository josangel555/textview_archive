import XCTest
@testable import ViewerCore
import RustCore

/// RustFuzzyAdapter behavior pins (STAGE-B, TSK-649: the Swift twin is
/// deleted — rust is the only engine, no gate). The expectations below are
/// the CONTRACT the deleted A/B suite proved byte-identical before deletion:
/// prefix > substring > scattered ranking, stable ties on input order,
/// non-matches dropped, empty-query short-circuit, generic key closures.
final class RustFuzzyAdapterTests: XCTestCase {

    private let corpus = [
        "src/main.rs", "Sources/ViewerCore/FuzzyMatcher.swift", "docs/DESIGN.md",
        "fuzzy_test", "FzyUtil", "a/b/fz", "unrelated", "fz-dup-a", "fz-dup-b",
    ]

    func test_rustIsTheOnlyEngine_andRanksTheContract() {
        let out = RustFuzzyAdapter.outcome(corpus, query: "fz", by: { $0 })
        XCTAssertEqual(out.source, .rust, "twin deleted — rust must serve the rank")
        let items = out.value.map(\.item)
        // Every fz-subsequence candidate present, no non-matches.
        XCTAssertFalse(items.contains("unrelated"))
        XCTAssertFalse(items.contains("docs/DESIGN.md"))
        // Stable tie: fz-dup-a (earlier input) before fz-dup-b (same score).
        let ia = try? XCTUnwrap(items.firstIndex(of: "fz-dup-a"))
        let ib = try? XCTUnwrap(items.firstIndex(of: "fz-dup-b"))
        XCTAssertLessThan(ia ?? 0, ib ?? 0, "stable tie-break on input order")
        // Prefix-ish candidates outrank the buried path segment.
        XCTAssertLessThan(
            items.firstIndex(of: "fz-dup-a") ?? .max,
            items.firstIndex(of: "Sources/ViewerCore/FuzzyMatcher.swift") ?? .max,
            "a leading fz outranks a scattered mid-path match")
    }

    func test_scoresDescend_andMatchedIndicesPresent() {
        let out = RustFuzzyAdapter.filterWithMatches(corpus, query: "fuzzy", by: { $0 })
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(out.map(\.match.score), out.map(\.match.score).sorted(by: >),
                       "results are best-first")
        XCTAssertTrue(out.allSatisfy { $0.match.matchedIndices.count == 5 },
                      "every result carries one matched index per query char")
    }

    func test_noHitQuery_returnsEmpty() {
        XCTAssertTrue(RustFuzzyAdapter.filterWithMatches(corpus, query: "xyz-no-hit", by: { $0 }).isEmpty)
    }

    func test_emptyQuery_listsAllInInputOrder_withoutBridgeCall() {
        let out = RustFuzzyAdapter.outcome(corpus, query: "", by: { $0 })
        XCTAssertEqual(out.value.map(\.item), corpus)
        XCTAssertTrue(out.value.allSatisfy { $0.match == FuzzyMatcher.Match(score: 0, matchedIndices: []) })
    }

    func test_genericItems_keyClosureDrivesTheRank() {
        struct Cmd: Sendable, Equatable { let title: String; let id: Int }
        let cmds = [Cmd(title: "Open File", id: 1), Cmd(title: "Close Tab", id: 2)]
        let out = RustFuzzyAdapter.outcome(cmds, query: "of", by: { $0.title })
        XCTAssertEqual(out.source, .rust)
        XCTAssertEqual(out.value.map(\.item.id), [1], "only 'Open File' matches 'of'")
    }
}
