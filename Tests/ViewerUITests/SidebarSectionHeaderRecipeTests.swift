import XCTest
@testable import ViewerUI

/// Pure-logic pin-test for the shared sidebar section header recipe.
/// Catches drift in the per-section header font / weight / padding
/// envelope: if one section file hardcodes a different size, the
/// recipe constants below stay stable but the visual will diverge,
/// so the canonical fix is "use the shared `SidebarSectionHeaderLabel`
/// / `.sidebarHeaderRow()` modifier instead of rolling your own."
///
/// These tests do not instantiate any view — they just pin the
/// recipe constants. Safe to run on the host.
///
/// Filter with:
///   `swift test --filter ViewerUITests.SidebarSectionHeaderRecipeTests`
final class SidebarSectionHeaderRecipeTests: XCTestCase {

    func test_labelFontSize_is10() {
        // 10pt is the across-the-board section label size. Increasing
        // it makes every section header larger — likely a deliberate
        // design call, not an accidental edit. Pin so an accidental
        // bump shows up as a failing test, not a quietly oversized
        // sidebar.
        XCTAssertEqual(SidebarSectionHeaderMetrics.labelFontSize, 10)
    }

    func test_chevronFontSize_is9() {
        // Chevron is one point smaller than the label so it reads as
        // chrome, not as part of the label.
        XCTAssertEqual(SidebarSectionHeaderMetrics.chevronFontSize, 9)
    }

    func test_chevronFrameWidth_is10() {
        // The chevron sits in a 10pt-wide frame so labels in expanded
        // and collapsed states are vertically aligned (the down-chevron
        // glyph is wider than the right-chevron). 10pt fits both
        // without horizontal shift.
        XCTAssertEqual(SidebarSectionHeaderMetrics.chevronFrameWidth, 10)
    }

    func test_horizontalPadding_is10() {
        XCTAssertEqual(SidebarSectionHeaderMetrics.horizontalPadding, 10)
    }

    func test_verticalPadding_is4() {
        XCTAssertEqual(SidebarSectionHeaderMetrics.verticalPadding, 4)
    }

    /// Sanity: the recipe values together produce a header row no
    /// taller than the file-tree rows (22pt height + 1pt for inter-
    /// section breathing room). A regression that bumped vertical
    /// padding to 8pt would make every section header visually
    /// dominant.
    func test_recipeTotals_keepHeaderCompact() {
        let totalVerticalPadding =
            SidebarSectionHeaderMetrics.verticalPadding * 2
        XCTAssertLessThanOrEqual(totalVerticalPadding, 12,
            "Header row vertical padding shouldn't exceed 12pt total")
    }
}
