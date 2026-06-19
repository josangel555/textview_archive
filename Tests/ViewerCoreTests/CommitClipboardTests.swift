import XCTest
@testable import ViewerCore

/// TSK-908 — clipboard text for the commit context-menu copy actions. Pure, host-safe.
final class CommitClipboardTests: XCTestCase {

    func test_shortSHA_takesFirstChars_andHandlesShortInput() {
        XCTAssertEqual(CommitClipboard.shortSHA("abcdef1234567890"), "abcdef12")
        XCTAssertEqual(CommitClipboard.shortSHA("abc"), "abc", "shorter than 8 → whole")
        XCTAssertEqual(CommitClipboard.shortSHA("abcdef1234", length: 4), "abcd")
        XCTAssertEqual(CommitClipboard.shortSHA(""), "")
    }

    func test_reference_isOnelineShortShaPlusSubject() {
        XCTAssertEqual(CommitClipboard.reference(sha: "abcdef1234", subject: "Fix the bug"),
                       "abcdef12 Fix the bug")
        XCTAssertEqual(CommitClipboard.reference(sha: "abcdef1234", subject: ""),
                       "abcdef12", "empty subject → SHA only, no trailing space")
    }
}
