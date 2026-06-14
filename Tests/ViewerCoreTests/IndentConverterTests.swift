import XCTest
@testable import ViewerCore

/// Teeth for leading-indentation conversion (TSK-675). LEADING whitespace only;
/// alignment after content is untouched; line terminators preserved (CRLF trap).
final class IndentConverterTests: XCTestCase {

    // MARK: tabsToSpaces

    func test_tabsToSpaces_expandsLeadingTabs() {
        XCTAssertEqual(IndentConverter.tabsToSpaces("\tx", width: 4), "    x")
        XCTAssertEqual(IndentConverter.tabsToSpaces("\t\tx", width: 2), "    x")
    }

    func test_tabsToSpaces_leavesNonLeadingTabs() {
        // A tab AFTER the first non-whitespace char is alignment — untouched.
        XCTAssertEqual(IndentConverter.tabsToSpaces("x\ty", width: 4), "x\ty")
        XCTAssertEqual(IndentConverter.tabsToSpaces("\tx\ty", width: 4), "    x\ty")
    }

    func test_tabsToSpaces_preservesCRLF() {
        let r = IndentConverter.tabsToSpaces("\ta\r\n\tb", width: 2)
        XCTAssertEqual(r, "  a\r\n  b")
        XCTAssertEqual(LineEndingDetector.detect(in: r), .crlf)
    }

    func test_tabsToSpaces_mixedLeading() {
        // two spaces then a tab (width 4) → two spaces + four spaces = six.
        XCTAssertEqual(IndentConverter.tabsToSpaces("  \tx", width: 4), "      x")
    }

    // MARK: spacesToTabs

    func test_spacesToTabs_collapsesFullRuns() {
        XCTAssertEqual(IndentConverter.spacesToTabs("    x", width: 4), "\tx")
        XCTAssertEqual(IndentConverter.spacesToTabs("        x", width: 4), "\t\tx")
    }

    func test_spacesToTabs_partialRunStaysSpaces() {
        XCTAssertEqual(IndentConverter.spacesToTabs("  x", width: 4), "  x")
        XCTAssertEqual(IndentConverter.spacesToTabs("      x", width: 4), "\t  x")
    }

    func test_spacesToTabs_leavesNonLeadingSpaces() {
        XCTAssertEqual(IndentConverter.spacesToTabs("x    y", width: 4), "x    y")
    }

    func test_spacesToTabs_existingLeadingTabPassesThrough() {
        // "  \t" leading (width 4): 2 pending spaces flushed, then the tab.
        XCTAssertEqual(IndentConverter.spacesToTabs("  \tx", width: 4), "  \tx")
    }

    func test_roundTrip_spaces_tabs_spaces() {
        let spaces = "        deep\n    shallow\nflush"
        let tabs = IndentConverter.spacesToTabs(spaces, width: 4)
        XCTAssertEqual(tabs, "\t\tdeep\n\tshallow\nflush")
        XCTAssertEqual(IndentConverter.tabsToSpaces(tabs, width: 4), spaces)
    }

    func test_empty() {
        XCTAssertEqual(IndentConverter.tabsToSpaces("", width: 4), "")
        XCTAssertEqual(IndentConverter.spacesToTabs("", width: 4), "")
    }
}
