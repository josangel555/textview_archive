import XCTest
@testable import ViewerCore

/// TSK-1590 — a lone accordion tool window must be allowed to fill the sidebar
/// instead of being pinned to the multi-panel 0.5 share (owner report: "Git
/// only fills half the height when it's the only tool window").
final class SidebarPanelCeilingFractionTests: XCTestCase {

    func test_ceilingFraction_singlePanelGetsFullBand() {
        XCTAssertEqual(SidebarPanelHeights.ceilingFraction(visiblePanelCount: 0), 1.0)
        XCTAssertEqual(SidebarPanelHeights.ceilingFraction(visiblePanelCount: 1), 1.0)
    }

    func test_ceilingFraction_multiplePanelsKeepHalfSplit() {
        XCTAssertEqual(SidebarPanelHeights.ceilingFraction(visiblePanelCount: 2), 0.5)
        XCTAssertEqual(SidebarPanelHeights.ceilingFraction(visiblePanelCount: 5), 0.5)
    }

    func test_lonePanel_notCappedAtHalf() {
        // A lone panel dragged tall (stored 700) on an 800pt sidebar: the OLD
        // 0.5 ceiling capped it at 400 (the "half" bug); the single-panel 1.0
        // fraction lets it reach its stored height.
        let available: CGFloat = 800
        let stored: CGFloat = 700
        let single = SidebarPanelHeights.clamp(
            stored, availableHeight: available,
            fraction: SidebarPanelHeights.ceilingFraction(visiblePanelCount: 1))
        XCTAssertEqual(single, 700, "a lone panel is bounded by its stored height, not half the sidebar")

        let multi = SidebarPanelHeights.clamp(
            stored, availableHeight: available,
            fraction: SidebarPanelHeights.ceilingFraction(visiblePanelCount: 3))
        XCTAssertEqual(multi, 400, "with siblings the 0.5 ceiling still applies")
    }

    func test_lonePanel_stillFlooredAtMinExpanded() {
        // Even at fraction 1.0 a tiny sidebar can't shrink a panel below the floor.
        let v = SidebarPanelHeights.clamp(
            60, availableHeight: 40,
            fraction: SidebarPanelHeights.ceilingFraction(visiblePanelCount: 1))
        XCTAssertEqual(v, SidebarPanelHeights.minExpandedHeight)
    }
}
