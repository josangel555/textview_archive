import XCTest
@testable import ViewerCore

/// TSK-1434 — the shared results panel's pure model: builders map each tool's
/// output to rows (severity, clickable line, tag), empty inputs become a
/// positive "note", and plainText serializes for the Copy button.
final class ToolResultsTests: XCTestCase {
    func test_lint_buildsClickableWarningRows() {
        let issues = [MarkdownLintIssue(rule: "image-alt", line: 3, message: "Image missing alt text"),
                      MarkdownLintIssue(rule: "dup-anchor", line: 9, message: "Duplicate anchor")]
        let r = ToolResults.lint(issues)
        XCTAssertEqual(r.title, "Lint — 2 issues")
        XCTAssertEqual(r.rows.map(\.line), [3, 9])
        XCTAssertEqual(r.rows.map(\.tag), ["image-alt", "dup-anchor"])
        XCTAssertTrue(r.rows.allSatisfy { $0.severity == .warning })
    }

    func test_lint_empty_isPositiveNote() {
        let r = ToolResults.lint([])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].severity, .info)
        XCTAssertNil(r.rows[0].line)
    }

    func test_stats_buildsInfoRows() {
        let r = ToolResults.stats(DocumentStats(characters: 10, charactersNoWhitespace: 8, words: 2, lines: 1))
        XCTAssertEqual(r.rows.count, 4)
        XCTAssertTrue(r.rows.allSatisfy { $0.severity == .info && $0.line == nil })
        XCTAssertTrue(r.rows[0].message.contains("Lines: 1"))
        XCTAssertTrue(r.rows[1].message.contains("Words: 2"))
    }

    func test_csvSummary_oneRowPerLine() {
        let r = ToolResults.csvSummary("Rows: 3\nColumns: 2\ncol a: numeric")
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.rows[2].message, "col a: numeric")
    }

    func test_plainText_includesLineAndTag() {
        let r = ToolResults(title: "T", rows: [ToolResultRow(id: 0, severity: .error, line: 7, message: "m", tag: "t")])
        XCTAssertEqual(r.plainText, "T\n  line 7: m [t]")
    }
}
