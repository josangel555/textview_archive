import XCTest
@testable import ViewerCore

/// Regression coverage for the audit S2 CRLF finding, now pinned on the LIVE
/// path: `RustIndentAdapter.detect` (the rust core; the Swift `IndentDetector`
/// twin was deleted in TSK-649 Stage B #1). The original bug: the Swift twin
/// split lines over the grapheme (`Character`) view, where `"\r\n"` is a SINGLE
/// cluster, so `firstIndex(of: "\n")` never matched the LF inside a CRLF pair
/// and collapsed every Windows-authored file into one line. These cases pin the
/// previously-divergent CRLF class (incl. lone-CR / mixed-ending / final-line)
/// against the engine that now serves them.
final class Audit_Sources_ViewerCore_IndentDetector_swift_CRLFTests: XCTestCase {

    // MARK: CRLF line endings

    func testCRLFFourSpaceIndent() {
        // The exact case from the audit evidence: was "—", must be Spaces (4).
        let src = "def f():\r\n    pass\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (4)")
    }

    func testCRLFTwoSpaceIndent() {
        let src = "function f() {\r\n  a()\r\n  b()\r\n}\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (2)")
    }

    func testCRLFTabsOnly() {
        let src = "\tfoo\r\n\tbar\r\n\tbaz\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Tabs")
    }

    func testCRLFMixedTabsAndSpaces() {
        let src = "\ttab line\r\n    space line\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Mixed")
    }

    func testCRLFNoIndent() {
        let src = "line one\r\nline two\r\nline three\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "—")
    }

    // MARK: All-whitespace / blank CRLF lines must not be miscounted

    func testCRLFWhitespaceOnlyLinesIgnored() {
        // Trailing CR on an all-whitespace line must NOT register as a
        // space-indented content line (the trailing-CR strip the audit
        // calls for). Only the real "foo" line counts -> no indent.
        let src = "    \r\n    \r\nfoo\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "—")
    }

    func testCRLFBlankLinesBetweenIndented() {
        let src = "def f():\r\n\r\n    pass\r\n\r\n    return 1\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (4)")
    }

    // MARK: Edge cases — final line without LF, mixed endings, lone CR

    func testCRLFFinalLineWithoutTerminator() {
        // Last line has CRLF stripped of the trailing LF (lone CR at EOF):
        // "    pass\r" must still count as a 4-space line.
        let src = "def f():\r\n    pass\r"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (4)")
    }

    func testMixedLFAndCRLFEndings() {
        // A file with mixed endings still resolves each line correctly.
        let src = "def f():\n    a()\r\n    b()\n    c()\r\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (4)")
    }

    func testLoneCRDoesNotCorruptDetection() {
        // Old-Mac CR-only endings collapse to a single logical line (LF is
        // the only split scalar, matching the Rust port). First char is a
        // letter, so no indent is reported -- not a bogus width.
        let src = "def f():\r    pass\r"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "—")
    }

    // MARK: LF parity unchanged (guard against regressing the common path)

    func testLFFourSpaceStillWorks() {
        let src = "def f():\n    pass\n"
        XCTAssertEqual(RustIndentAdapter.detect(in: src), "Spaces (4)")
    }
}
