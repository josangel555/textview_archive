import XCTest
@testable import ViewerCore

/// TSK-727 slice 4 (`@`): heading ranking for the palette symbol-jump. The
/// palette list/jump render is the view tail; the ranking contract is pinned
/// here (empty → doc order, query → fuzzy-ranked best-first, non-matches out).
final class SymbolJumpTests: XCTestCase {

    private func h(_ title: String, _ line: Int, _ level: Int = 1) -> MarkdownHeading {
        MarkdownHeading(level: level, title: title, line: line)
    }

    func testEmptyQueryReturnsAllInDocumentOrder() {
        let hs = [h("Intro", 1), h("Setup", 8), h("Usage", 20)]
        XCTAssertEqual(SymbolJump.rank(headings: hs, query: ""), hs)
        XCTAssertEqual(SymbolJump.rank(headings: hs, query: "   "), hs)
    }

    func testQueryFiltersToMatchesOnly() {
        let hs = [h("Introduction", 1), h("Setup Guide", 8), h("Setup Notes", 14), h("Usage", 20)]
        let r = SymbolJump.rank(headings: hs, query: "setup")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.allSatisfy { $0.title.lowercased().contains("setup") },
                      "only setup-ish headings survive")
        XCTAssertFalse(r.contains(h("Introduction", 1)), "non-match dropped")
        XCTAssertFalse(r.contains(h("Usage", 20)), "non-match dropped")
    }

    func testNoMatchYieldsEmpty() {
        let hs = [h("Intro", 1), h("Setup", 8)]
        XCTAssertTrue(SymbolJump.rank(headings: hs, query: "zzzznope").isEmpty)
    }

    func testRankedResultPreservesHeadingLineForJump() {
        // The jump target is the heading's 1-based line — must survive ranking.
        let hs = [h("Alpha", 3), h("Target Heading", 42), h("Beta", 50)]
        let r = SymbolJump.rank(headings: hs, query: "target")
        XCTAssertEqual(r.first?.line, 42)
        XCTAssertEqual(r.first?.title, "Target Heading")
    }

    func testEmptyHeadingsYieldsEmpty() {
        XCTAssertTrue(SymbolJump.rank(headings: [], query: "anything").isEmpty)
        XCTAssertTrue(SymbolJump.rank(headings: [], query: "").isEmpty)
    }
}
