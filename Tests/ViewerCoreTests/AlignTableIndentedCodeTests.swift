import XCTest
@testable import ViewerCore

/// Align Tables (Formatter.prettyPrint .markdown) must not treat pipe content
/// inside a 4-space INDENTED code block as a table — CommonMark renders that as
/// code, so reformatting would strip the indent and corrupt it. Fenced code was
/// already skipped; this covers the indented-code sibling.
final class AlignTableIndentedCodeTests: XCTestCase {
    func test_indentedPipeContent_notReformatted() {
        let src = "Para\n\n    | a | b |\n    | - | - |\n    | 1 | 2 |\n"
        XCTAssertEqual(Formatter.prettyPrint(src, as: .markdown), src,
                       "4-space-indented pipe content is code, must be left byte-identical")
    }

    func test_tabIndentedPipeContent_notReformatted() {
        let src = "\t| a | b |\n\t| - | - |\n"
        XCTAssertEqual(Formatter.prettyPrint(src, as: .markdown), src, "tab indent = 4 cols = code")
    }

    func test_realTable_stillAligns() {
        let src = "| a | b |\n| - | - |\n| 1 | 2 |\n"
        XCTAssertEqual(Formatter.prettyPrint(src, as: .markdown),
                       "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n")
    }

    func test_upTo3SpaceIndentTable_stillAligns() {
        // 0–3 leading spaces are valid table indentation.
        let src = "   | a | b |\n   | - | - |\n"
        let out = Formatter.prettyPrint(src, as: .markdown)
        XCTAssertTrue(out.contains("| a   | b   |"), "3-space-indented table still aligns; got:\n\(out)")
    }
}
