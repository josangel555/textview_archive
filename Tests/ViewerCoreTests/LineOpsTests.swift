import XCTest
@testable import ViewerCore

/// Teeth for whole-file line operations (Edit ▸ Lines) — terminator-aware,
/// trailing-newline preserving.
final class LineOpsTests: XCTestCase {

    func test_sort_ascending() {
        XCTAssertEqual(LineOps.sort("banana\napple\ncherry", ascending: true), "apple\nbanana\ncherry")
    }

    func test_sort_descending() {
        XCTAssertEqual(LineOps.sort("apple\nbanana\ncherry", ascending: false), "cherry\nbanana\napple")
    }

    func test_reverse() {
        XCTAssertEqual(LineOps.reverse("one\ntwo\nthree"), "three\ntwo\none")
    }

    func test_removeDuplicates_keepsFirst_preservesOrder() {
        XCTAssertEqual(LineOps.removeDuplicates("b\na\nb\nc\na"), "b\na\nc")
    }

    func test_preservesTrailingNewline() {
        XCTAssertEqual(LineOps.sort("b\na\n", ascending: true), "a\nb\n")
        XCTAssertEqual(LineOps.sort("b\na", ascending: true), "a\nb", "no trailing newline added")
    }

    func test_preservesCRLF() {
        let out = LineOps.sort("b\r\na\r\nc", ascending: true)
        XCTAssertEqual(out, "a\r\nb\r\nc")
        XCTAssertEqual(LineEndingDetector.detect(in: out), .crlf)
    }

    func test_crlf_withTrailing() {
        XCTAssertEqual(LineOps.sort("b\r\na\r\n", ascending: true), "a\r\nb\r\n")
    }

    func test_empty_andSingleLine() {
        XCTAssertEqual(LineOps.sort("", ascending: true), "")
        XCTAssertEqual(LineOps.sort("solo", ascending: true), "solo")
        XCTAssertEqual(LineOps.removeDuplicates("solo\n"), "solo\n")
    }

    func test_removeDuplicates_blankLinesAlsoDeduped() {
        XCTAssertEqual(LineOps.removeDuplicates("a\n\nb\n\n"), "a\n\nb\n")
    }

    func test_removeEmptyLines_dropsBlankAndWhitespaceOnly() {
        XCTAssertEqual(LineOps.removeEmptyLines("a\n\nb\n   \nc"), "a\nb\nc")
    }

    func test_removeEmptyLines_preservesTrailing_andEnding() {
        XCTAssertEqual(LineOps.removeEmptyLines("a\r\n\r\nb\r\n"), "a\r\nb\r\n")
    }

    func test_removeEmptyLines_keepsLeadingWhitespaceOnContentLines() {
        XCTAssertEqual(LineOps.removeEmptyLines("  a\n\n\tb"), "  a\n\tb")
    }

    func test_collapseBlankLines_runsCollapseToOne() {
        XCTAssertEqual(LineOps.collapseBlankLines("a\n\n\n\nb"), "a\n\nb")
    }

    func test_collapseBlankLines_whitespaceOnlyCountsAsBlank() {
        XCTAssertEqual(LineOps.collapseBlankLines("a\n\n   \n\nb"), "a\n\nb")
    }

    func test_collapseBlankLines_singleBlankUntouched_andCRLF() {
        XCTAssertEqual(LineOps.collapseBlankLines("a\r\n\r\nb"), "a\r\n\r\nb")
    }

    func test_collapseBlankLines_leadingBlanksCollapse_trailingPreserved() {
        XCTAssertEqual(LineOps.collapseBlankLines("\n\na\n\n\n"), "\na\n\n")
    }
}
