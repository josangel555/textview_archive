import XCTest
@testable import ViewerCore

/// TSK-918 — side-panel width clamp: grow freely up to `available − minContent`,
/// never below `minPanel`, no fixed upper cap.
final class PanelResizeTests: XCTestCase {

    func test_withinBounds_unchanged() {
        XCTAssertEqual(
            PanelResize.clampWidth(300, available: 1200, minContent: 360, minPanel: 160),
            300)
    }

    func test_growsWellPastTheOld480Cap() {
        // The old hard cap was 480; now a wide window allows a much wider panel.
        XCTAssertEqual(
            PanelResize.clampWidth(900, available: 1600, minContent: 360, minPanel: 160),
            900, "no fixed 480 cap anymore")
    }

    func test_cappedToLeaveMinimumContent() {
        XCTAssertEqual(
            PanelResize.clampWidth(1100, available: 1200, minContent: 360, minPanel: 160),
            840, "panel may not starve the content area (1200 − 360)")
    }

    func test_belowMinPanel_floored() {
        XCTAssertEqual(
            PanelResize.clampWidth(50, available: 1200, minContent: 360, minPanel: 160),
            160)
    }

    func test_tinyWindow_panelFloorWins_overContentMin() {
        // Window too small for both minima → panel floor wins (content squeezed).
        XCTAssertEqual(
            PanelResize.clampWidth(500, available: 400, minContent: 360, minPanel: 160),
            160)
    }

    func test_hugeWindow_allowsVeryWidePanel() {
        XCTAssertEqual(
            PanelResize.clampWidth(2400, available: 3000, minContent: 360, minPanel: 160),
            2400)
    }
}
