import XCTest
@testable import ViewerCore

/// Teeth for the file-level whitespace cleanup (TSK-675). Unlike the clipboard
/// `TextTools.trimTrailingWhitespace`, these MUST preserve each line's terminator
/// (LF/CRLF/CR) — converting line endings here would be a silent data change.
final class TextCleanupTests: XCTestCase {

    // MARK: trimTrailingWhitespace

    func test_trim_stripsTrailingSpacesAndTabs() {
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace("abc  \t\ndef\t"), "abc\ndef")
    }

    func test_trim_preservesCRLF() {
        // The terminator must survive byte-for-byte (the CRLF grapheme trap).
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace("a  \r\nb \r\nc"), "a\r\nb\r\nc")
        XCTAssertEqual(LineEndingDetector.detect(in:
            TextCleanup.trimTrailingWhitespace("a  \r\nb \r\nc")), .crlf)
    }

    func test_trim_preservesLoneCR() {
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace("a \rb "), "a\rb")
    }

    func test_trim_doesNotTouchLeadingOrInteriorWhitespace() {
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace("  indented   word  "), "  indented   word")
    }

    func test_trim_blankLinesBecomeEmpty_terminatorsKept() {
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace("a\n   \nb"), "a\n\nb")
    }

    func test_trim_empty() {
        XCTAssertEqual(TextCleanup.trimTrailingWhitespace(""), "")
    }

    // MARK: ensureFinalNewline

    func test_ensureFinalNewline_addsWhenMissing() {
        XCTAssertEqual(TextCleanup.ensureFinalNewline("abc", using: .lf), "abc\n")
        XCTAssertEqual(TextCleanup.ensureFinalNewline("abc", using: .crlf), "abc\r\n")
    }

    func test_ensureFinalNewline_noopWhenPresent() {
        XCTAssertEqual(TextCleanup.ensureFinalNewline("abc\n", using: .lf), "abc\n")
        XCTAssertEqual(TextCleanup.ensureFinalNewline("abc\r\n", using: .crlf), "abc\r\n")
        // Already ends in a break → not doubled, even if the kind differs.
        XCTAssertEqual(TextCleanup.ensureFinalNewline("abc\r", using: .lf), "abc\r")
    }

    func test_ensureFinalNewline_emptyStaysEmpty() {
        XCTAssertEqual(TextCleanup.ensureFinalNewline("", using: .lf), "")
    }
}
