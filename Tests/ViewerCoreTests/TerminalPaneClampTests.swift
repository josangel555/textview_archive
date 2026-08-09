import XCTest
@testable import ViewerCore

/// TSK-1313 — the terminal pane's size clamp is a corruption CEILING, not a UX cap:
/// the user can expand it vertically far beyond the old 800 limit (the window +
/// split layout bound the usable size). Min floors + the absurd-value corruption
/// guard are preserved. (The side-column WIDTH clamp is gone with the 2026-08-09
/// terminal-as-a-panel rework — a right-docked terminal's width rides
/// `PanelDockLayout` like every tool window.)
final class TerminalPaneClampTests: XCTestCase {

    func test_clampHeight_allowsLargeSizes_pastOldCap() {
        XCTAssertEqual(TerminalPaneLayout.clampHeight(2000), 2000, "no UX cap — large heights pass (old cap was 800)")
        XCTAssertEqual(TerminalPaneLayout.clampHeight(10), TerminalPaneLayout.minHeight, "min floor preserved")
    }

    func test_corruptionCeiling_stillGuardsAbsurdValues() {
        XCTAssertEqual(TerminalPaneLayout.clampHeight(1_000_000), TerminalPaneLayout.maxHeight)
    }
}
