import XCTest
@testable import ViewerUI

/// TSK-890 — editor drag-select perf: selection-match highlight drag-gate.
///
/// PERF BUG: CM6's stock `highlightSelectionMatches` ViewPlugin recomputes a
/// viewport-wide occurrence scan on EVERY `selectionSet` transaction. A mouse
/// drag-select fires one such transaction per mousemove, so the scan runs
/// unthrottled on each frame of the drag — the reported "drag-selection is
/// slow".
///
/// FIX (same drag-gating principle as TSK-894's active-line highlight): suppress
/// the selection-match scan while a drag is in flight and recompute once on
/// drag-end. `CMSelectionMatchHighlightGate` is the host-testable model that
/// mirrors the JS gate in `codemirror.html`; these tests pin the decision
/// (`shouldRunSelectionMatchScan`) and the transitions so a regression of the
/// JS drag-gating fails on the host gate even though the perf/pixel effect is
/// WebView-only.
///
/// Plus a grep test that the JS wiring (the compartment-wrapped
/// `highlightSelectionMatches`, the drag installer) survived the build — same
/// contract style as `CurrentLineHighlightStateTests` / `CodeMirrorBundleTests`.
final class SelectionMatchHighlightGateTests: XCTestCase {

    // MARK: - The core decision

    func testIdleRunsTheScan() {
        // At rest (no drag) the occurrence scan runs normally — selecting a word
        // with a click still highlights its other occurrences.
        let g = CMSelectionMatchHighlightGate(isDragging: false)
        XCTAssertTrue(g.shouldRunSelectionMatchScan,
                      "selection-match scan must run when no drag is in flight")
    }

    func testDraggingSuppressesTheScan() {
        // Mid-drag the per-mousemove scan is the perf cost we remove.
        let g = CMSelectionMatchHighlightGate(isDragging: true)
        XCTAssertFalse(g.shouldRunSelectionMatchScan,
                       "selection-match scan must be suppressed while dragging")
    }

    // MARK: - Transitions

    func testBeginningDragSuppressesTheScan() {
        let start = CMSelectionMatchHighlightGate(isDragging: false)
        XCTAssertTrue(start.shouldRunSelectionMatchScan)

        let dragging = start.beginningDrag()
        XCTAssertTrue(dragging.isDragging)
        XCTAssertFalse(dragging.shouldRunSelectionMatchScan,
                       "the scan must stop the instant a drag begins")
    }

    func testEndingDragRestoresTheScan() {
        // Drag-end re-enables the scan so it recomputes once against the final
        // selection (the user can immediately see other occurrences).
        let dragging = CMSelectionMatchHighlightGate(isDragging: true)
        let ended = dragging.endingDrag()
        XCTAssertFalse(ended.isDragging)
        XCTAssertTrue(ended.shouldRunSelectionMatchScan,
                      "the scan must resume on drag-end")
    }

    func testFullDragCycleReturnsToScanning() {
        // down → (many mousemoves, all suppressed) → up → scanning again.
        let gate = CMSelectionMatchHighlightGate()
            .beginningDrag()
        XCTAssertFalse(gate.shouldRunSelectionMatchScan)
        // A redundant beginningDrag (e.g. a second mousedown) stays suppressed.
        XCTAssertFalse(gate.beginningDrag().shouldRunSelectionMatchScan)
        let done = gate.endingDrag()
        XCTAssertTrue(done.shouldRunSelectionMatchScan)
    }

    // MARK: - Defaults / equality

    func testDefaultIsNotDraggingAndScans() {
        let g = CMSelectionMatchHighlightGate()
        XCTAssertFalse(g.isDragging)
        XCTAssertTrue(g.shouldRunSelectionMatchScan)
    }

    func testEquality() {
        XCTAssertEqual(CMSelectionMatchHighlightGate(isDragging: true),
                       CMSelectionMatchHighlightGate(isDragging: false).beginningDrag())
        XCTAssertNotEqual(CMSelectionMatchHighlightGate(isDragging: true),
                          CMSelectionMatchHighlightGate(isDragging: false))
    }

    // MARK: - JS wiring contract (grep the shipped host HTML)

    func testHostHTMLShipsDragGatedSelectionMatch() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL,
                                "codemirror.html missing from ViewerUI resources")
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            // The compartment + its installer.
            "selectionMatchCompartment",
            "function installDragSelectionMatchGate",
            "function setSelectionMatchEnabled",
            "installDragSelectionMatchGate()",
            // The drag listeners that flip the gate.
            "dragGateActive",
            "addEventListener(\"mousedown\"",
            "addEventListener(\"mouseup\"",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing TSK-890 wiring: \(needle)")
        }
        // highlightSelectionMatches must now be COMPARTMENT-WRAPPED (so the gate
        // can swap it out mid-drag), not installed bare. Guard against a
        // regression that drops it back to the always-on form.
        XCTAssertTrue(
            html.contains("selectionMatchCompartment.of(highlightSelectionMatches())"),
            "highlightSelectionMatches must be wrapped in selectionMatchCompartment")
        XCTAssertFalse(
            html.contains("      highlightSelectionMatches(),"),
            "highlightSelectionMatches() must not be installed un-gated (drag-perf regression)")
    }
}
