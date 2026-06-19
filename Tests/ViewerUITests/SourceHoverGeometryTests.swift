import XCTest
import CoreGraphics
@testable import ViewerUI

/// Tier 1 (host-safe) coverage for the source line-hover geometry (TSK-263).
/// The pointer→line mapping is the testable kernel of the hover highlight;
/// the drawing/interaction itself is view-layer (human review-gated). These
/// pin the inverse-of-the-gutter math so a coordinate regression fails here.
final class SourceHoverGeometryTests: XCTestCase {

    private func state(offsetY: CGFloat = 0, lineHeight: CGFloat = 16,
                       lineCount: Int = 100, topInset: CGFloat = 10,
                       viewportHeight: CGFloat = 400,
                       wrappedRowCounts: [Int]? = nil) -> SourceScrollState {
        SourceScrollState(offsetY: offsetY, viewportHeight: viewportHeight,
                          lineHeight: lineHeight, lineCount: lineCount,
                          topInset: topInset, wrappedRowCounts: wrappedRowCounts)
    }

    func test_pointerInTopInset_isAboveFirstLine_returnsNil() {
        // y within the 10pt top inset → above glyph row 1.
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(0, in: state()))
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(9.9, in: state()))
    }

    func test_firstAndSubsequentLines_noScroll() {
        let s = state()
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 1)   // top of line 1
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(25, in: s), 1)   // still line 1 (10..26)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26, in: s), 2)   // line 2
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(42, in: s), 3)   // 10 + 2*16
    }

    func test_scrolled_mapsToDocumentLine() {
        // Scrolled down 160pt == 10 lines; top of viewport now shows line 11.
        let s = state(offsetY: 160)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 11)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26, in: s), 12)
    }

    func test_pastLastLine_returnsNil() {
        // lineHeight 16, topInset 10 → line 3 occupies viewport-y [42, 58).
        let s = state(lineCount: 3)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(47, in: s), 3)   // within line 3
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(57, in: s), 3)   // last px of line 3
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(58, in: s))        // first px past line 3
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(500, in: s))
    }

    func test_degenerateGeometry_returnsNil() {
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(50, in: state(lineHeight: 0)))
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(50, in: state(lineCount: 0)))
    }

    func test_lineViewportY_isInverseOfPointerMapping() {
        let s = state(offsetY: 160)
        // Line 11 sits at the top of the viewport after scrolling 160pt.
        XCTAssertEqual(SourceHoverGeometry.lineViewportY(11, in: s), 10, accuracy: 0.001)
        // Round-trip: the viewport-y of a line maps back to that same line.
        for line in [1, 5, 11, 42, 99] {
            let y = SourceHoverGeometry.lineViewportY(line, in: s)
            XCTAssertEqual(SourceHoverGeometry.lineAtPointer(y, in: s), line,
                           "round-trip failed for line \(line)")
        }
    }

    // TSK-736: the hover handler dedupes its @State write — `if line !=
    // hoveredSourceLine`. Its whole value rests on lineAtPointer being LINE-
    // QUANTIZED: every pointer-y within one line maps to the SAME index, so an
    // intra-line pointer move produces no write (no re-body / no find repaint),
    // collapsing a per-pixel storm into one update per line crossing.
    func test_intraLineSweep_isConstant_thenChangesAtCrossing_dedupePremise() {
        let s = state()   // lineHeight 16, topInset 10 → line 1 = viewport-y [10, 26)
        // 32 sub-pixel samples across the whole of line 1 all read as line 1.
        let samples = stride(from: CGFloat(10), to: 26, by: 0.5)
            .map { SourceHoverGeometry.lineAtPointer($0, in: s) }
        XCTAssertEqual(Set(samples), [1],
            "every intra-line sample maps to one line → the dedupe guard skips all of them")
        // Crossing into the next line DOES change the value (the guard writes).
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(25.99, in: s), 1)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26.0, in: s), 2)
    }

    // MARK: - Wrapped-line mapping (TSK-896)
    //
    // The bug: with soft-wrap on, a logical line spanning K visual rows pushes
    // every line below it down by (K-1) rows. The OLD uniform inverse
    // `floor((y+off-inset)/lineHeight)+1` ignored that and mapped the pointer
    // to a line several rows ABOVE the true one — the "highlight is offset by
    // several lines" drift. These pin the wrap-aware walk. Each would FAIL
    // against the pre-fix uniform formula (that's the teeth).

    func test_wrap_lineSpanningThreeRows_shiftsLinesBelow() {
        // Line 1 wraps to 3 visual rows, lines 2..5 are single rows.
        // lineHeight 16, topInset 10. Visual grid (viewport-y):
        //   line 1 → rows [10,26),[26,42),[42,58)
        //   line 2 → [58,74)
        //   line 3 → [74,90)
        let s = state(lineCount: 5, wrappedRowCounts: [3, 1, 1, 1, 1])
        // Anywhere inside line 1's three rows reads as line 1.
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 1)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(30, in: s), 1)   // row 2 of line 1
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(50, in: s), 1)   // row 3 of line 1
        // First row after the wrap is line 2 — NOT line 4 (the old drift).
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(58, in: s), 2)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(74, in: s), 3)
    }

    func test_wrap_oldUniformFormulaWouldDrift_thisIsTheTeeth() {
        // Demonstrate the regression the fix kills: a pointer over the row that
        // visually shows line 2 must map to line 2, where the uniform formula
        // returned 4 (off by the 2 extra rows line 1 added).
        let s = state(lineCount: 5, wrappedRowCounts: [3, 1, 1, 1, 1])
        let y: CGFloat = 58   // top of line 2's row
        // Wrap-aware (correct):
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(y, in: s), 2)
        // What the old uniform inverse produced (proof the drift was real):
        let driftedLine = Int(((y + s.offsetY) - s.topInset) / s.lineHeight) + 1
        XCTAssertEqual(driftedLine, 4, "uniform inverse drifts by the wrap rows")
        XCTAssertNotEqual(SourceHoverGeometry.lineAtPointer(y, in: s), driftedLine)
    }

    func test_wrap_scrolled_accountsForWrappedRowsAbove() {
        // Lines 1 & 2 wrap to 2 rows each; scroll down 4 rows (64pt). The
        // viewport top now shows the START of line 3 (rows: 1a,1b,2a,2b | 3…).
        let s = state(offsetY: 64, lineCount: 6, wrappedRowCounts: [2, 2, 1, 1, 1, 1])
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 3)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(26, in: s), 4)
    }

    func test_wrap_lineViewportY_isInverseOfPointerMapping() {
        let s = state(lineCount: 6, wrappedRowCounts: [2, 1, 3, 1, 2, 1])
        for line in 1...6 {
            let y = SourceHoverGeometry.lineViewportY(line, in: s)
            XCTAssertEqual(SourceHoverGeometry.lineAtPointer(y, in: s), line,
                           "wrap round-trip failed for line \(line)")
        }
    }

    func test_wrap_lineViewportY_summingRowsAbove() {
        // Line 3's top = topInset + (rows of lines 1+2)*lineHeight - offsetY.
        // Lines 1,2 = 2 rows each → 4 rows above line 3. 10 + 4*16 = 74.
        let s = state(lineCount: 6, wrappedRowCounts: [2, 2, 1, 1, 1, 1])
        XCTAssertEqual(SourceHoverGeometry.lineViewportY(3, in: s), 74, accuracy: 0.001)
    }

    func test_wrap_visualRowSpan_reportsPerLineRows() {
        let s = state(lineCount: 4, wrappedRowCounts: [3, 1, 2, 1])
        XCTAssertEqual(SourceHoverGeometry.visualRowSpan(ofLine: 1, in: s), 3)
        XCTAssertEqual(SourceHoverGeometry.visualRowSpan(ofLine: 2, in: s), 1)
        XCTAssertEqual(SourceHoverGeometry.visualRowSpan(ofLine: 3, in: s), 2)
        // No wrap data → 1.
        XCTAssertEqual(SourceHoverGeometry.visualRowSpan(ofLine: 1, in: state()), 1)
    }

    func test_wrap_pastLastWrappedLine_returnsNil() {
        // 2 lines, line 1 wraps to 2 rows → grid occupies viewport-y [10, 58).
        let s = state(lineCount: 2, wrappedRowCounts: [2, 1])
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(40, in: s), 1)   // row 2 of line 1
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(42, in: s), 2)   // line 2
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(57, in: s), 2)   // last px of line 2
        XCTAssertNil(SourceHoverGeometry.lineAtPointer(58, in: s))        // past the doc
    }

    func test_wrap_shortWrapDataFallsBackToSingleRows_noCrash() {
        // Defensive: wrappedRowCounts shorter than lineCount (stale/partial) —
        // lines past the modeled range default to one row each, no crash.
        let s = state(lineCount: 5, wrappedRowCounts: [2])   // only line 1 modeled
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(10, in: s), 1)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(40, in: s), 1)   // 2nd wrap row
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(42, in: s), 2)   // line 2 (single row)
        XCTAssertEqual(SourceHoverGeometry.lineAtPointer(58, in: s), 3)
    }

    func test_emptyWrapData_behavesLikeNoWrap() {
        // An empty array must behave identically to nil (no-wrap fast path).
        let withEmpty = state(wrappedRowCounts: [])
        let withNil = state(wrappedRowCounts: nil)
        for y in stride(from: CGFloat(10), to: 200, by: 7) {
            XCTAssertEqual(SourceHoverGeometry.lineAtPointer(y, in: withEmpty),
                           SourceHoverGeometry.lineAtPointer(y, in: withNil),
                           "empty wrap data must match no-wrap at y=\(y)")
        }
    }
}
