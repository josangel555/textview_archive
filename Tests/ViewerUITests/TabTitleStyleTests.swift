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

/// Owner 2026-08-23 — split-view selection emphasis: only the FOCUSED pane's
/// selected tab carries the accent; an unfocused pane's selected tab is grey;
/// unselected tabs are plain regardless of pane focus. (Pixel tail: the
/// panes-split VM scene.)
final class TabChipSelectionStyleTests: XCTestCase {

    func test_selectedInFocusedPane_isTheAccentTab() {
        XCTAssertEqual(TabChipSelectionStyle.emphasis(isSelected: true, isPaneFocused: true), .accent)
    }

    func test_selectedInUnfocusedPane_isMutedGrey() {
        XCTAssertEqual(TabChipSelectionStyle.emphasis(isSelected: true, isPaneFocused: false), .muted,
            "an unfocused pane's front tab must render grey so only THE active tab wears the accent")
    }

    func test_unselected_isPlain_regardlessOfPaneFocus() {
        XCTAssertEqual(TabChipSelectionStyle.emphasis(isSelected: false, isPaneFocused: true), .plain)
        XCTAssertEqual(TabChipSelectionStyle.emphasis(isSelected: false, isPaneFocused: false), .plain)
    }
}
