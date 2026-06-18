import XCTest
@testable import ViewerUI

/// TSK-374 — the pure row model behind the find-match LIST popover. Host-safe
/// (no window): maps match line numbers + the document text to (line, text)
/// rows. The list view + popover placement are the VM/owner render tail.
final class FindMatchListTests: XCTestCase {

    func test_rows_mapMatchLinesToTrimmedLineText() {
        let doc = "alpha\n  beta match  \ngamma\n\ndelta match\n"
        let rows = FindMatchList.rows(matchLines: [2, 5], docText: doc)
        XCTAssertEqual(rows.map(\.line), [2, 5])
        XCTAssertEqual(rows.map(\.text), ["beta match", "delta match"], "leading/trailing ws trimmed")
        XCTAssertEqual(rows.map(\.id), [0, 1], "stable positional ids")
    }

    func test_rows_skipsOutOfRange_andKeepsSameLineMatchesDistinct() {
        let doc = "one\ntwo\n"
        // line 5 is out of range → skipped; the duplicate line 1 stays as two rows.
        let rows = FindMatchList.rows(matchLines: [1, 5, 1], docText: doc)
        XCTAssertEqual(rows.map(\.line), [1, 1], "out-of-range line dropped")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "ids unique even for same line")
    }

    func test_rows_truncatesLongLines_withEllipsis() {
        let doc = String(repeating: "x", count: 500)
        let rows = FindMatchList.rows(matchLines: [1], docText: doc, maxTextLength: 50)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].text.hasSuffix("…"))
        XCTAssertEqual(rows[0].text.count, 51, "50 chars + ellipsis")
    }

    func test_rows_emptyMatchLines_yieldNoRows() {
        XCTAssertTrue(FindMatchList.rows(matchLines: [], docText: "a\nb\n").isEmpty)
    }
}
