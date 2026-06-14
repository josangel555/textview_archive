import XCTest
@testable import ViewerCore

/// TSK-727 `#` operator: the pure in-file text scan. The palette list/jump
/// render is the view tail, but the scan + 1-based line numbering (which the
/// jump relies on) is pinned here.
final class InFileSearchTests: XCTestCase {

    func testFindsMatchingLinesWithOneBasedNumbers() {
        let text = "alpha\nneedle here\nbeta\nanother needle\ngamma\n"
        let m = InFileSearch.matches(in: text, query: "needle")
        XCTAssertEqual(m.map { $0.lineNumber }, [2, 4])
        XCTAssertEqual(m.map { $0.line }, ["needle here", "another needle"])
    }

    func testCaseInsensitive() {
        let text = "Foo\nBAR\nbaz\n"
        XCTAssertEqual(InFileSearch.matches(in: text, query: "bar").map { $0.lineNumber }, [2])
        XCTAssertEqual(InFileSearch.matches(in: text, query: "FOO").map { $0.lineNumber }, [1])
    }

    func testEmptyOrBlankQueryYieldsNothing() {
        let text = "a\nb\n"
        XCTAssertTrue(InFileSearch.matches(in: text, query: "").isEmpty)
        XCTAssertTrue(InFileSearch.matches(in: text, query: "   ").isEmpty)
    }

    func testNoMatch() {
        XCTAssertTrue(InFileSearch.matches(in: "a\nb\nc\n", query: "zzz").isEmpty)
    }

    func testCRLFLineNumbersAndStrippedCarriageReturn() {
        // CRLF counts as one line (per-\n), and the returned line has no \r.
        let text = "one\r\ntwo needle\r\nthree\r\n"
        let m = InFileSearch.matches(in: text, query: "needle")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].lineNumber, 2)
        XCTAssertEqual(m[0].line, "two needle", "trailing \\r must be stripped")
    }

    func testFirstAndLastLineMatch() {
        let text = "needle first\nmid\nneedle last"
        let m = InFileSearch.matches(in: text, query: "needle")
        XCTAssertEqual(m.map { $0.lineNumber }, [1, 3])
    }

    func testLimitCapsResults() {
        let text = String(repeating: "needle\n", count: 50)
        let m = InFileSearch.matches(in: text, query: "needle", limit: 10)
        XCTAssertEqual(m.count, 10)
        XCTAssertEqual(m.first?.lineNumber, 1)
        XCTAssertEqual(m.last?.lineNumber, 10, "the cap takes the first N in line order")
    }

    func testMultipleOccurrencesOnOneLineCountAsOneMatch() {
        // A line is one result regardless of how many times the needle appears.
        let m = InFileSearch.matches(in: "needle needle needle\n", query: "needle")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].lineNumber, 1)
    }
}
