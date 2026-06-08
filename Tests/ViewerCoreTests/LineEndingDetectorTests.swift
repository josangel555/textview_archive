import XCTest
@testable import ViewerCore

/// Coverage for `LineEndingDetector` (TSK-509). The CRLF cases are the
/// load-bearing ones: a grapheme-view scan would miss the LF inside `\r\n`
/// and misclassify, so these pin the scalar-level logic.
final class LineEndingDetectorTests: XCTestCase {

    private func d(_ s: String) -> LineEnding { LineEndingDetector.detect(in: s) }

    func test_empty_andSingleLine_areNone() {
        XCTAssertEqual(d(""), .none)
        XCTAssertEqual(d("no breaks here"), .none)
    }

    func test_pureLF() {
        XCTAssertEqual(d("a\nb\nc"), .lf)
        XCTAssertEqual(d("a\nb\n"), .lf, "trailing newline doesn't change kind")
    }

    func test_pureCRLF() {
        XCTAssertEqual(d("a\r\nb\r\nc"), .crlf)
        XCTAssertEqual(d("a\r\nb\r\n"), .crlf)
    }

    func test_pureCR_classicMac() {
        XCTAssertEqual(d("a\rb\rc"), .cr)
    }

    func test_blankCRLFLine_isStillCRLF_notMixed() {
        // `\r\n\r\n` is two CRLF pairs (a blank line), NOT a CRLF + lone CR/LF.
        XCTAssertEqual(d("a\r\n\r\nb"), .crlf)
    }

    func test_mixed_crlfAndLf() {
        XCTAssertEqual(d("a\r\nb\nc"), .mixed)
    }

    func test_mixed_lfAndCr() {
        XCTAssertEqual(d("a\nb\rc"), .mixed)
    }

    func test_mixed_crlfAndCr() {
        // A CRLF pair plus a lone CR (the lone CR is followed by 'b', not LF).
        XCTAssertEqual(d("a\r\nb\rc"), .mixed)
    }

    func test_loneCRAtEnd_isCR() {
        XCTAssertEqual(d("a\r"), .cr)
    }

    func test_loneCRBeforeNonLF_isCR_notCRLF() {
        XCTAssertEqual(d("a\rb"), .cr)
    }

    func test_displayString_matchesRawValue() {
        XCTAssertEqual(LineEndingDetector.displayString(in: "a\r\nb"), "CRLF")
        XCTAssertEqual(LineEndingDetector.displayString(in: "a\nb"), "LF")
        XCTAssertEqual(LineEndingDetector.displayString(in: "abc"), "—")
    }
}
