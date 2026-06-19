import XCTest
@testable import ViewerUI

/// TSK-894 — editor current-line highlight state machine.
///
/// BUG (two coupled symptoms): while drag-selecting, the current-line
/// highlight should be SUPPRESSED; and after a drag it used to STICK on the
/// last line and stop following the mouse (other rows still hover-highlight).
///
/// `CMCurrentLineHighlightState` is the host-testable model that mirrors the
/// drag-aware active-line ViewPlugin in `codemirror.html`. These tests pin the
/// decision (`shouldShowCurrentLineHighlight` / `highlightedLine`) and the
/// transitions (begin-drag → suppressed, end-drag-collapsed → tracks the
/// caret) so a regression of the stuck/drag logic fails on the host gate even
/// though the pixel behavior is VM-only.
///
/// Plus a grep test that the JS wiring (the drag-aware plugin, the swap-out of
/// stock `highlightActiveLine()`) survived the build — same contract style as
/// `CodeMirrorBundleTests`.
final class CurrentLineHighlightStateTests: XCTestCase {

    // MARK: - The core decision

    func testIdleCollapsedCaretShowsHighlightOnCaretLine() {
        let s = CMCurrentLineHighlightState(phase: .idle, hasNonEmptySelection: false, caretLine: 7)
        XCTAssertTrue(s.shouldShowCurrentLineHighlight)
        XCTAssertEqual(s.highlightedLine, 7)
    }

    func testHoveringWithCollapsedCaretShowsHighlight() {
        // Hovering (pointer moving, no button) is treated like idle for the
        // line-highlight decision — the caret line tracks.
        let s = CMCurrentLineHighlightState(phase: .hovering, hasNonEmptySelection: false, caretLine: 3)
        XCTAssertTrue(s.shouldShowCurrentLineHighlight)
        XCTAssertEqual(s.highlightedLine, 3)
    }

    // (a) suppress during a drag
    func testDraggingSuppressesHighlightEvenWithCollapsedCaret() {
        let s = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: false, caretLine: 4)
        XCTAssertFalse(s.shouldShowCurrentLineHighlight,
                       "current-line highlight must be suppressed while dragging")
        XCTAssertNil(s.highlightedLine)
    }

    func testDraggingSuppressesHighlightWithSelection() {
        let s = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: true, caretLine: 9)
        XCTAssertFalse(s.shouldShowCurrentLineHighlight)
        XCTAssertNil(s.highlightedLine)
    }

    func testNonEmptySelectionSuppressesHighlightWhenIdle() {
        // A non-empty (multiline or single-line) selection hides the
        // current-line highlight — same predicate the JS uses.
        let s = CMCurrentLineHighlightState(phase: .idle, hasNonEmptySelection: true, caretLine: 12)
        XCTAssertFalse(s.shouldShowCurrentLineHighlight)
        XCTAssertNil(s.highlightedLine)
    }

    // MARK: - Transitions

    func testBeginningDragEntersDraggingAndSuppresses() {
        let start = CMCurrentLineHighlightState(phase: .idle, hasNonEmptySelection: false, caretLine: 5)
        XCTAssertTrue(start.shouldShowCurrentLineHighlight)

        let dragging = start.beginningDrag()
        XCTAssertEqual(dragging.phase, .dragging)
        XCTAssertFalse(dragging.shouldShowCurrentLineHighlight,
                       "highlight must vanish the instant a drag begins")
        XCTAssertNil(dragging.highlightedLine)
    }

    // (b) the stuck-after-drag fix: drag-end with a collapsed caret resumes
    // tracking the caret line — it does NOT stick on where the drag started.
    func testEndingDragCollapsedCaretResumesTrackingNewLine() {
        // Drag started on line 2, released as a collapsed caret on line 18.
        let dragging = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: false, caretLine: 2)
        let ended = dragging.endingDrag(hasNonEmptySelection: false, caretLine: 18)

        XCTAssertNotEqual(ended.phase, .dragging, "must leave the dragging phase on drag-end")
        XCTAssertTrue(ended.shouldShowCurrentLineHighlight,
                      "a collapsed caret after a drag must re-show the highlight")
        XCTAssertEqual(ended.highlightedLine, 18,
                       "highlight must track the caret's NEW line, not stick on the old one")
    }

    func testEndingDragWithRemainingSelectionStaysSuppressed() {
        // Drag released while a real (non-empty) selection remains → still hidden.
        let dragging = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: false, caretLine: 2)
        let ended = dragging.endingDrag(hasNonEmptySelection: true, caretLine: 30)

        XCTAssertNotEqual(ended.phase, .dragging)
        XCTAssertFalse(ended.shouldShowCurrentLineHighlight,
                       "a non-empty selection after the drag keeps the highlight off")
        XCTAssertNil(ended.highlightedLine)
    }

    // The exact-closure regression: a later caret move (hover/keyboard/click)
    // after a drag-end must keep tracking. This is the path that was "stuck".
    func testHoverAfterDragEndTracksHoveredLine() {
        let afterDrag = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: false, caretLine: 2)
            .endingDrag(hasNonEmptySelection: false, caretLine: 18)
        // Caret then moves to line 42 (e.g. a click / arrow key).
        let moved = afterDrag.selectionChanged(hasNonEmptySelection: false, caretLine: 42)
        XCTAssertTrue(moved.shouldShowCurrentLineHighlight)
        XCTAssertEqual(moved.highlightedLine, 42,
                       "after a drag the highlight must follow subsequent caret moves")
    }

    func testSelectionChangedClearsStuckDraggingPhase() {
        // A programmatic / keyboard selection change while (incorrectly) still
        // flagged dragging must drop the dragging phase so the highlight can show.
        let stuck = CMCurrentLineHighlightState(phase: .dragging, hasNonEmptySelection: false, caretLine: 2)
        let recovered = stuck.selectionChanged(hasNonEmptySelection: false, caretLine: 11)
        XCTAssertNotEqual(recovered.phase, .dragging)
        XCTAssertTrue(recovered.shouldShowCurrentLineHighlight)
        XCTAssertEqual(recovered.highlightedLine, 11)
    }

    func testSelectionChangedToNonEmptyHidesHighlight() {
        let start = CMCurrentLineHighlightState(phase: .idle, hasNonEmptySelection: false, caretLine: 5)
        let selected = start.selectionChanged(hasNonEmptySelection: true, caretLine: 8)
        XCTAssertFalse(selected.shouldShowCurrentLineHighlight)
        XCTAssertNil(selected.highlightedLine)
    }

    // MARK: - Defaults / equality

    func testDefaultsAreIdleCollapsedOnLineOne() {
        let s = CMCurrentLineHighlightState()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.hasNonEmptySelection)
        XCTAssertEqual(s.caretLine, 1)
        XCTAssertTrue(s.shouldShowCurrentLineHighlight)
        XCTAssertEqual(s.highlightedLine, 1)
    }

    // MARK: - JS wiring contract (grep the shipped host HTML)

    func testHostHTMLShipsDragAwareActiveLineWiring() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL,
                               "codemirror.html missing from ViewerUI resources")
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            // The custom plugin builder + its install in baseExtensions.
            "function buildActiveLinePlugin",
            "function shouldShowActiveLine",
            "activeLineExtension()",
            // Drag tracking: mousedown begins, document mouseup ends.
            "this.isDragging",
            "addEventListener(\"mousedown\"",
            "addEventListener(\"mouseup\"",
            // The class CM6's default styling targets — reused so theming holds.
            "cm-activeLine",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing TSK-894 wiring: \(needle)")
        }
        // The stock plugin must NOT be installed anymore (only mentioned in
        // explanatory comments). Guard against a re-introduction that would
        // bring back the stuck/drag behavior.
        XCTAssertFalse(html.contains("highlightActiveLine(),"),
                       "stock highlightActiveLine() must stay replaced by activeLineExtension()")
    }
}
