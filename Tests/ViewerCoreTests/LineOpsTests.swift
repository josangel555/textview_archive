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
}
