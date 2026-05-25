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

    // P11 — line/col computed in O(N) total. Pin: many matches in a
    // long file still produces correct line/col without quadratic cost.
    func test_lineColumn_manyMatchesAcrossManyLines() throws {
        var text = ""
        for i in 0..<100 {
            text += "line\(i) hit here\n"
        }
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches.count, 100)
        XCTAssertEqual(matches.first?.line, 1)
        XCTAssertEqual(matches.last?.line, 100)
        for (i, m) in matches.enumerated() {
            XCTAssertEqual(m.line, i + 1, "match #\(i) on wrong line")
        }
    }

    func test_lineColumn_singleHit_in10kLineFile_isCorrect() throws {
        let prefix = Array(repeating: "noise\n", count: 9999).joined()
        let text = prefix + "needle"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "needle"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 10000)
        XCTAssertEqual(matches[0].column, 1)
    }

    // MARK: S2-E — CR / CRLF line counting

    /// Classic-Mac / CR-only files used to report every match as
    /// `line: 1, column: <doc-offset>`. After the fix bare `\r`
    /// advances the line counter the same as bare `\n`.
    func test_lineColumn_CR_only_files_countLines() throws {
        let text = "alpha\rbeta\rgamma hit here\r"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 3, "bare CR must advance line")
        // After "gamma " the column is 7 (1-based).
        XCTAssertEqual(matches[0].column, 7)
    }

    /// CRLF files used to count `\r` into the column (off-by-one).
    /// After the fix CRLF advances the line ONCE and `lineStart`
    /// lands after both terminator bytes — so columns are right.
    func test_lineColumn_CRLF_files_columnIsCorrect() throws {
        let text = "alpha\r\nbeta\r\nhit\r\n"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 3)
        XCTAssertEqual(
            matches[0].column, 1,
            "column on a CRLF-terminated line should be 1, not 2"
        )
    }

    /// Mixed terminators within one file must each be honoured by
    /// their own rule. Synthetic but exercises every branch.
    func test_lineColumn_mixed_LF_CR_CRLF() throws {
        // Line 1: "x\n"            (LF)
        // Line 2: "y\r"            (bare CR)
        // Line 3: "z\r\n"          (CRLF)
        // Line 4: "hit"
        let text = "x\ny\rz\r\nhit"
        let matches = try engine.search(in: text, query: FindQuery(pattern: "hit"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 4)
        XCTAssertEqual(matches[0].column, 1)
    }
}
