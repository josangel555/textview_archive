import XCTest
@testable import ViewerCore

final class FindEngineTests: XCTestCase {
    private let engine = FindEngine()

    private func nsRange(_ loc: Int, _ len: Int) -> NSRange {
        NSRange(location: loc, length: len)
    }

    // MARK: Empty / basic

    func test_emptyQueryReturnsNoMatches() throws {
        let m = try engine.search(in: "anything", query: FindQuery(pattern: ""))
        XCTAssertEqual(m, [])
    }

    func test_literalMatch_singleHit() throws {
        let matches = try engine.search(in: "Hello, world!", query: FindQuery(pattern: "world"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range, nsRange(7, 5))
    }

    func test_literalMatch_multipleHits() throws {
        let matches = try engine.search(in: "ab ab ab", query: FindQuery(pattern: "ab"))
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map { $0.range.location }, [0, 3, 6])
    }

    // MARK: Case sensitivity

    func test_caseInsensitiveByDefault() throws {
        let matches = try engine.search(
            in: "Hello hello HELLO",
            query: FindQuery(pattern: "hello")
        )
        XCTAssertEqual(matches.count, 3)
    }

    func test_caseSensitive() throws {
        let matches = try engine.search(
            in: "Hello hello HELLO",
            query: FindQuery(pattern: "hello", caseSensitive: true)
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range.location, 6)
    }

    // MARK: Whole word

    func test_wholeWord() throws {
        let matches = try engine.search(
            in: "the cat catches",
            query: FindQuery(pattern: "cat", wholeWord: true)
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range.location, 4)
    }

    func test_wholeWord_off_matchesSubstring() throws {
        let matches = try engine.search(
            in: "the cat catches",
            query: FindQuery(pattern: "cat")
        )
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: Regex

    func test_regex_simple() throws {
        let matches = try engine.search(
            in: "v1.2.3 and v10.20.30",
            query: FindQuery(pattern: #"v\d+(?:\.\d+)+"#, kind: .regex)
        )
        XCTAssertEqual(matches.count, 2)
    }

    func test_regex_invalidThrows() {
        XCTAssertThrowsError(try engine.search(
            in: "abc",
            query: FindQuery(pattern: "[unclosed", kind: .regex)
        )) { error in
            guard case .invalidRegex(let p) = error as? FindError else {
                return XCTFail("expected .invalidRegex, got \(error)")
            }
            XCTAssertEqual(p, "[unclosed")
        }
    }

    func test_literal_escapesRegexMetacharacters() throws {
        let matches = try engine.search(
            in: "a.b and a*b",
            query: FindQuery(pattern: "a.b")
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range.location, 0)
    }

    // MARK: Line/column

    func test_lineColumn_singleLine() throws {
        let matches = try engine.search(in: "abc def", query: FindQuery(pattern: "def"))
        XCTAssertEqual(matches[0].line, 1)
        XCTAssertEqual(matches[0].column, 5)
    }

    func test_lineColumn_multiLine() throws {
        let text = "line1\nline2 hit\nline3"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches[0].line, 2)
        XCTAssertEqual(matches[0].column, 7)
    }

    func test_lineColumn_blankLines() throws {
        let text = "\n\nhit"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches[0].line, 3)
        XCTAssertEqual(matches[0].column, 1)
    }

    // MARK: nextMatch

    func test_nextMatch_findsAtOrAfterCursor() {
        let ms = [
            FindMatch(range: nsRange(0, 1), line: 1, column: 1),
            FindMatch(range: nsRange(5, 1), line: 1, column: 6),
            FindMatch(range: nsRange(10, 1), line: 1, column: 11),
        ]
        let (m, i) = FindEngine.nextMatch(in: ms, after: 6)!
        XCTAssertEqual(m.range.location, 10)
        XCTAssertEqual(i, 2)
    }

    func test_nextMatch_wrapsAround() {
        let ms = [
            FindMatch(range: nsRange(0, 1), line: 1, column: 1),
            FindMatch(range: nsRange(5, 1), line: 1, column: 6),
        ]
        let (m, i) = FindEngine.nextMatch(in: ms, after: 99)!
        XCTAssertEqual(m.range.location, 0)
        XCTAssertEqual(i, 0)
    }

    func test_nextMatch_emptyReturnsNil() {
        XCTAssertNil(FindEngine.nextMatch(in: [], after: 0))
    }
}
