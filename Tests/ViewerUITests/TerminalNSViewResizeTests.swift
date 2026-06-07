import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// Host-testable guard for the terminal resize→reflow path (scroll-reset /
/// TUI-corruption-on-tab-switch bug). On a tab switch the pane uses
/// `.id(selectedTabID)`, which REMOUNTS the `TerminalNSView`; the fresh view
/// lays out at frame `.zero` first, so `recomputeGridDimensions` would compute
/// a 1×1 grid and fire `onResize(1,1)` — collapsing the live grid and
/// DESTROYING the on-screen output ("switch away + back → results gone, prompt
/// at the top", and it wrecks alt-screen TUIs). The fix ignores degenerate
/// bounds + dedupes unchanged sizes; this pins that behaviour on the host gate
/// (the visual "output survives the switch" is VM/T5, but the destructive
/// resize is the root cause and is catchable here).
@MainActor
final class TerminalNSViewResizeTests: HeadlessUITestCase {

    func test_zeroSizeTransient_doesNotEmitDestructiveResize() {
        let view = TerminalNSView(initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        var reported: [(rows: Int, cols: Int)] = []
        view.onResize = { r, c in reported.append((rows: r, cols: c)) }

        // The remount transient: a zero/degenerate frame must NOT report a size
        // (a 1×1 grid would collapse the buffer).
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(reported.isEmpty,
            "zero-size transient must not emit a resize — got \(reported)")

        // A real frame reports exactly once with a sane (>1) grid.
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(reported.count, 1, "first real size should report once")
        XCTAssertGreaterThan(reported.last!.rows, 1)
        XCTAssertGreaterThan(reported.last!.cols, 1)

        // Same size again → deduped (no parser churn / SIGWINCH spam).
        let afterReal = reported.count
        view.setFrameSize(NSSize(width: 800, height: 400))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(reported.count, afterReal, "unchanged size must not re-report")

        // Detached back to zero (tab switched away) → still no destructive 1×1.
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(reported.count, afterReal,
            "zero-size after a real size must not emit a 1×1 resize")
    }
}
