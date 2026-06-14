import XCTest
@testable import ViewerUI

/// TSK-902 — tab-title emphasis rule: preview tabs are italic-only (never
/// bold), normal tabs bold when selected.
final class TabTitleStyleTests: XCTestCase {

    func test_italic_onlyForPreview() {
        XCTAssertTrue(TabTitleStyle.isItalic(isPreview: true))
        XCTAssertFalse(TabTitleStyle.isItalic(isPreview: false))
    }

    func test_selectedNormalTab_isBold() {
        XCTAssertTrue(TabTitleStyle.isBold(isSelected: true, isPreview: false))
    }

    func test_unselectedNormalTab_notBold() {
        XCTAssertFalse(TabTitleStyle.isBold(isSelected: false, isPreview: false))
    }

    func test_previewTab_neverBold_evenWhenSelected() {
        XCTAssertFalse(TabTitleStyle.isBold(isSelected: true, isPreview: true),
            "a selected preview tab must be italic-only, not bold (TSK-902)")
        XCTAssertFalse(TabTitleStyle.isBold(isSelected: false, isPreview: true))
    }
}
