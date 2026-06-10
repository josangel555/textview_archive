import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// TSK-493 — the `--diagnose` dump's terminal-grid evidence contract.
/// The "terminal shows ~1 line in a 320pt band" bug class is invisible to
/// frame checks alone: the NSView frame can be correct while the EMULATOR
/// grid is stale (1 row) or the content sits bottom-anchored. These pin the
/// fields the VM-side dump relies on to arbitrate that, so the harness
/// signal can't silently rot.
@MainActor
final class TerminalDiagnosticInfoTests: HeadlessUITestCase {

    /// A fresh blank screen: grid dimensions echo the model, no non-blank
    /// rows, cursor at origin.
    func test_blankScreen_reportsGridAndNoContentRows() {
        let view = TerminalNSView(
            initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        let info = view.diagnosticGridInfo()

        XCTAssertEqual(info["grid_rows"] as? Int, 24)
        XCTAssertEqual(info["grid_cols"] as? Int, 80)
        XCTAssertEqual(info["cursor_row"] as? Int, 0)
        XCTAssertEqual(info["cursor_col"] as? Int, 0)
        XCTAssertEqual(info["firstNonBlankRow"] as? Int, -1)
        XCTAssertEqual(info["lastNonBlankRow"] as? Int, -1)
        XCTAssertEqual(info["nonBlankRowCount"] as? Int, 0)
        XCTAssertEqual(info["scrollback_count"] as? Int, 0)
        XCTAssertEqual(info["scrollOffset"] as? Int, 0)
    }

    /// Prompt-at-top vs prompt-at-bottom is exactly what TSK-493's symptom
    /// hinged on: a healthy mount has content starting at row 0.
    func test_contentRows_reportOccupancy_topAnchored() {
        var screen = TerminalScreen(rows: 24, cols: 80)
        for ch in "user@host %" { screen.write(ch) }
        let view = TerminalNSView(initialScreen: screen, fontSize: 13)
        let info = view.diagnosticGridInfo()

        XCTAssertEqual(info["firstNonBlankRow"] as? Int, 0,
            "a healthy fresh shell writes its prompt at the TOP of the grid")
        XCTAssertEqual(info["lastNonBlankRow"] as? Int, 0)
        XCTAssertEqual(info["nonBlankRowCount"] as? Int, 1)
        XCTAssertEqual(info["cursor_row"] as? Int, 0)
        XCTAssertNotEqual(info["cursor_col"] as? Int, 0)
    }

    /// The broken-state shape the dump must be able to EXPRESS: content
    /// bottom-anchored in the grid (what a 1-row-then-grown grid looks like).
    func test_contentRows_reportOccupancy_bottomAnchored() {
        var screen = TerminalScreen(rows: 24, cols: 80)
        screen.moveCursor(row: 23, col: 0)
        for ch in "user@host %" { screen.write(ch) }
        let view = TerminalNSView(initialScreen: screen, fontSize: 13)
        let info = view.diagnosticGridInfo()

        XCTAssertEqual(info["firstNonBlankRow"] as? Int, 23,
            "bottom-anchored content must be distinguishable from top-anchored")
        XCTAssertEqual(info["nonBlankRowCount"] as? Int, 1)
    }

    /// `gridMatchesBounds` is the one-glance health bit: after a real layout
    /// at H×W, the emulator grid the view ACTUALLY resized to (via onResize →
    /// update(screen:)) must agree with what the bounds imply.
    func test_gridMatchesBounds_afterRealLayoutAndResizeRoundTrip() {
        var screen = TerminalScreen(rows: 24, cols: 80)
        let view = TerminalNSView(initialScreen: screen, fontSize: 13)
        view.onResize = { rows, cols in
            screen.resize(rows: rows, cols: cols)
        }
        view.frame = NSRect(x: 0, y: 0, width: 575, height: 320)
        view.layoutSubtreeIfNeeded()
        view.update(screen: screen, fontSize: 13)

        let info = view.diagnosticGridInfo()
        XCTAssertEqual(info["gridMatchesBounds"] as? Bool, true,
            "after the resize round-trip the emulator grid must match bounds")
        XCTAssertEqual(info["grid_rows"] as? Int,
                       info["bounds_expected_rows"] as? Int)
        XCTAssertGreaterThan((info["grid_rows"] as? Int) ?? 0, 1,
            "a 320pt-tall pane is many rows — 1 row means the TSK-493 symptom")
    }

    /// The STALE-GRID shape (the failure the field exists to catch): bounds
    /// say ~18 rows but the emulator never grew past 1 → the health bit
    /// must read false.
    func test_gridMatchesBounds_false_whenEmulatorGridIsStale() {
        let view = TerminalNSView(
            initialScreen: TerminalScreen(rows: 1, cols: 80), fontSize: 13)
        // No onResize wiring — the emulator grid stays 1×80 (the stale case).
        view.frame = NSRect(x: 0, y: 0, width: 575, height: 320)
        view.layoutSubtreeIfNeeded()

        let info = view.diagnosticGridInfo()
        XCTAssertEqual(info["gridMatchesBounds"] as? Bool, false,
            "a 1-row grid in a 320pt-tall view is exactly TSK-493 — must flag")
        XCTAssertEqual(info["grid_rows"] as? Int, 1)
    }

    /// The dump walk must attach the terminal node so the VM-side JSON
    /// actually carries the evidence.
    func test_describeView_attachesTerminalNode() {
        let view = TerminalNSView(
            initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        let d = DiagnosticDump.describeView(
            view, depth: 0, includeRecursive: false)
        let term = d["terminal"] as? [String: Any]
        XCTAssertNotNil(term, "describeView must emit the 'terminal' node")
        XCTAssertEqual(term?["grid_rows"] as? Int, 24)
    }
}
