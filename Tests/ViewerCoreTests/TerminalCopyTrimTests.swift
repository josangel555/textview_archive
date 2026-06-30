import XCTest
@testable import ViewerCore

/// TSK-769 — terminal copy trims the cell-grid trailing-space padding + bottom blank rows
/// (matching Terminal.app / iTerm), while preserving interior blank lines (real content).
final class TerminalCopyTrimTests: XCTestCase {

    func test_trimsTrailingWhitespacePerLine_TSK769() {
        XCTAssertEqual(TerminalCopyTrim.trim("ls   \npwd\t\t"), "ls\npwd")
    }

    func test_dropsTrailingBlankLines_keepsInterior_TSK769() {
        // Interior blank line preserved; the trailing padded/blank rows dropped.
        XCTAssertEqual(TerminalCopyTrim.trim("a\n\nb\n   \n  \n"), "a\n\nb")
    }

    func test_preservesContent_withNoTrailingPadding_TSK769() {
        XCTAssertEqual(TerminalCopyTrim.trim("echo hi\nbye"), "echo hi\nbye")
    }

    func test_allBlankSelection_becomesEmpty_TSK769() {
        XCTAssertEqual(TerminalCopyTrim.trim("   \n\t\n"), "")
    }

    func test_singleLine_trimmed_TSK769() {
        XCTAssertEqual(TerminalCopyTrim.trim("npm run build      "), "npm run build")
    }
}
