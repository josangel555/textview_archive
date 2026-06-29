import XCTest
@testable import ViewerCore

/// TSK-1313 — the terminal pane's size clamp is a corruption CEILING, not a UX cap:
/// the user can expand it horizontally/vertically far beyond the old 800/900 limits
/// (the window + split layout bound the usable size). Min floors + the absurd-value
/// corruption guard are preserved.
final class TerminalPaneClampTests: XCTestCase {

    func test_clampWidth_allowsLargeSizes_pastOldCap() {
        XCTAssertEqual(TerminalPaneLayout.clampWidth(2000), 2000, "no UX cap — large widths pass (old cap was 900)")
        XCTAssertEqual(TerminalPaneLayout.clampWidth(100), TerminalPaneLayout.minWidth, "min floor preserved")
    }

    func test_clampHeight_allowsLargeSizes_pastOldCap() {
        XCTAssertEqual(TerminalPaneLayout.clampHeight(2000), 2000, "no UX cap — large heights pass (old cap was 800)")
        XCTAssertEqual(TerminalPaneLayout.clampHeight(10), TerminalPaneLayout.minHeight, "min floor preserved")
    }

    func test_corruptionCeiling_stillGuardsAbsurdValues() {
        XCTAssertEqual(TerminalPaneLayout.clampWidth(1_000_000), TerminalPaneLayout.maxWidth)
        XCTAssertEqual(TerminalPaneLayout.clampHeight(1_000_000), TerminalPaneLayout.maxHeight)
    }
}
