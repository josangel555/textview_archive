import XCTest
@testable import ViewerCore

final class FuzzyMatcherTests: XCTestCase {

    func test_emptyQueryMatches() {
        let m = FuzzyMatcher.match("", against: "anything")
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.score, 0)
    }

    func test_simpleMatch() {
        let m = FuzzyMatcher.match("rdm", against: "README.md")
        XCTAssertNotNil(m)
    }

    func test_caseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("RDM", against: "readme.md"))
        XCTAssertNotNil(FuzzyMatcher.match("rdm", against: "README.MD"))
    }

    func test_orderMatters() {
        XCTAssertNil(FuzzyMatcher.match("mdr", against: "README"))
    }

    func test_noMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("xyz", against: "README.md"))
    }

    func test_consecutiveScoresHigherThanScattered() {
        let consec = FuzzyMatcher.match("rea", against: "readme")
        let scattered = FuzzyMatcher.match("rea", against: "rxexa")
        XCTAssertGreaterThan(consec?.score ?? 0, scattered?.score ?? 0)
    }

    func test_prefixScoresHigherThanMidstring() {
        let prefix = FuzzyMatcher.match("read", against: "README.md")
        let midstring = FuzzyMatcher.match("read", against: "foo/readme.md")
        // The prefix one starts at index 0 — should score higher.
        XCTAssertGreaterThan(prefix?.score ?? 0, midstring?.score ?? 0)
    }

    func test_wordBoundaryBonus() {
        // "rm" matches both "README.md" (R after start, m after .) and "wormrm"
        // The first has stronger boundary bonuses.
        let withBoundaries = FuzzyMatcher.match("rm", against: "README.md")
        let withoutBoundaries = FuzzyMatcher.match("rm", against: "wormrm")
        XCTAssertGreaterThan(withBoundaries?.score ?? 0, withoutBoundaries?.score ?? 0)
    }

    func test_returnsMatchedIndices() {
        let m = FuzzyMatcher.match("rdm", against: "README.md")
        XCTAssertEqual(m?.matchedIndices.count, 3)
    }

    // MARK: filter()

    func test_filter_emptyQueryReturnsAll() {
        let result = FuzzyMatcher.filter(["a.md", "b.md", "c.txt"], query: "") { $0 }
        XCTAssertEqual(result.count, 3)
    }

    func test_filter_sortsByScore() {
        let items = ["far/foo/readme.md", "README.md", "weird/raedm.md"]
        let result = FuzzyMatcher.filter(items, query: "readme") { $0 }
        XCTAssertEqual(result.first, "README.md", "best match should be first")
    }

    func test_filter_excludesNonMatches() {
        let items = ["alpha.md", "beta.md", "gamma.md"]
        let result = FuzzyMatcher.filter(items, query: "zzz") { $0 }
        XCTAssertEqual(result, [])
    }

    // T4 / B13 / A10: ties must preserve input order so palette doesn't
    // shuffle on every keystroke.
    func test_filter_tiesPreserveInputOrder() {
        // Three items with names of identical length and matching pattern
        // produce identical scores; the input order is the tie-break.
        let items = ["zzz_one.md", "zzz_two.md", "zzz_six.md"]
        let result = FuzzyMatcher.filter(items, query: "zzz") { $0 }
        XCTAssertEqual(result, items)
    }

    func test_filter_tieStability_acrossRepeatedCalls() {
        let items = (1...20).map { "f\($0).md" }
        let q = "f"
        let r1 = FuzzyMatcher.filter(items, query: q) { $0 }
        let r2 = FuzzyMatcher.filter(items, query: q) { $0 }
        XCTAssertEqual(r1, r2)
    }
}
