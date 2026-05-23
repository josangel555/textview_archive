import XCTest
@testable import ViewerKit

final class HighlightedTextTests: XCTestCase {

    // MARK: - Empty / no-match

    func testEmptyQueryReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "hello world", query: "")
        XCTAssertEqual(r.count, 0)
    }

    func testWhitespaceOnlyQueryReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "hello world", query: "   ")
        XCTAssertEqual(r.count, 0)
    }

    func testEmptyHaystackReturnsNoRanges() {
        let r = HighlightedText.ranges(in: "", query: "x")
        XCTAssertEqual(r.count, 0)
    }

    func testNoMatchReturnsEmpty() {
        let r = HighlightedText.ranges(in: "hello", query: "xyz")
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Literal matching

    func testSingleMatch() {
        let text = "hello world"
        let ranges = HighlightedText.ranges(in: text, query: "world")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "world")
    }

    func testMultipleMatches() {
        let text = "foo bar foo baz foo"
        let ranges = HighlightedText.ranges(in: text, query: "foo")
        XCTAssertEqual(ranges.count, 3)
        for r in ranges {
            XCTAssertEqual(String(text[r]), "foo")
        }
    }

    func testCaseInsensitiveByDefault() {
        let text = "Hello WORLD hello"
        let ranges = HighlightedText.ranges(in: text, query: "hello")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "Hello")
        XCTAssertEqual(String(text[ranges[1]]), "hello")
    }

    func testCaseSensitiveSkipsDifferentCase() {
        let text = "Hello WORLD hello"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "hello",
            mode: .literal(caseSensitive: true)
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "hello")
    }

    func testOverlappingNeedleAdvancesPastMatch() {
        // "aa" in "aaaa" should match at positions 0 and 2, not
        // 0/1/2/3 — overlap suppression is part of the contract.
        let text = "aaaa"
        let ranges = HighlightedText.ranges(in: text, query: "aa")
        XCTAssertEqual(ranges.count, 2)
    }

    func testUnicodeMatch() {
        let text = "café au lait, CAFÉ noir"
        let ranges = HighlightedText.ranges(in: text, query: "café")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "café")
        XCTAssertEqual(String(text[ranges[1]]), "CAFÉ")
    }

    // MARK: - Regex mode

    func testRegexValidPattern() {
        let text = "foo123 bar456 baz"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "\\d+",
            mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "123")
        XCTAssertEqual(String(text[ranges[1]]), "456")
    }

    func testRegexInvalidPatternFallsBackToLiteral() {
        // `foo(` is invalid regex (unbalanced paren). Should not throw
        // and should match the literal substring instead.
        let text = "see foo( here"
        let ranges = HighlightedText.ranges(
            in: text,
            query: "foo(",
            mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "foo(")
    }

    func testRegexCaseSensitivity() {
        let text = "Foo foo FOO"
        let insensitive = HighlightedText.ranges(
            in: text, query: "foo", mode: .regex(caseSensitive: false)
        )
        XCTAssertEqual(insensitive.count, 3)
        let sensitive = HighlightedText.ranges(
            in: text, query: "foo", mode: .regex(caseSensitive: true)
        )
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(String(text[sensitive[0]]), "foo")
    }
}
